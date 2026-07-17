import Foundation
import AlphaSubCore

// MARK: - ASS Importer

/// Advanced SubStation Alpha / SubStation Alpha format importer.
/// Supports .ass and .ssa files with positioning, colors, and background boxes.
public struct ASSImporter: FormatImporter {
    public static let formatID = FormatID.ass
    public static let formatName = String(localized: "Advanced SubStation Alpha (.ass)")
    public static let fileExtensions = ["ass", "ssa"]

    public static func canImport(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        return str.contains("[Script Info]") || str.contains("ScriptType:")
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw FormatError.unsupportedEncoding("Cannot decode ASS data")
        }

        let normalized = str
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var frameRate: FrameRate = opts.targetFrameRate ?? .fps25
        var frameRateFromFile = opts.targetFrameRate != nil
        var title = "ASS Import"

        let lines = normalized.components(separatedBy: "\n")
        var inScriptInfo = false
        var inEvents = false
        var inStyles = false
        var styleDefs: [String: ASSStyle] = [:]
        var subtitles: [Subtitle] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if trimmed == "[Script Info]" {
                inScriptInfo = true
                inEvents = false
                inStyles = false
                continue
            }
            if trimmed == "[Events]" {
                inScriptInfo = false
                inEvents = true
                inStyles = false
                continue
            }
            // "[Styles]" (SSA v4) and "[V4 Styles]" / "[V4+ Styles]" (ASS).
            if trimmed == "[Styles]" || trimmed.hasPrefix("[Styles") || trimmed.hasPrefix("[V4") {
                inScriptInfo = false
                inEvents = false
                inStyles = true
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inScriptInfo = false
                inEvents = false
                inStyles = false
                continue
            }

            if inScriptInfo {
                if trimmed.hasPrefix("Title:") {
                    title = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("PlayResX:") || trimmed.hasPrefix("PlayResY:") {
                } else if trimmed.hasPrefix("Timer:") {
                    if let val = Double(trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
                        if let matched = FrameRate.allCases.first(where: { abs($0.value - val) < 0.5 }) {
                            frameRate = matched
                            frameRateFromFile = true
                        }
                    }
                }
            }

            if inStyles {
                let lower = trimmed.lowercased()
                if lower.hasPrefix("style:") {
                    let style = parseStyleLine(trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces))
                    styleDefs[style.name.lowercased()] = style
                }
            }

