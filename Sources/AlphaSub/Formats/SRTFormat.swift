import Foundation
import AlphaSubCore

// MARK: - SRT Importer

public struct SRTImporter: FormatImporter {
    public static let formatID = FormatID.srt
    public static let formatName = String(localized: "SubRip (SRT)")
    public static let fileExtensions = ["srt"]

    public static func canImport(_ data: Data) -> Bool {
        // SRT files start with a number "1" followed by newline
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        // First line should be "1"
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? ""
        return Int(firstLine) != nil
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        let encoding = opts.encoding ?? detectEncoding(data)
        guard let str = String(data: data, encoding: encoding) else {
            throw FormatError.unsupportedEncoding("Cannot decode SRT with detected encoding")
        }

        let normalized = str
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let blocks = parseSRTBlocks(normalized)
        let frameRate = opts.targetFrameRate ?? .fps25

        let subtitles: [Subtitle] = try blocks.map { block in
            try parseBlock(block, frameRate: frameRate)
        }

        let track = Track(
            name: "SRT Import",
            language: opts.defaultLanguage ?? "",
            subtitles: subtitles,
            formatOrigin: "srt"
        )

        return [track]
    }

    // MARK: - Private Parsing

    /// Split raw SRT text into cue blocks.
    ///
    /// SRT cues are normally separated by blank lines. We split on blank lines
    /// first, then re-split any block that contains more than one timecode line
    /// (which means blank-line separators were missing between cues).
    ///
    /// Within each resulting block, the line before the timecode (if it's a
    /// lone integer) is the cue index. Everything after the timecode is
    /// subtitle text — even bare numbers like "3" or "1984".
    private static func parseSRTBlocks(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        let n = lines.count

        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        func isTimecode(_ s: String) -> Bool { s.contains("-->") }

        // Phase 1: split on blank lines into raw groups
        var rawGroups: [[String]] = []
        var i = 0
        while i < n {
            if isBlank(lines[i]) { i += 1; continue }
            var group: [String] = []
            while i < n, !isBlank(lines[i]) {
                group.append(lines[i])
                i += 1
            }
            if !group.isEmpty { rawGroups.append(group) }
        }

        // Phase 1b: a stray blank line between a cue index and its timecode
        // orphans that index at the END of the previous group, e.g.
        //
        //     1
        //     00:00:01,000 --> 00:00:04,000
        //     Line one
        //     Line two
        //     2            ← index for the next cue, blank line follows
        //
        //     00:00:05,000 --> 00:00:08,000
        //     Next
        //
        // The trailing "2" would otherwise be swept into cue 1's text as an
        // extra line. If the group has its own timecode (so it's a real cue)
        // and the NEXT group begins with a timecode, that trailing lone
        // integer is the next cue's index — move it onto the next group.
        // A genuine numeric last line ("Chapter\n7") is left untouched because
        // the next group there starts with an index, not a timecode (or there
        // is no next group at all).
        for gi in rawGroups.indices.dropLast() {
            guard let last = rawGroups[gi].last,
                  Int(last.trimmingCharacters(in: .whitespaces)) != nil,
                  rawGroups[gi].contains(where: isTimecode),
                  let firstNext = rawGroups[gi + 1].first, isTimecode(firstNext)
            else { continue }
            let idx = rawGroups[gi].removeLast()
            rawGroups[gi + 1].insert(idx, at: 0)
        }

        // Phase 2: for groups with multiple timecode lines, re-split at
        // each timecode boundary. A timecode line preceded by a lone integer
        // means the integer is a cue index — include it with the new cue.
        var blocks: [String] = []
        for group in rawGroups {
            let tcCount = group.filter { isTimecode($0) }.count
            if tcCount <= 1 {
                // Standard: one cue per group (blank-line separators present)
                if tcCount == 1 {
                    blocks.append(group.joined(separator: "\n"))
                } else if group.count == 1, Int(group[0].trimmingCharacters(in: .whitespaces)) != nil {
                    // Dangling cue index with no timecode — skip it (invalid SRT,
                    // but common at EOF or when blank lines appear between an
                    // index and its timecode). Don't treat it as subtitle text.
                } else if !group.isEmpty {
                    // Non-index text without a timecode — could be subtitle text
                    // whose timecode was lost, but more likely garbage. Skip.
                }
                continue
            }

            // Multiple timecodes = missing separators. Re-split at each TC.
            // Scan backwards so we can easily grab the preceding index line.
            var tcPositions: [Int] = []
            for j in 0..<group.count {
                if isTimecode(group[j]) { tcPositions.append(j) }
            }

            for (k, tcPos) in tcPositions.enumerated() {
                var cue: [String] = []
                // If the line immediately before the timecode is a lone integer,
                // it's the cue index for this cue, not subtitle text.
                if tcPos > 0, Int(group[tcPos - 1].trimmingCharacters(in: .whitespaces)) != nil {
                    // But only if the previous timecode isn't also at tcPos-1
                    if k == 0 || tcPositions[k - 1] < tcPos - 1 {
                        cue.append(group[tcPos - 1])
                    }
                }
                // Timecode line
                cue.append(group[tcPos])
                // Collect text lines until the next timecode's index (if any)
                let textStart = tcPos + 1
                let textEnd: Int
                if k + 1 < tcPositions.count {
                    // Stop before the next cue's index line (if any) or timecode
                    let nextTC = tcPositions[k + 1]
                    if nextTC > tcPos + 1, Int(group[nextTC - 1].trimmingCharacters(in: .whitespaces)) != nil {
                        textEnd = nextTC - 1
                    } else {
                        textEnd = nextTC
                    }
                } else {
                    textEnd = group.count
                }
                for j in textStart..<textEnd {
                    cue.append(group[j])
                }
                blocks.append(cue.joined(separator: "\n"))
            }
        }
        return blocks
    }

