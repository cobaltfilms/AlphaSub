import Foundation
import AlphaSubCore

// MARK: - FCPXML (Final Cut Pro X XML) Importer

/// Final Cut Pro X XML (`.fcpxml`) subtitle format importer.
///
/// FCPXML describes titles as `<title>` elements on a titles lane inside a
/// `<sequence>` `<spine>`. Each `<title>` carries `offset` and `duration`
/// attributes expressed as rational seconds (e.g. `3201/2400s`) relative to
/// the sequence start, and a `<text>` child containing the subtitle string.
///
/// This importer walks the document, locates every `<title>` element, parses
/// its timing and text, and emits one `Track` per `<project>` (named after the
/// project). When a project cannot be found, titles are collected under a
/// single fallback track named "FCPXML Import".
///
/// Only the subset of FCPXML relevant to subtitles is parsed: `<title>` text
/// content, `<text-style>` italic/bold hints, and timing. Other elements
/// (clips, audio, effects) are ignored.
public struct FCPXMLImporter: FormatImporter {
    public static let formatID = FormatID.fcpxml
    public static let formatName = String(localized: "FCP X XML (.fcpxml)")
    public static let fileExtensions = ["fcpxml", "fcpxmld"]

    public static func canImport(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        // FCPXML is XML with an <fcpxml> root element. Sniff for the root
        // tag (with or without attributes) rather than just the file
        // extension, so mislabelled files are still detected.
        return str.contains("<fcpxml") || str.contains("Final Cut Pro")
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        let frameRate = opts.targetFrameRate ?? .fps25

        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw FormatError.unsupportedEncoding("Cannot decode FCPXML data")
        }

        let doc = try XMLDocument(xmlString: str, options: [])
        guard let root = doc.rootElement() else {
            throw FormatError.invalidData("No root element in FCPXML")
        }

        // The root must be <fcpxml>. Be tolerant of namespaces / attributes.
        guard localName(root.name) == "fcpxml" else {
            throw FormatError.invalidData("Root element is not <fcpxml>")
        }

        // Determine the project frame rate from <sequence frameDuration>.
        // FCPXML expresses frame duration as a rational (e.g. "1001/24000s"
        // for 23.976 fps). Fall back to the options / default 25 fps.
        let detectedFrameRate = detectFrameRate(root)
        let sequenceFrameRate = detectedFrameRate ?? frameRate
        // When the rate was read from the file or explicitly passed via opts,
        // record it on the track so the UI knows it wasn't guessed.
        let trackFrameRate: FrameRate? = detectedFrameRate ?? opts.targetFrameRate

        // Collect titles grouped by their enclosing <project>, preserving
        // document order. If no <project> is present, group everything under
        // a single fallback track.
        var tracks: [Track] = []
        let projects = findElements(root: root, localName: "project")
        if projects.isEmpty {
            let titles = findElements(root: root, localNames: ["title", "caption"])
            let subs = titles.compactMap { parseTitle($0, frameRate: sequenceFrameRate, baseOffset: nil) }
            if !subs.isEmpty {
                tracks.append(makeTrack(name: "FCPXML Import", language: opts.defaultLanguage?.rawValue ?? "", subtitles: subs, frameRate: trackFrameRate))
            }
        } else {
            for project in projects {
                let name = project.attribute(forName: "name")?.stringValue ?? "FCPXML Import"
                let titles = findElements(root: project, localNames: ["title", "caption"])
                // A title's offset is relative to its enclosing sequence, not
                // the project. FCPXML sequences are siblings of (or wrap)
                // projects; for the common single-sequence layout we treat
                // the sequence start as the offset origin. We pass nil and
                // rely on the title's own offset attribute.
                let subs = titles.compactMap { parseTitle($0, frameRate: sequenceFrameRate, baseOffset: nil) }
                if !subs.isEmpty {
                    tracks.append(makeTrack(name: name, language: opts.defaultLanguage?.rawValue ?? "", subtitles: subs, frameRate: trackFrameRate))
                }
            }
        }

        // If we found nothing at all, return an empty array rather than a
        // phantom track. The old stub returned a single empty track, which
        // lied to callers about having imported content.
        if tracks.isEmpty {
            return []
        }

        // Apply an optional import timecode offset.
        if let offset = opts.timecodeOffset {
            tracks = tracks.map { $0.offsetAll(by: offset) }
        }

