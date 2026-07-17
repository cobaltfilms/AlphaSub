import Foundation
import AlphaSubCore

// MARK: - WebVTT Importer

/// W3C WebVTT subtitle format importer.
/// Supports WebVTT and WebVTT+ (styled WebVTT with CSS classes and inline styles).
public struct WebVTTImporter: FormatImporter {
    public static let formatID = FormatID.webvtt
    public static let formatName = String(localized: "WebVTT / WebVTT+")
    public static let fileExtensions = ["vtt"]

    public static func canImport(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("WEBVTT")
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        let encoding = opts.encoding ?? .utf8

        guard let str = String(data: data, encoding: encoding) else {
            throw FormatError.unsupportedEncoding("Cannot decode WebVTT data")
        }

        let normalized = str
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let (headerRegion, cuesText) = splitHeaderAndCues(normalized)

        var metadata: FormatMetadata = [:]
        if let styleBlock = extractStyleBlock(headerRegion) {
            metadata["webvtt_styles"] = styleBlock
        }

        let frameRate = opts.targetFrameRate ?? .fps25
        let cues = parseCues(cuesText, frameRate: frameRate)

        let track = Track(
            name: "WebVTT Import",
            language: opts.defaultLanguage ?? "",
            subtitles: cues,
            formatOrigin: "webvtt",
            metadata: metadata
        )

        return [track]
    }

    // MARK: - Parsing

    private static func splitHeaderAndCues(_ text: String) -> (header: String, cues: String) {
        let lines = text.components(separatedBy: "\n")
        var headerLines: [String] = []
        var cueLines: [String] = []
        var pastHeader = false

        for line in lines {
            if !pastHeader {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    pastHeader = true
                    continue
                }
                if line.hasPrefix("WEBVTT") || line.hasPrefix("Style::") || line.hasPrefix("Region:") {
                    headerLines.append(line)
                } else if let _ = parseCueHeader(line) {
                    pastHeader = true
                    cueLines.append(line)
                } else {
                    headerLines.append(line)
                }
            } else {
                cueLines.append(line)
            }
        }