    /// Parse a single SRT block into a Subtitle.
    private static func parseBlock(_ block: String, frameRate: FrameRate) throws -> Subtitle {
        let lines = block.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Anchor on the timecode line wherever it sits; an index line (if any)
        // precedes it and is discarded, text is everything after it.
        guard let tcIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
            throw FormatError.invalidData("Invalid SRT block: \(block.prefix(50))")
        }

        let timeLine = lines[tcIndex].replacingOccurrences(of: " ", with: "")
        let parts = timeLine.components(separatedBy: "-->")
        guard parts.count == 2 else {
            throw FormatError.timecodeParseError("Invalid timecode line: \(lines[tcIndex])")
        }

        let start = try parseSRTTimecode(String(parts[0]), frameRate: frameRate)
        let end = try parseSRTTimecode(String(parts[1]), frameRate: frameRate)

        // Remaining lines are subtitle text
        let textLines = Array(lines.suffix(from: tcIndex + 1))
        let textBlocks = parseSRTText(textLines)

        // SDH: Detect music/off-screen/speaker patterns in SRT text
        let plainText = textBlocks.map { $0.plainText }.joined(separator: " ")
        let lowerText = plainText.lowercased()
        let isMusic = lowerText.contains("♪") || lowerText.hasPrefix("(music") || lowerText.contains("music ")
        let isOffSpeech = lowerText.hasPrefix("(off-screen)") || lowerText.hasPrefix("(off screen)")
            || lowerText.hasPrefix("(vo)") || lowerText.hasPrefix("(voice-over)")
            || lowerText.hasPrefix("(voiceover)")

        // SDH: Detect speaker prefix (e.g., "JOHN: Hello")
        var speaker = ""
        if let colonRange = plainText.range(of: ": "), plainText.distance(from: plainText.startIndex, to: colonRange.lowerBound) <= 20 {
            let potentialSpeaker = String(plainText[..<colonRange.lowerBound])
            let stripped = potentialSpeaker.trimmingCharacters(in: .whitespaces)
            if stripped.count >= 2 && stripped.count <= 15 && stripped.allSatisfy({ $0.isLetter || $0.isWhitespace || $0 == "-" }) {
                speaker = stripped.uppercased()
            }
        }