        return tracks
    }

    // MARK: - Parsing Helpers

    private static func makeTrack(name: String, language: String, subtitles: [Subtitle], frameRate: FrameRate? = nil) -> Track {
        var metadata: FormatMetadata = [:]
        metadata["fcpxml_version"] = "1.11"
        return Track(
            name: name,
            language: LanguageCode(language),
            subtitles: subtitles,
            formatOrigin: "fcpxml",
            metadata: metadata,
            frameRate: frameRate
        )
    }

    /// Parse a `<title>` element into a `Subtitle`.
    ///
    /// `offset` is the title's start time relative to the sequence start;
    /// `duration` is its on-screen duration. Both are rational seconds.
    /// The text comes from the `<text>` child, which may contain styled
    /// `<text-style>` runs.
    private static func parseTitle(_ title: XMLElement, frameRate: FrameRate, baseOffset: Timecode?) -> Subtitle? {
        guard let offsetStr = title.attribute(forName: "offset")?.stringValue,
              let startTime = parseRationalSeconds(offsetStr, frameRate: frameRate)
        else { return nil }

        let durationStr = title.attribute(forName: "duration")?.stringValue ?? "0s"
        guard let duration = parseRationalSeconds(durationStr, frameRate: frameRate) else { return nil }

        let endTime = Timecode(totalFrames: startTime.totalFrames + duration.totalFrames, frameRate: frameRate)

        let textBlocks = parseTitleText(title)
        guard !textBlocks.isEmpty else { return nil }

        let alignment = parseAlignment(title)
        let vpos = parseVerticalPlacement(title)

        var sub = Subtitle(
            startTime: baseOffset.map { startTime.offset(by: $0) } ?? startTime,
            endTime: baseOffset.map { endTime.offset(by: $0) } ?? endTime,
            textBlocks: textBlocks,
            verticalPosition: vpos,
            alignment: alignment,
            useCustomPosition: alignment != .center || vpos != .safeArea(.bottom),
            isAI: false
        )

        // SDH heuristics: detect music / off-screen / forced from text, mirroring
        // the convention used by the TTML importer.
        let plain = sub.plainText.lowercased()
        if plain.contains("\u{266A}") || plain.hasPrefix("(music") || plain.contains("music ") {
            sub.isMusic = true
        }
        if plain.hasPrefix("(off-screen)") || plain.hasPrefix("(off screen)") || plain.hasPrefix("(vo)") || plain.hasPrefix("(voice") {
            sub.isOffSpeech = true
        }
        return sub
    }

    /// Extract `TextBlock`s from a `<title>` element.
    ///
    /// FCPXML titles embed text in a `<text>` child. The text may be split
    /// across multiple `<text-style>` runs for inline styling. Newlines within
    /// a title are represented as literal `\n` characters in the text node or
    /// as separate `<text>` children (FCP X typically uses a single `<text>`
    /// with a string value containing line breaks). We split on newlines to
    /// produce one `TextBlock` per line, preserving per-segment styles.
    private static func parseTitleText(_ title: XMLElement) -> [TextBlock] {
        // Locate the <text> child (there is usually exactly one).
        let textElems = (title.children ?? []).compactMap { $0 as? XMLElement }
            .filter { localName($0.name) == "text" }

        if let textElem = textElems.first {
            return collectTextBlocks(textElem, inheritedStyle: [])
        }

        // Some FCPXML variants put text directly inside <title> without a
        // <text> wrapper. Fall back to the element's string value.
        if let raw = title.stringValue, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return splitIntoBlocks(raw, style: [])
        }
        return []
    }

    /// Walk an element's children, collecting text segments and splitting on
    /// newlines to form `TextBlock`s (one per line).
    private static func collectTextBlocks(_ element: XMLElement, inheritedStyle: TextStyle) -> [TextBlock] {
        // First, gather styled segments from <text-style> children, if any.
        var segments: [(String, TextStyle)] = []
        let styledChildren = (element.children ?? []).compactMap { $0 as? XMLElement }
            .filter { localName($0.name) == "text-style" }

        if !styledChildren.isEmpty {
            for child in styledChildren {
                let style = mergeTextStyle(child, inherited: inheritedStyle)
                if let text = child.stringValue, !text.isEmpty {
                    segments.append((text, style))
                }
            }
        }

        // If no <text-style> children, use the element's own text content.
        if segments.isEmpty {
            if let text = element.stringValue, !text.isEmpty {
                segments.append((text, inheritedStyle))
            }
        }

        if segments.isEmpty { return [] }

        // Join all segments into a single string carrying style info, then
        // split on newlines to form one TextBlock per line. We preserve style
        // by associating each character range with its source segment.
        return splitStyledSegmentsIntoBlocks(segments)
    }

    /// Split an array of (text, style) segments into `TextBlock`s on newline
    /// boundaries, preserving the per-segment style for each piece.
    private static func splitStyledSegmentsIntoBlocks(_ segments: [(String, TextStyle)]) -> [TextBlock] {
        var blocks: [TextBlock] = []
        var currentSegments: [TextSegment] = []

        for (text, style) in segments {
            // Split this segment's text on newlines; each newline starts a
            // new TextBlock.
            let parts = text.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i > 0 {
                    // Newline boundary: flush the current line.
                    if !currentSegments.isEmpty {
                        blocks.append(TextBlock(segments: currentSegments))
                        currentSegments = []
                    }
                }
                let trimmed = part
                if !trimmed.isEmpty {
                    currentSegments.append(TextSegment(text: trimmed, style: style))
                }
            }
        }
        if !currentSegments.isEmpty {
            blocks.append(TextBlock(segments: currentSegments))
        }
        return blocks.isEmpty ? [TextBlock(segments: [TextSegment(text: "")])] : blocks
    }

    private static func splitIntoBlocks(_ text: String, style: TextStyle) -> [TextBlock] {
        return splitStyledSegmentsIntoBlocks([(text, style)])
    }

    /// Map FCPXML `<text-style>` font-style / font-weight attributes onto the
    /// core `TextStyle` OptionSet.
    private static func mergeTextStyle(_ element: XMLElement, inherited: TextStyle) -> TextStyle {
        var style = inherited
        if let fontStyle = element.attribute(forName: "fontStyle")?.stringValue {
            if fontStyle == "italic" || fontStyle == "oblique" { style.insert(.italic) }
            else if fontStyle == "normal" { style.remove(.italic) }
        }
        if let fontWeight = element.attribute(forName: "fontWeight")?.stringValue {
            if fontWeight == "bold" { style.insert(.bold) }
            else if fontWeight == "normal" { style.remove(.bold) }
        }
        // FCPXML sometimes uses <i> / <b> child elements for inline styling.
        let local = localName(element.name)
        if local == "i" { style.insert(.italic) }
        if local == "b" { style.insert(.bold) }
        return style
    }

    /// Infer horizontal alignment from a `<title>` element. FCPXML titles
    /// carry alignment via a `<param name="Alignment">` element or a
    /// `<text-style>` `alignment` attribute. Default to center.
    private static func parseAlignment(_ title: XMLElement) -> TextAlignment {
        // Look for <param name="Alignment"> children.
        for child in (title.children ?? []).compactMap({ $0 as? XMLElement }) {
            if localName(child.name) == "param",
               child.attribute(forName: "name")?.stringValue == "Alignment" {
                let value = child.attribute(forName: "value")?.stringValue ?? ""
                switch value.lowercased() {
                case "1", "left":  return .left
                case "2", "center": return .center
                case "3", "right": return .right
                default: break
                }
            }
        }
        // Fall back to a <text-style> alignment attribute.
        for child in (title.children ?? []).compactMap({ $0 as? XMLElement }) {
            if localName(child.name) == "text-style",
               let align = child.attribute(forName: "alignment")?.stringValue {
                switch align.lowercased() {
                case "left":  return .left
                case "right": return .right
                case "center": return .center
                case "start": return .start
                case "end":   return .end
                default: break
                }
            }
        }
        return .center
    }

    /// Parse an FCPXML rational time string such as "3201/2400s" or "1001/24000s".
    /// Returns a `Timecode` in the given frame rate. Also handles plain
    /// seconds ("1.5s") and integer seconds ("2s").
    ///
    /// Note: `Timecode` is frame-quantized, so the returned timecode's
    /// `seconds` may differ from the input by up to one frame. Use
    /// `parseRationalSecondsValue` when you need the exact fractional seconds.
    public static func parseRationalSeconds(_ str: String, frameRate: FrameRate) -> Timecode? {
        guard let seconds = parseRationalSecondsValue(str) else { return nil }
        return Timecode.fromSeconds(seconds, frameRate: frameRate)
    }

    /// Parse an FCPXML rational time string and return the exact seconds
    /// value as a `Double`, without frame quantization.
    public static func parseRationalSecondsValue(_ str: String) -> Double? {
        let s = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasSuffix("s") else { return nil }
        let body = String(s.dropLast())

        // "num/den" rational form.
        if let slash = body.firstIndex(of: "/") {
            let numStr = String(body[..<slash])
            let denStr = String(body[body.index(after: slash)...])
            guard let num = Double(numStr), let den = Double(denStr), den != 0 else {
                return nil
            }
            return num / den
        }

        // Plain decimal seconds.
        if let seconds = Double(body) {
            return seconds
        }
        return nil
    }

    /// Detect the project frame rate from a `<sequence frameDuration="...">`
    /// attribute. FCPXML stores the per-frame duration as a rational (e.g.
    /// "1001/24000s" for 23.976 fps). Returns nil if not present.
    private static func detectFrameRate(_ root: XMLElement) -> FrameRate? {
        let sequences = findElements(root: root, localName: "sequence")
        for seq in sequences {
            if let durStr = seq.attribute(forName: "frameDuration")?.stringValue {
                // Parse the rational directly without going through Timecode,
                // which would quantize to integer frames and lose precision.
                if let frameDuration = parseRationalSecondsValue(durStr), frameDuration > 0 {
                    let fps = 1.0 / frameDuration
                    for rate in FrameRate.allCases {
                        if abs(rate.value - fps) < 0.01 { return rate }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - XML Helpers

    private static func localName(_ name: String?) -> String {
        guard let name = name else { return "" }
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    private static func findElements(root: XMLElement, localName target: String) -> [XMLElement] {
        findElements(root: root, localNames: [target])
    }

    /// Find every descendant (and the root) whose local name is one of `targets`,
    /// in document order. Used to gather `<title>` and `<caption>` cues together.
    private static func findElements(root: XMLElement, localNames targets: Set<String>) -> [XMLElement] {
        var results: [XMLElement] = []
        func walk(_ elem: XMLElement) {
            if targets.contains(localName(elem.name)) {
                results.append(elem)
            }
            for child in (elem.children ?? []).compactMap({ $0 as? XMLElement }) {
                walk(child)
            }
        }
        walk(root)
        return results
    }

    /// Read a caption's vertical placement from its `<text placement="…">`
    /// attribute. Defaults to bottom (the subtitle convention); only an explicit
    /// `top` differs. `<title>` elements have no placement and fall through.
    private static func parseVerticalPlacement(_ element: XMLElement) -> VerticalPosition {
        for child in (element.children ?? []).compactMap({ $0 as? XMLElement })
        where localName(child.name) == "text" {
            if let p = child.attribute(forName: "placement")?.stringValue?.lowercased(), p == "top" {
                return .safeArea(.top)
            }
        }
        return .safeArea(.bottom)
    }
}

// MARK: - FCPXML (Final Cut Pro X XML) Exporter

/// Final Cut Pro X XML (`.fcpxml`) subtitle format exporter.
///
/// Emits each subtitle as a `<title>` clip on the sequence spine — the one
/// structure DaVinci Resolve's importer reliably accepts (Resolve rejects
/// `<caption>` connected to a `<gap>`: "unexpected sub-element Caption"). Titles
/// reference the format rather than a Motion `.moti` effect, so Resolve logs a
/// benign "title effect not found" and substitutes its own text generator.
///
/// To stop that generator landing the text centred, every title carries an
/// `<adjust-transform>` that pushes it into the lower third (or the upper third
/// for top-positioned cues), so subtitles arrive where they belong without the
/// editor repositioning all of them by hand.
public struct FCPXMLExporter: FormatExporter {
    public static let formatID = FormatID.fcpxml
    public static let formatName = String(localized: "FCP X XML (.fcpxml)")
    public static let fileExtension = "fcpxml"

    /// Timebase used for rational time output. 2400 is divisible by 24, 25,
    /// and 30, so it yields exact rational representations for those frame
    /// rates without floating-point rounding.
    private static let timebase: Int64 = 2400

    /// Vertical transform offset (in 1080p pixels from centre, +up) that drops a
    /// bottom cue into the subtitle safe area / lifts a top cue to match.
    private static let bottomY = -400
    private static let topY = 400

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        let opts = options ?? ExportOptions()
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        let frameRate = opts.sourceFrameRate ?? track.subtitles.first?.startTime.frameRate ?? .fps25
        let frameDuration = formatRationalSeconds(1.0 / frameRate.value)
        let minDuration = 1.0 / frameRate.value
        let projectName = track.name.isEmpty ? "AlphaSub Export" : track.name

        let subs = track.subtitles.sorted { $0.startTime.seconds < $1.startTime.seconds }
        let totalSeconds = subs.map { max($0.endTime.seconds, $0.startTime.seconds + minDuration) }.max() ?? 0
        let totalStr = formatRationalSeconds(totalSeconds)

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<fcpxml version=\"1.11\">\n"
        xml += "  <resources>\n"
        xml += "    <format id=\"r1\" frameDuration=\"\(frameDuration)\" name=\"FFFormatDefaultVideoFormat\" width=\"1920\" height=\"1080\"/>\n"
        xml += "  </resources>\n"
        xml += "  <library>\n"
        xml += "    <event name=\"AlphaSub Export\">\n"
        xml += "      <project name=\"\(escapeXML(projectName))\">\n"
        xml += "        <sequence format=\"r1\" frameDuration=\"\(frameDuration)\" tcFormat=\"NDF\" tcStart=\"0s\" duration=\"\(totalStr)\">\n"
        xml += "          <spine>\n"

        for sub in subs {
            let offsetStr = formatRationalSeconds(sub.startTime.seconds)
            let durSeconds = max(sub.endTime.seconds - sub.startTime.seconds, minDuration)
            let durStr = formatRationalSeconds(durSeconds)

            xml += "            <title offset=\"\(offsetStr)\" duration=\"\(durStr)\" name=\"\(escapeXML(subtitleName(sub)))\" ref=\"r1\">\n"
            xml += "              <adjust-transform position=\"0 \(transformY(sub.verticalPosition))\"/>\n"
            xml += "              <param name=\"Alignment\" value=\"\(alignmentParam(sub.alignment))\"/>\n"
            xml += "              <text>\n"
            xml += formatTitleText(sub.textBlocks)
            xml += "              </text>\n"
            xml += "            </title>\n"
        }

        xml += "          </spine>\n"
        xml += "        </sequence>\n"
        xml += "      </project>\n"
        xml += "    </event>\n"
        xml += "  </library>\n"
        xml += "</fcpxml>\n"

        guard let data = xml.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode FCPXML as UTF-8")
        }
        return data
    }

    // MARK: - Formatting Helpers

    /// Convert a seconds value to a "num/den s" rational string using the
    /// timebase. For example, 1.0 second with a 2400 timebase becomes
    /// "2400/2400s". Sub-frame precision is preserved by scaling.
    public static func formatRationalSeconds(_ seconds: Double) -> String {
        let num = (seconds * Double(timebase)).rounded()
        return "\(Int64(num))/\(timebase)s"
    }

    /// Vertical transform offset for a cue: lower third for bottom cues (the
    /// subtitle default), upper third for top cues, centred otherwise.
    private static func transformY(_ position: VerticalPosition) -> Int {
        switch position {
        case .safeArea(.bottom):  return bottomY
        case .safeArea(.top):     return topY
        case .safeArea(.center):  return 0
        case .row(let r):         return r <= 11 ? topY : bottomY
        case .lineShift:          return bottomY
        case .percentage(let p):  return Int((50.0 - p) / 50.0 * Double(topY))
        }
    }

    /// FCP `<param name="Alignment">` value: 1 left, 2 centre, 3 right.
    private static func alignmentParam(_ alignment: TextAlignment) -> String {
        switch alignment {
        case .left, .start: return "1"
        case .right, .end:  return "3"
        default:            return "2"
        }
    }

    /// Render `TextBlock`s as `<text-style>` runs. Each line is its own run, with
    /// a newline-only run between lines (the structure Final Cut and Resolve both
    /// accept). Inline italic/bold is emitted per run.
    private static func formatTitleText(_ blocks: [TextBlock]) -> String {
        var out = ""
        for (i, block) in blocks.enumerated() {
            for segment in block.segments {
                var attrs = ""
                if segment.style.contains(.italic) { attrs += " fontStyle=\"italic\"" }
                if segment.style.contains(.bold) { attrs += " fontWeight=\"bold\"" }
                out += "                <text-style\(attrs)>\(escapeXML(segment.text))</text-style>\n"
            }
            if i < blocks.count - 1 {
                out += "                <text-style>\n</text-style>\n"
            }
        }
        return out
    }

    private static func subtitleName(_ sub: Subtitle) -> String {
        let plain = sub.plainText.replacingOccurrences(of: "\n", with: " ")
        return plain.isEmpty ? "Title" : String(plain.prefix(40))
    }

    public static func escapeXML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}