            if inEvents {
                let lower = trimmed.lowercased()
                if lower.hasPrefix("dialogue:") {
                    if let sub = parseDialogueLine(
                        String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces),
                        frameRate: frameRate,
                        styles: styleDefs
                    ) {
                        subtitles.append(sub)
                    }
                }
            }
        }

        let track = Track(
            name: title,
            language: opts.defaultLanguage ?? "",
            subtitles: subtitles,
            formatOrigin: "ass",
            frameRate: frameRateFromFile ? frameRate : nil
        )
        return [track]
    }

    // MARK: - ASS Parsing

    private struct ASSStyle {
        var name: String
        var italic: Bool
        var bold: Bool
        var underline: Bool
        var strikeout: Bool
        var alignment: Int
        var marginV: Int
        var primaryColour: TextColor?
    }

    private static func parseStyleLine(_ line: String) -> ASSStyle {
        let parts = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 22 else {
            return ASSStyle(name: parts.count > 0 ? parts[0] : "Default", italic: false, bold: false, underline: false, strikeout: false, alignment: 2, marginV: 30, primaryColour: nil)
        }
        // PrimaryColour white is the format default — leave it nil so plain
        // tracks don't come in marked as coloured.
        var primary = parseASSColorValue(parts[3])
        if primary == .white { primary = nil }
        return ASSStyle(
            name: parts[0],
            italic: parts[7].contains("-1") || parts[7].contains("1"),
            bold: parts[8].contains("-1") || parts[8].contains("1"),
            underline: parts[13].contains("-1") || parts[13].contains("1"),
            strikeout: parts[14].contains("-1") || parts[14].contains("1"),
            alignment: Int(parts[18]) ?? 2,
            marginV: Int(parts[17]) ?? 30,
            primaryColour: primary
        )
    }

    /// Parse an ASS colour value `&HAABBGGRR&` / `&HBBGGRR` (BGR byte order,
    /// alpha ignored, trailing `&` optional).
    static func parseASSColorValue(_ raw: String) -> TextColor? {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("&H") { s = String(s.dropFirst(2)) }
        else if s.hasPrefix("&") { s = String(s.dropFirst()) }
        if s.hasSuffix("&") { s = String(s.dropLast()) }
        guard !s.isEmpty, s.count <= 8, s.allSatisfy({ $0.isHexDigit }),
              let v = UInt32(s, radix: 16) else { return nil }
        return TextColor(r: UInt8(v & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8((v >> 16) & 0xFF))
    }

    private static func parseDialogueLine(_ line: String, frameRate: FrameRate, styles: [String: ASSStyle]) -> Subtitle? {
        let parts = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 10 else { return nil }

        let styleName = parts[3].lowercased()
        let startStr = parts[1]
        let endStr = parts[2]

        guard let startTime = parseASSTimecode(startStr, frameRate: frameRate),
              let endTime = parseASSTimecode(endStr, frameRate: frameRate)
        else { return nil }

        let textStart = line.range(of: ",\(parts[9])")
        let rawText: String
        if let textRange = textStart {
            let textBegin = line.index(textRange.lowerBound, offsetBy: 1)
            rawText = String(line[textBegin...])
        } else {
            rawText = parts[9]
        }

        let textBlocks = parseASSText(rawText)

        let baseStyle = styles[styleName]
        var vpos: VerticalPosition = .safeArea(.bottom)
        var align: TextAlignment = .center

        if let style = baseStyle {
            switch style.alignment {
            case 1, 2, 3: vpos = .safeArea(.bottom)
            case 4, 5, 6: vpos = .safeArea(.center)
            case 7, 8, 9: vpos = .safeArea(.top)
            default: vpos = .safeArea(.bottom)
            }
            switch style.alignment {
            case 1, 4, 7: align = .left
            case 3, 6, 9: align = .right
            default: align = .center
            }
            if parts.count > 5, let marginV = Int(parts[7]), marginV > 0 {
                switch vpos {
                case .safeArea(.bottom): vpos = .percentage(Double(100 - marginV))
                case .safeArea(.top): vpos = .percentage(Double(marginV))
                default: break
                }
            }
        }

        var isItalic = baseStyle?.italic ?? false
        let isBold = baseStyle?.bold ?? false
        if parts.count > 3 {
            if parts[3].contains("It") || parts[3].contains("it") { isItalic = true }
        }

        let styleColor = baseStyle?.primaryColour
        var mergedBlocks = textBlocks
        if isItalic || isBold || styleColor != nil {
            for i in mergedBlocks.indices {
                var merged = [TextSegment]()
                for seg in mergedBlocks[i].segments {
                    var style: TextStyle = seg.style
                    if isItalic { style.insert(.italic) }
                    if isBold { style.insert(.bold) }
                    // Inline overrides win over the style's PrimaryColour.
                    merged.append(TextSegment(text: seg.text, style: style, color: seg.color ?? styleColor))
                }
                mergedBlocks[i] = TextBlock(segments: merged)
            }
        }

        return Subtitle(
            startTime: startTime,
            endTime: endTime,
            textBlocks: mergedBlocks,
            verticalPosition: vpos,
            alignment: align,
            useCustomPosition: vpos != .safeArea(.bottom) || align != .center
        )
    }

    private static func parseASSTimecode(_ str: String, frameRate: FrameRate) -> Timecode? {
        let s = str.trimmingCharacters(in: .whitespaces)
        let parts = s.components(separatedBy: CharacterSet(charactersIn: ":."))
        guard parts.count >= 4,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              let sec = Int(parts[2])
        else { return nil }

        let frac = parts[3]
        if frac.count <= 2, let f = Int(frac) {
            return Timecode(h: h, m: m, s: sec, f: f, frameRate: frameRate)
        }
        if let cs = Double("0.\(frac)") {
            let totalSeconds = Double(h * 3600 + m * 60 + sec) + cs
            return Timecode.fromSeconds(totalSeconds, frameRate: frameRate)
        }
        return nil
    }

    private static func parseASSText(_ raw: String) -> [TextBlock] {
        // Override blocks `{...}` are consumed by parseASSSegments (which
        // applies the \i/\b/\u/\c toggles it models), so they must NOT be
        // stripped up front — that would lose inline colour overrides.
        func makeBlock(_ line: String) -> TextBlock {
            let text = line.replacingOccurrences(of: "\\h", with: " ")
            let segments = parseASSSegments(text)
            guard !segments.isEmpty else {
                let plain = text.replacingOccurrences(of: "\\{.*?\\}", with: "", options: .regularExpression)
                return TextBlock(plainText: plain)
            }
            return TextBlock(segments: segments)
        }

        guard raw.contains("\\N") || raw.contains("\\n") else {
            return [makeBlock(raw)]
        }

        var blocks: [TextBlock] = []
        let hardLines = raw.components(separatedBy: "\\N")
        for line in hardLines {
            blocks.append(makeBlock(line.components(separatedBy: "\\n").joined(separator: " ")))
        }
        return blocks
    }

    private static func parseASSSegments(_ text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        var currentText = ""
        var currentStyle: TextStyle = []
        var currentColor: TextColor?
        var i = text.startIndex

        while i < text.endIndex {
            if text.index(i, offsetBy: 2, limitedBy: text.endIndex) != nil && text[i] == "\\" {
                let next = text.index(after: i)
                let nextChar = text[next]

                if nextChar == "i" || nextChar == "I" {
                    if !currentText.isEmpty {
                        segments.append(TextSegment(text: currentText, style: currentStyle, color: currentColor))
                        currentText = ""
                    }
                    let closeIdx = text.index(after: next)
                    if closeIdx < text.endIndex && text[closeIdx] == "0" {
                        currentStyle.remove(.italic)
                        i = text.index(after: closeIdx)
                    } else {
                        currentStyle.insert(.italic)
                        i = text.index(after: next)
                    }
                    continue
                }
                if nextChar == "b" || nextChar == "B" {
                    if !currentText.isEmpty {
                        segments.append(TextSegment(text: currentText, style: currentStyle, color: currentColor))
                        currentText = ""
                    }
                    let closeIdx = text.index(after: next)
                    if closeIdx < text.endIndex && text[closeIdx] == "0" {
                        currentStyle.remove(.bold)
                        i = text.index(after: closeIdx)
                    } else {
                        currentStyle.insert(.bold)
                        i = text.index(after: next)
                    }
                    continue
                }
                if nextChar == "u" || nextChar == "U" {
                    if !currentText.isEmpty {
                        segments.append(TextSegment(text: currentText, style: currentStyle, color: currentColor))
                        currentText = ""
                    }
                    let closeIdx = text.index(after: next)
                    if closeIdx < text.endIndex && text[closeIdx] == "0" {
                        currentStyle.remove(.underline)
                        i = text.index(after: closeIdx)
                    } else {
                        currentStyle.insert(.underline)
                        i = text.index(after: next)
                    }
                    continue
                }
            }

            if text[i] == "{" {
                if let endBrace = text[i...].firstIndex(of: "}") {
                    if !currentText.isEmpty {
                        segments.append(TextSegment(text: currentText, style: currentStyle, color: currentColor))
                        currentText = ""
                    }
                    let override = String(text[text.index(after: i)..<endBrace])
                    parseASSOverride(override, style: &currentStyle, color: &currentColor)
                    i = text.index(after: endBrace)
                    continue
                }
            }

            currentText.append(text[i])
            i = text.index(after: i)
        }

        if !currentText.isEmpty {
            segments.append(TextSegment(text: currentText, style: currentStyle, color: currentColor))
        }

        return segments
    }

    private static func parseASSOverride(_ override: String, style: inout TextStyle, color: inout TextColor?) {
        if override.contains("\\i1") { style.insert(.italic) }
        if override.contains("\\i0") { style.remove(.italic) }
        if override.contains("\\b1") || override.contains("\\b400") { style.insert(.bold) }
        if override.contains("\\b0") { style.remove(.bold) }
        if override.contains("\\u1") { style.insert(.underline) }
        if override.contains("\\u0") { style.remove(.underline) }
        // Primary-colour override: {\c&HBBGGRR&} / {\1c&HBBGGRR&}. A bare
        // \c / \1c (no argument) resets to the style default. \2c–\4c
        // (secondary/outline/shadow) are not modelled and are ignored.
        if let m = override.range(of: "\\\\1?c(?![a-zA-Z])(&H[0-9A-Fa-f]+&?)?", options: .regularExpression) {
            let match = String(override[m])
            if let amp = match.range(of: "&H") {
                var value = TextColor?.none
                if let parsed = ASSImporter.parseASSColorValue(String(match[amp.lowerBound...])) {
                    value = parsed == .white ? nil : parsed
                }
                color = value
            } else {
                color = nil
            }
        }
    }
}