        let placement = extractPosition(from: textLines)
        return Subtitle(
            startTime: start,
            endTime: end,
            textBlocks: textBlocks,
            verticalPosition: placement.vertical,
            horizontalPosition: placement.horizontal,
            alignment: placement.alignment,
            // Without this flag, effectivePosition() falls back to the track
            // default and a parsed {\anN} placement is silently discarded.
            useCustomPosition: placement.vertical != .safeArea(.bottom)
                || placement.horizontal != .centered
                || placement.alignment != .center,
            isMusic: isMusic,
            isOffSpeech: isOffSpeech,
            isNewScene: lowerText.hasPrefix("[new scene]") || lowerText.hasPrefix("[scene change]"),
            speaker: speaker
        )
    }

    /// Parse SRT-style timecode: "00:00:27,520" or "00:00:27:12"
    private static func parseSRTTimecode(_ str: String, frameRate: FrameRate) throws -> Timecode {
        // HH:MM:SS,mmm (SRT standard: comma = milliseconds)
        if str.contains(",") {
            let parts = str.components(separatedBy: ",")
            guard parts.count == 2,
                  let ms = Int(parts[1].padding(toLength: 3, withPad: "0", startingAt: 0))
            else {
                throw FormatError.timecodeParseError(str)
            }
            let hms = try parseHMS(String(parts[0]))
            let totalSeconds = Double(hms.h * 3600 + hms.m * 60 + hms.s) + Double(ms) / 1000.0
            return Timecode.fromSeconds(totalSeconds, frameRate: frameRate)
        }
        // HH:MM:SS:FF (frame-based, used by some tools)
        if str.contains(":") && str.split(separator: ":").count == 4 {
            return try Timecode.parse(str, frameRate: frameRate)
        }
        // HH:MM:SS.mmm
        if str.contains(".") {
            let parts = str.components(separatedBy: ".")
            guard parts.count == 2,
                  let ms = Int(parts[1].padding(toLength: 3, withPad: "0", startingAt: 0))
            else {
                throw FormatError.timecodeParseError(str)
            }
            let hms = try parseHMS(String(parts[0]))
            let totalSeconds = Double(hms.h * 3600 + hms.m * 60 + hms.s) + Double(ms) / 1000.0
            return Timecode.fromSeconds(totalSeconds, frameRate: frameRate)
        }
        throw FormatError.timecodeParseError(str)
    }

    private static func parseHMS(_ str: String) throws -> (h: Int, m: Int, s: Int) {
        let parts = str.components(separatedBy: ":")
        guard parts.count == 3,
              let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2])
        else {
            throw FormatError.timecodeParseError(str)
        }
        return (h, m, s)
    }

    /// Parse SRT text with <i>/<b>/<u>/<font> tags into TextBlocks.
    private static func parseSRTText(_ lines: [String]) -> [TextBlock] {
        return lines.map { line in
            let segments = parseSRTLineIntoTextSegments(line)
            return TextBlock(segments: segments)
        }
    }

    /// Parse a single line for HTML-like SRT style tags.
    private static func parseSRTLineIntoTextSegments(_ line: String) -> [TextSegment] {
        // Simple state machine: start with no style, toggle on <i>/<b>/<u>;
        // <font color> pushes a colour, </font> pops back to the outer one.
        var segments: [TextSegment] = []
        var currentText = ""
        var currentStyle: TextStyle = []
        var currentColor: TextColor?
        var colorStack: [TextColor?] = []
        var i = line.startIndex

        while i < line.endIndex {
            if line[i] == "{" {
                // SSA/ASS override block, e.g. {\an2}, {\i1}, {\i1\b1}. These are
                // not subtitle text — they carry styling/positioning. Apply the
                // inline style toggles we model and strip the block entirely so
                // the tag never leaks into the rendered text (positioning is read
                // separately by extractPosition).
                if let closeIndex = line[i...].firstIndex(of: "}") {
                    let tagContent = String(line[line.index(after: i)..<closeIndex])
                    if tagContent.hasPrefix("\\") {
                        if !currentText.isEmpty {
                            segments.append(TextSegment(text: currentText, style: currentStyle, color: currentColor))
                            currentText = ""
                        }
                        applyASSOverrides(tagContent, to: &currentStyle)
                        i = line.index(after: closeIndex)
                        continue
                    }
                }
                // A literal "{" that isn't an override block — keep it as text.
                currentText.append(line[i])
                i = line.index(after: i)
                continue
            }
            if line[i] == "<" {
                // Check for closing tag
                if let closeIndex = line[i...].firstIndex(of: ">") {
                    let tagContent = String(line[line.index(after: i)..<closeIndex])
                    let tag = tagContent.lowercased()

                    // Save current segment
                    if !currentText.isEmpty {
                        segments.append(TextSegment(text: currentText, style: currentStyle, color: currentColor))
                        currentText = ""
                    }

                    // Apply or remove style
                    switch tag {
                    case "i", "italic":                currentStyle.insert(.italic)
                    case "/i", "/italic":              currentStyle.remove(.italic)
                    case "b", "bold":                  currentStyle.insert(.bold)
                    case "/b", "/bold":                currentStyle.remove(.bold)
                    case "u", "underline":             currentStyle.insert(.underline)
                    case "/u", "/underline":           currentStyle.remove(.underline)
                    case "s", "strikethrough":         currentStyle.insert(.strikethrough)
                    case "/s", "/strikethrough":       currentStyle.remove(.strikethrough)
                    case "/font":
                        currentColor = colorStack.popLast() ?? nil
                    default:
                        if tag.hasPrefix("font") {
                            colorStack.append(currentColor)
                            if let c = fontColor(from: tagContent) { currentColor = c }
                        }
                        // Other tags (<ruby>, …) are ignored.
                    }

                    i = line.index(after: closeIndex)
                } else {
                    // Broken tag — treat as text
                    currentText.append(line[i])
                    i = line.index(after: i)
                }
            } else {
                currentText.append(line[i])
                i = line.index(after: i)
            }
        }

        // Flush remaining text
        if !currentText.isEmpty {
            segments.append(TextSegment(text: currentText, style: currentStyle, color: currentColor))
        }

        // Empty after parsing (e.g. a line that was only override tags) → an
        // empty segment, never the raw line, so stripped tags can't reappear.
        return segments.isEmpty ? [TextSegment(text: "", style: [])] : segments
    }

    /// Extract the colour of a `<font color="...">` tag (named CSS colour or
    /// #hex). Returns nil for `<font>` tags without a parseable colour.
    private static func fontColor(from tagContent: String) -> TextColor? {
        guard let range = tagContent.range(of: "color", options: .caseInsensitive) else { return nil }
        var rest = tagContent[range.upperBound...].drop { $0 == " " || $0 == "=" }
        // The value may be quoted (single or double) or bare.
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            rest = rest.prefix { $0 != quote }
        } else {
            rest = rest.prefix { $0 != " " }
        }
        let value = String(rest)
        return TextColor(hex: value) ?? TextColor(named: value)
    }

    /// Apply the inline-style toggles of an SSA/ASS override block such as
    /// `\i1`, `\b0`, or a combined `\i1\b1`. Codes we don't model (positioning
    /// `\an`, `\pos`, colour `\c`, font `\fn`/`\fs`, …) are ignored — the block
    /// itself has already been removed from the text by the caller.
    private static func applyASSOverrides(_ content: String, to style: inout TextStyle) {
        // A block is a run of "\code" segments; split on the backslash.
        for raw in content.split(separator: "\\") where !raw.isEmpty {
            let code = raw.lowercased()
            // For \iN \bN \uN \sN, any non-zero value turns the style on
            // (\b700 is a bold weight), 0 turns it off.
            func toggle(_ prefix: Character) -> Bool? {
                guard code.first == prefix, let n = Int(code.dropFirst()) else { return nil }
                return n > 0
            }
            func set(_ member: TextStyle, _ on: Bool) {
                if on { style.insert(member) } else { style.remove(member) }
            }
            if let on = toggle("i") { set(.italic, on) }
            else if let on = toggle("b") { set(.bold, on) }
            else if let on = toggle("u") { set(.underline, on) }
            else if let on = toggle("s") { set(.strikethrough, on) }
        }
    }

    /// Screen position + text alignment derived from an SSA/ASS `\anN` tag.
    struct ASSPlacement {
        var vertical: VerticalPosition = .safeArea(.bottom)
        var horizontal: HorizontalPosition = .centered
        var alignment: TextAlignment = .center
    }

    /// Parse the first `{\anN}` numpad-alignment tag into a placement. The numpad
    /// layout is 1–3 bottom, 4–6 middle, 7–9 top, with columns left/centre/right.
    /// `\an2` (and the absence of any tag) is the SRT default: bottom-centre.
    private static func extractPosition(from lines: [String]) -> ASSPlacement {
        var placement = ASSPlacement()
        for line in lines {
            guard let r = line.range(of: #"\an"#),
                  let digit = line[r.upperBound...].first,
                  let n = digit.wholeNumberValue, (1...9).contains(n)
            else { continue }

            switch (n - 1) % 3 {       // column
            case 0:  placement.horizontal = .leftAligned;  placement.alignment = .left
            case 2:  placement.horizontal = .rightAligned; placement.alignment = .right
            default: placement.horizontal = .centered;     placement.alignment = .center
            }
            switch (n - 1) / 3 {       // row band
            case 2:  placement.vertical = .safeArea(.top)
            case 1:  placement.vertical = .safeArea(.center)
            default: placement.vertical = .safeArea(.bottom)
            }
            return placement
        }
        return placement
    }

    private static func detectEncoding(_ data: Data) -> String.Encoding {
        // Try UTF-8 BOM first
        if data.count >= 3 {
            let bom = data.prefix(3)
            if bom == Data([0xEF, 0xBB, 0xBF]) { return .utf8 }
            if bom == Data([0xFF, 0xFE]) || bom == Data([0xFE, 0xFF]) { return .utf16 }
        }
        // Try UTF-8, fall back to Latin-1
        if let _ = String(data: data, encoding: .utf8) { return .utf8 }
        return .isoLatin1
    }
}