        return (headerLines.joined(separator: "\n"), cueLines.joined(separator: "\n"))
    }

    private static func extractStyleBlock(_ header: String) -> String? {
        guard header.contains("Style::") || header.contains("STYLE") else { return nil }
        var styleLines: [String] = []
        var inStyle = false
        for line in header.components(separatedBy: "\n") {
            if line.hasPrefix("STYLE") || line.hasPrefix("Style::") {
                inStyle = true
                continue
            }
            if inStyle {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                styleLines.append(line)
            }
        }
        return styleLines.isEmpty ? nil : styleLines.joined(separator: "\n")
    }

    private static func parseCues(_ text: String, frameRate: FrameRate) -> [Subtitle] {
        let blocks = splitIntoCueBlocks(text)
        return blocks.compactMap { parseCueBlock($0, frameRate: frameRate) }
    }

    private static func splitIntoCueBlocks(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [String] = []
        var current: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let _ = parseCueHeader(trimmed) {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                }
                current = [line]
            } else if trimmed.isEmpty {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks
    }

    private static func parseCueBlock(_ block: String, frameRate: FrameRate) -> Subtitle? {
        let lines = block.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { return nil }

        let timeLine: String
        let payloadLines: [String]

        if let header = parseCueHeader(lines[0]) {
            timeLine = header
            payloadLines = Array(lines.dropFirst())
        } else {
            return nil
        }

        // Split on the arrow WITHOUT collapsing spaces first — the end timecode
        // is followed by space-separated cue settings (align/position/line/size)
        // which must not be glued onto the timecode.
        let timeParts = timeLine.components(separatedBy: "-->")
        guard timeParts.count == 2 else { return nil }

        let startStr = timeParts[0].trimmingCharacters(in: .whitespaces)
        let endPart = timeParts[1].trimmingCharacters(in: .whitespaces)
        // The end timecode is the first whitespace-delimited token; the rest are
        // cue settings.
        let endClean = endPart.split(separator: " ").first.map(String.init) ?? endPart

        guard let startTime = parseWebVTTTimecode(startStr, frameRate: frameRate),
              let endTime = parseWebVTTTimecode(endClean, frameRate: frameRate)
        else { return nil }

        // Cue settings are the space-separated tokens AFTER the end timecode on
        // the timing line (`00:00:02.000 --> 00:00:04.000 align:left line:10%`).
        // Some non-conformant files also put them on their own payload line;
        // extractCueSettingsAndText handles those.
        let settingTokens = endPart.split(separator: " ").dropFirst().map(String.init)
        var placement = parseCueSettings(settingTokens)

        let (textLines, legacyPosition) = extractCueSettingsAndText(payloadLines)
        if placement.vertical == .safeArea(.bottom), legacyPosition != .safeArea(.bottom) {
            placement.vertical = legacyPosition
        }
        let textBlocks = parseVTTText(textLines)

        // SDH: Detect music/offscreen/speaker patterns in WebVTT
        let plainText = textBlocks.map { $0.plainText }.joined(separator: " ").lowercased()
        let isMusic = plainText.contains("♪") || plainText.hasPrefix("(music") || plainText.contains("music ")
        let isOffSpeech = plainText.hasPrefix("(off-screen)") || plainText.hasPrefix("(off screen)")
            || plainText.hasPrefix("(vo)") || plainText.hasPrefix("(voice)")

        // SDH: Detect speaker prefix (e.g., "JOHN: Hello")
        var speaker = ""
        if let colonRange = plainText.range(of: ": "), plainText.distance(from: plainText.startIndex, to: colonRange.lowerBound) <= 20 {
            let potentialSpeaker = String(plainText[..<colonRange.lowerBound])
            if potentialSpeaker.allSatisfy({ $0.isLetter || $0.isWhitespace }) && potentialSpeaker.trimmingCharacters(in: .whitespaces).count >= 2 {
                speaker = potentialSpeaker.trimmingCharacters(in: .whitespaces).uppercased()
            }
        }

        return Subtitle(
            startTime: startTime,
            endTime: endTime,
            textBlocks: textBlocks,
            verticalPosition: placement.vertical,
            horizontalPosition: placement.horizontal,
            alignment: placement.alignment,
            useCustomPosition: placement.vertical != .safeArea(.bottom)
                || placement.horizontal != .centered
                || placement.alignment != .center,
            isMusic: isMusic,
            isOffSpeech: isOffSpeech,
            speaker: speaker
        )
    }

    private static func parseCueHeader(_ line: String) -> String? {
        if line.contains("-->") { return line }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("-->") {
            return trimmed
        }
        return nil
    }

    struct VTTPlacement {
        var vertical: VerticalPosition = .safeArea(.bottom)
        var horizontal: HorizontalPosition = .centered
        var alignment: TextAlignment = .center
    }

    /// Parse the cue-settings tokens that follow the end timecode:
    /// `line:` → vertical (percentage values only; snap lines and negative
    /// line numbers keep the default), `position:` → horizontal,
    /// `align:` → text alignment.
    private static func parseCueSettings(_ tokens: [String]) -> VTTPlacement {
        var placement = VTTPlacement()
        for token in tokens {
            if token.hasPrefix("line:") {
                let value = String(token.dropFirst("line:".count))
                if value.contains("%"), let val = Double(value.split(separator: "%").first.map(String.init) ?? ""),
                   val >= 0, val <= 100 {
                    // Our own exporter writes the default bottom row as
                    // line:94.0% — treat the bottom band as the safe-area
                    // default so round-tripped files don't flag every cue.
                    placement.vertical = val >= 93.5 ? .safeArea(.bottom) : .percentage(val)
                }
            } else if token.hasPrefix("position:") {
                let value = String(token.dropFirst("position:".count))
                if let val = Double(value.split(separator: "%").first.map(String.init) ?? ""),
                   val >= 0, val <= 100 {
                    placement.horizontal = abs(val - 50) < 0.5 ? .centered : .percentage(val)
                }
            } else if token.hasPrefix("align:") {
                switch String(token.dropFirst("align:".count)) {
                case "left", "start": placement.alignment = .left
                case "right", "end":  placement.alignment = .right
                default:              placement.alignment = .center
                }
            }
        }
        return placement
    }

    private static func extractCueSettingsAndText(_ lines: [String]) -> ([String], VerticalPosition) {
        var textLines: [String] = []
        var position: VerticalPosition = .safeArea(.bottom)

        for line in lines {
            if line.contains("-->") && !line.hasPrefix("<") {
                continue
            }
            if line.hasPrefix("position:") || line.hasPrefix("line:") || line.hasPrefix("align:") || line.hasPrefix("vertical:") || line.hasPrefix("size:") {
                if line.contains("line:") {
                    if let val = extractPercentValue(line, key: "line:") {
                        if val > 5.0 {
                            position = .percentage(val)
                        }
                    }
                }
                continue
            }
            textLines.append(line)
        }

        return (textLines, position)
    }

    private static func extractPercentValue(_ line: String, key: String) -> Double? {
        guard let range = line.range(of: key) else { return nil }
        let after = line[range.upperBound...]
        let numStr = after.split(separator: "%").first?.split(separator: ",").first ?? ""
        return Double(numStr)
    }

    // MARK: - WebVTT Time Parsing

    private static func parseWebVTTTimecode(_ str: String, frameRate: FrameRate) -> Timecode? {
        let s = str.trimmingCharacters(in: .whitespaces)

        let hhmmssmmm = #/^(\d{2,}):(\d{2}):(\d{2})[.,](\d{3})$/#
        if #available(macOS 13.0, *) {
            if let match = try? hhmmssmmm.wholeMatch(in: s) {
                let h = Int(match.1)!, m = Int(match.2)!, sec = Int(match.3)!, ms = Int(match.4)!
                let total = Double(h * 3600 + m * 60 + sec) + Double(ms) / 1000.0
                return Timecode.fromSeconds(total, frameRate: frameRate)
            }
        } else {
            let parts = s.components(separatedBy: CharacterSet(charactersIn: ":,."))
            if parts.count == 4,
               let h = Int(parts[0]), let m = Int(parts[1]),
               let sec = Int(parts[2]), let ms = Int(parts[3]) {
                let total = Double(h * 3600 + m * 60 + sec) + Double(ms) / 1000.0
                return Timecode.fromSeconds(total, frameRate: frameRate)
            }
        }

        let mmmssmmm = #/^(\d{1,2}):(\d{2})[.,](\d{3})$/#
        if #available(macOS 13.0, *) {
            if let match = try? mmmssmmm.wholeMatch(in: s) {
                let m = Int(match.1)!, sec = Int(match.2)!, ms = Int(match.3)!
                let total = Double(m * 60 + sec) + Double(ms) / 1000.0
                return Timecode.fromSeconds(total, frameRate: frameRate)
            }
        } else {
            let parts = s.components(separatedBy: CharacterSet(charactersIn: ":,."))
            if parts.count == 3,
               let m = Int(parts[0]), let sec = Int(parts[1]), let ms = Int(parts[2]) {
                let total = Double(m * 60 + sec) + Double(ms) / 1000.0
                return Timecode.fromSeconds(total, frameRate: frameRate)
            }
        }

        return nil
    }

    // MARK: - WebVTT Text Parsing (handles <i>, <b>, <u>, <lang>, <ruby>, cue settings)

    private static func parseVTTText(_ lines: [String]) -> [TextBlock] {
        return lines.map { line in
            let cleanLine = stripVTTTags(line)
            let segments = parseVTTLineIntoSegments(cleanLine)
            return TextBlock(segments: segments)
        }
    }

    private static func stripVTTTags(_ line: String) -> String {
        var cleaned = line
        cleaned = cleaned.replacingOccurrences(of: "<ruby>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "</ruby>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<rt>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "</rt>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<lang .*?>", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "</lang>", with: "")
        return cleaned
    }

    private static func parseVTTLineIntoSegments(_ line: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        var currentText = ""
        var currentStyle: TextStyle = []
        var currentColor: TextColor?
        var colorStack: [TextColor?] = []
        var i = line.startIndex

        while i < line.endIndex {
            if line[i] == "<" {
                if let closeIndex = line[i...].firstIndex(of: ">") {
                    let tagContent = String(line[line.index(after: i)..<closeIndex])
                    let tag = tagContent.lowercased()

                    if !currentText.isEmpty {
                        segments.append(TextSegment(text: currentText, style: currentStyle, color: currentColor))
                        currentText = ""
                    }

                    switch tag {
                    case "i", "italic":              currentStyle.insert(.italic)
                    case "/i", "/italic":             currentStyle.remove(.italic)
                    case "b", "bold":                  currentStyle.insert(.bold)
                    case "/b", "/bold":                currentStyle.remove(.bold)
                    case "u", "underline":             currentStyle.insert(.underline)
                    case "/u", "/underline":           currentStyle.remove(.underline)
                    case "/c":
                        currentColor = colorStack.popLast() ?? nil
                    default:
                        if tag == "c" || tag.hasPrefix("c.") {
                            // Standard colour classes: <c.yellow>, <c.cyan>, …
                            colorStack.append(currentColor)
                            if let c = classColor(from: tag) { currentColor = c }
                        }
                    }

                    i = line.index(after: closeIndex)
                } else {
                    currentText.append(line[i])
                    i = line.index(after: i)
                }
            } else {
                currentText.append(line[i])
                i = line.index(after: i)
            }
        }

        if !currentText.isEmpty {
            segments.append(TextSegment(text: currentText, style: currentStyle, color: currentColor))
        }

        return segments.isEmpty ? [TextSegment(text: line, style: [])] : segments
    }

    /// The 8 standard teletext colour class names of a `<c.…>` tag. White maps
    /// to nil (format default). Non-colour classes (`<c.music>`, …) are ignored.
    private static func classColor(from tag: String) -> TextColor? {
        for cls in tag.split(separator: ".").dropFirst() {
            switch cls {
            case "white":   return nil
            case "yellow":  return .yellow
            case "cyan":    return .cyan
            case "green":   return .green
            case "magenta": return .magenta
            case "red":     return .red
            case "blue":    return .blue
            case "black":   return .black
            default: continue
            }
        }
        return nil
    }
}