// MARK: - ASS Exporter

/// Advanced SubStation Alpha format exporter.
/// Supports positioning, colour, and background box via override tags.
public struct ASSExporter: FormatExporter {
    public static let formatID = FormatID.ass
    public static let formatName = String(localized: "Advanced SubStation Alpha (.ass)")
    public static let fileExtension = "ass"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        let _ = options?.sourceFrameRate ?? track.subtitles.first?.startTime.frameRate ?? .fps25
        let playResX = 384
        let playResY = 288
        let boldFlag = (options?.boldFont ?? false) ? -1 : 0

        let borderWidth = options?.borderWidth ?? 1
        let borderColor = options?.borderColor ?? "000000"
        let assOutlineColor = assColor(fromHex: borderColor)

        var output = ""
        output += "[Script Info]\n"
        output += "Title: \(track.name)\n"
        output += "ScriptType: v4.00+\n"
        output += "PlayResX: \(playResX)\n"
        output += "PlayResY: \(playResY)\n"
        output += "Timer: 100.0000\n"
        output += "\n"
        output += "[V4+ Styles]\n"
        output += "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        output += "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00\(assOutlineColor),&H80000000,\(boldFlag),0,0,0,100,100,0,0,1,\(borderWidth == 0 ? "0" : "1"),\(String(format: "%.0f", borderWidth)),0,2,10,10,30,1\n"
        output += "Style: Italic,Arial,20,&H00FFFFFF,&H000000FF,&H00\(assOutlineColor),&H80000000,\(boldFlag),-1,0,0,100,100,0,0,1,\(borderWidth == 0 ? "0" : "1"),\(String(format: "%.0f", borderWidth)),0,2,10,10,30,1\n"
        output += "\n"
        output += "[Events]\n"
        output += "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"