// MARK: - SRT Exporter

public struct SRTExporter: FormatExporter {
    public static let formatID = FormatID.srt
    public static let formatName = String(localized: "SubRip (SRT)")
    public static let fileExtension = "srt"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        let opts = options ?? ExportOptions()
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        var output = ""
        if opts.includeBOM { output = "\u{FEFF}" }

        _ = opts.sourceFrameRate ?? track.subtitles.first?.startTime.frameRate ?? .fps25

        let sdhMode = opts.extra["sdh"] == "true"
        // Position override tags ({\anN}) are an SSA/ASS extension that only some
        // players honour — DaVinci Resolve, Premiere and others render them on
        // screen as literal text. Off by default so the output is plain SRT;
        // opt in for VLC-style players that interpret them.
        let includePositionTags = opts.extra["srt_position_tags"] == "true"

        for (index, sub) in track.subtitles.enumerated() {
            let num = index + 1
            output += "\(num)\n"
            output += "\(formatSRTTimecode(sub.startTime)) --> \(formatSRTTimecode(sub.endTime))\n"
            var text = formatSRTText(sub.textBlocks, sdhMode: sdhMode, subtitle: sub)
            if includePositionTags, let tag = srtPositionTag(sub) { text = tag + text }
            if sdhMode {
                if sub.isMusic     { text = "♪ " + text }
                if sub.isOffSpeech { text = "(OFF-SCREEN) " + text }
                if sub.isForced    { text = "(FORCED) " + text }
                if sub.isNewScene  { text = "[NEW SCENE] " + text }
                if !sub.speaker.isEmpty { text = sub.speaker + ": " + text }
            }
            output += text + "\n\n"
        }