// MARK: - WebVTT Exporter

public struct WebVTTExporter: FormatExporter {
    public static let formatID = FormatID.webvtt
    public static let formatName = String(localized: "WebVTT / WebVTT+")
    public static let fileExtension = "vtt"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        // No BOM: many web players choke on a leading U+FEFF, and professional
        // exporters omit it.
        var output = "WEBVTT\n\n"

        // SDH colour preset (cue classes referenced when a cue carries an SDH
        // flag). Always emitted so the classes resolve.
        output += """
        STYLE
        ::cue(.off-screen) { color: #ffff00; }
        ::cue(.voice-over) { color: #00ffff; }
        ::cue(.noise) { color: #ff0000; }
        ::cue(.music) { color: #ff00ff; }
        ::cue(.foreign) { color: #00ff00; }

        """
        output += "\n"

        // Preserve any round-tripped styles from an imported file.
        if let styles = track.metadata["webvtt_styles"] {
            output += "STYLE\n\(styles)\n\n"
        }

        for (index, sub) in track.subtitles.enumerated() {
            output += "\(index + 1)\n"
            output += "\(formatVTTTimecode(sub.startTime)) --> \(formatVTTTimecode(sub.endTime))"
            output += cueSettings(for: sub)
            output += "\n"

            var text = formatVTTText(sub.textBlocks)
            // SDH flags map to cue classes (resolved by the STYLE preset) rather
            // than being injected as literal text.
            if sub.isMusic {
                text = "<c.music>\(text)</c>"
            } else if sub.isOffSpeech {
                text = "<c.off-screen>\(text)</c>"
            }
            output += text
            output += "\n\n"
        }