        for sub in track.subtitles {
            let startTC = formatASSTimecode(sub.startTime)
            let endTC = formatASSTimecode(sub.endTime)

            let styleName: String
            let isAllItalic = sub.textBlocks.allSatisfy { block in
                block.segments.allSatisfy { $0.style.contains(.italic) }
            }
            let isAllBold = sub.textBlocks.allSatisfy { block in
                block.segments.allSatisfy { $0.style.contains(.bold) }
            }
            if isAllItalic && isAllBold {
                styleName = "Italic"
            } else {
                styleName = "Default"
            }

            let text = formatASSText(sub.textBlocks, hasInlineItalic: !isAllItalic, hasInlineBold: !isAllBold)
            var overrides = ""
            switch sub.verticalPosition {
            case .percentage(let pct):
                overrides += "\\pos(\(playResX/2),\(Int(Double(playResY) * pct / 100.0)))"
            case .safeArea(.top):
                overrides += "\\an8"
            case .safeArea(.center):
                overrides += "\\an5"
            default:
                break
            }
            switch sub.alignment {
            case .left, .start:
                overrides += "\\an1"
            case .right, .end:
                overrides += "\\an3"
            default:
                break
            }

            let fullText = overrides.isEmpty ? text : "{\(overrides)}\(text)"
            output += "Dialogue: 0,\(startTC),\(endTC),\(styleName),,0000,0000,0000,,\(fullText)\n"
        }

        guard let data = output.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode ASS as UTF-8")
        }
        return data
    }

    private static func formatASSTimecode(_ tc: Timecode) -> String {
        let (h, m, s, f) = tc.components
        let cs = Int(Double(f) / tc.frameRate.value * 100.0)
        return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
    }

    private static func formatASSText(_ blocks: [TextBlock], hasInlineItalic: Bool, hasInlineBold: Bool) -> String {
        // Inline colour: an override is emitted whenever the effective colour
        // changes between segments; nil (default) is the style's white.
        var currentColor: TextColor?
        return blocks.map { block in
            block.segments.map { segment in
                var text = segment.text
                    .replacingOccurrences(of: "\\n", with: " ")
                    .replacingOccurrences(of: "\\N", with: " ")
                    .replacingOccurrences(of: "{", with: "\\{")
                if hasInlineItalic && segment.style.contains(.italic) { text = "{\\i1}\(text){\\i0}" }
                if hasInlineBold && segment.style.contains(.bold) { text = "{\\b1}\(text){\\b0}" }
                if segment.color != currentColor {
                    text = "{\\1c\(assOverrideColor(segment.color ?? .white))}" + text
                    currentColor = segment.color
                }
                return text
            }.joined()
        }.joined(separator: "\\N")
    }

    /// `&HBBGGRR&` for an inline `\1c` override.
    private static func assOverrideColor(_ c: TextColor) -> String {
        String(format: "&H%02X%02X%02X&", c.b, c.g, c.r)
    }

    /// Convert a hex color string (e.g. "000000" or "FF000000") to ASS &H00BBGGRR format.
    private static func assColor(fromHex hex: String) -> String {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let chars = Array(clean)
        let r: String
        let g: String
        let b: String
        if chars.count == 8 {
            r = String(chars[2]) + String(chars[3])
            g = String(chars[4]) + String(chars[5])
            b = String(chars[6]) + String(chars[7])
        } else if chars.count == 6 {
            r = String(chars[0]) + String(chars[1])
            g = String(chars[2]) + String(chars[3])
            b = String(chars[4]) + String(chars[5])
        } else {
            return "000000"
        }
        return b + g + r
    }
}