        guard let data = output.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode SRT as UTF-8")
        }
        return data
    }

    /// Format timecode as "00:00:27,520"
    private static func formatSRTTimecode(_ tc: Timecode) -> String {
        let (h, m, s, _) = tc.components
        let ms = tc.milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// SSA/ASS {\anX} numpad alignment tag (omitted for the default bottom-centre).
    /// Layout:  7 8 9 / 4 5 6 / 1 2 3  (numpad positions)
    private static func srtPositionTag(_ sub: Subtitle) -> String? {
        let row: Int
        switch sub.verticalPosition {
        case .safeArea(.top):    row = 6
        case .safeArea(.center): row = 3
        default:                 row = 0   // bottom (incl. lineShift)
        }
        let col: Int
        switch sub.alignment {
        case .left, .start:  col = 0
        case .right, .end:   col = 2
        default:             col = 1       // centre
        }
        let code = row + col + 1
        return code == 2 ? nil : "{\\an\(code)}"  // 2 = bottom-centre = default
    }

    /// Format TextBlocks into SRT lines with <i>/<b> markup.
    private static func formatSRTText(_ blocks: [TextBlock], sdhMode: Bool = false, subtitle: Subtitle? = nil) -> String {
        return blocks.map { block in
            block.segments.map { segment in
                var text = segment.text
                if segment.style.contains(.bold)      { text = "<b>\(text)</b>" }
                if segment.style.contains(.italic)    { text = "<i>\(text)</i>" }
                if segment.style.contains(.underline) { text = "<u>\(text)</u>" }
                if segment.style.contains(.strikethrough) { text = "<s>\(text)</s>" }
                if let color = segment.color { text = "<font color=\"\(color.hexString)\">\(text)</font>" }
                return text
            }.joined()
        }.joined(separator: "\n")
    }
}