        guard let data = output.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode WebVTT as UTF-8")
        }
        return data
    }

    /// Explicit cue settings string (alignment + position + line), matching the
    /// professional reference: centred default cues get `align:center
    /// position:50%,center`, left/right cues an inset position with 95% size, and
    /// centred cues with a custom horizontal position keep that exact percentage.
    private static func cueSettings(for sub: Subtitle) -> String {
        let line = String(format: "%.1f%%", vttLinePercent(sub))
        switch sub.alignment {
        case .left, .start:
            return " align:left position:5.0% size:95.0% line:\(line)"
        case .right, .end:
            return " align:right position:95.0% size:95.0% line:\(line)"
        default:
            switch sub.horizontalPosition {
            case .percentage(let p): return " align:center position:\(Int(p))% line:\(line)"
            case .leftAligned:       return " align:center position:0% line:\(line)"
            case .rightAligned:      return " align:center position:100% line:\(line)"
            case .centered:          return " align:center position:50%,center line:\(line)"
            }
        }
    }

    /// Vertical position as a WebVTT line percentage (0 = top, ~94 = bottom).
    private static func vttLinePercent(_ sub: Subtitle) -> Double {
        switch sub.verticalPosition {
        case .safeArea(.top):     return 10.0
        case .safeArea(.center):  return 50.0
        case .safeArea(.bottom):  return 94.0
        case .percentage(let p):  return min(100.0, max(0.0, p))
        case .lineShift(let n):   return max(0.0, 94.0 - Double(n) * 6.0)
        case .row(let r):         return min(94.0, Double(r) * 4.0)
        }
    }

    private static func formatVTTTimecode(_ tc: Timecode) -> String {
        let (h, m, s, _) = tc.components
        let ms = tc.milliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private static func formatVTTText(_ blocks: [TextBlock]) -> String {
        return blocks.map { block in
            block.segments.map { segment in
                var text = segment.text
                if segment.style.contains(.italic)    { text = "<i>\(text)</i>" }
                if segment.style.contains(.bold)       { text = "<b>\(text)</b>" }
                if segment.style.contains(.underline)   { text = "<u>\(text)</u>" }
                // Only the standard colour classes are portable — segments
                // whose colour isn't exactly one of the 8 names export uncoloured.
                if let color = segment.color, let name = vttClassName(color) {
                    text = "<c.\(name)>\(text)</c>"
                }
                return text
            }.joined()
        }.joined(separator: "\n")
    }

    private static func vttClassName(_ color: TextColor) -> String? {
        switch color {
        case .white:   return "white"
        case .yellow:  return "yellow"
        case .cyan:    return "cyan"
        case .green:   return "green"
        case .magenta: return "magenta"
        case .red:     return "red"
        case .blue:    return "blue"
        case .black:   return "black"
        default:       return nil
        }
    }
}