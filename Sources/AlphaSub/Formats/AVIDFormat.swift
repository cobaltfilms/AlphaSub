import Foundation
import AlphaSubCore

// MARK: - AVID Importer

/// AVID DS MC .txt subtitle format importer.
/// Formats: AVID DS (tab-separated) or AVID MC (numbered with timecodes on separate lines).
public struct AVIDImporter: FormatImporter {
    public static let formatID = FormatID.avid
    public static let formatName = String(localized: "AVID DS/MC (.txt)")
    public static let fileExtensions = ["txt"]

    public static func canImport(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        // AVID DS format: tabs with timecode\ttext on each line
        // AVID MC format: numbered lines with separate timecode lines
        let lines = trimmed.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var avidDsLines = 0
        for line in lines.prefix(20) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("\t") && matchesAVIDDsLine(t) { avidDsLines += 1 }
        }
        return avidDsLines >= 2
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw FormatError.unsupportedEncoding("Cannot decode AVID data")
        }

        let normalized = str
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.components(separatedBy: "\n")
        let frameRate = opts.targetFrameRate ?? .fps25

        // Detect format
        let isDsFormat = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(5)
            .filter { $0.contains("\t") && matchesAVIDDsLine($0) }
            .count >= 2

        let subtitles: [Subtitle]
        if isDsFormat {
            subtitles = parseDsFormat(lines, frameRate: frameRate)
        } else {
            subtitles = parseMcFormat(lines, frameRate: frameRate)
        }

        return [Track(
            name: "AVID Import",
            language: opts.defaultLanguage ?? "",
            subtitles: subtitles,
            formatOrigin: "avid",
            frameRate: opts.targetFrameRate
        )]
    }

    // MARK: - AVID DS Format (tab-separated: IN\tOUT\tTEXT)

    private static func matchesAVIDDsLine(_ line: String) -> Bool {
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 3 else { return false }
        return parseAVIDTime(parts[0].trimmingCharacters(in: .whitespaces), frameRate: .fps25) != nil
            && parseAVIDTime(parts[1].trimmingCharacters(in: .whitespaces), frameRate: .fps25) != nil
    }

    private static func parseDsFormat(_ lines: [String], frameRate: FrameRate) -> [Subtitle] {
        var subtitles: [Subtitle] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("\t") else { continue }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }

            let startStr = parts[0].trimmingCharacters(in: .whitespaces)
            let endStr = parts[1].trimmingCharacters(in: .whitespaces)
            let text = parts[2...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)

            guard let startTC = parseAVIDTime(startStr, frameRate: frameRate),
                  let endTC = parseAVIDTime(endStr, frameRate: frameRate)
            else { continue }

            let textBlocks = text.components(separatedBy: "\n").map { lineStr in
                TextBlock(segments: [TextSegment(text: lineStr.trimmingCharacters(in: .whitespaces))])
            }

            subtitles.append(Subtitle(
                startTime: startTC,
                endTime: endTC,
                textBlocks: textBlocks,
                verticalPosition: .safeArea(.bottom)
            ))
        }
        return subtitles
    }

    // MARK: - AVID MC Format (numbered: 1\nTC\nTEXT)

    private static func parseMcFormat(_ lines: [String], frameRate: FrameRate) -> [Subtitle] {
        var subtitles: [Subtitle] = []
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard Int(line) != nil else { i += 1; continue }

            i += 1
            guard i < lines.count else { break }
            let tcLine = lines[i].trimmingCharacters(in: .whitespaces)

            let tcParts = tcLine.components(separatedBy: " ").filter { !$0.isEmpty }
            guard tcParts.count >= 2 else { i += 1; continue }

            let startTC = parseAVIDTime(tcParts[0], frameRate: frameRate)
            let endTC = parseAVIDTime(tcParts[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "->"))), frameRate: frameRate)

            guard let start = startTC, let end = endTC else { i += 1; continue }

            i += 1
            var textLines: [String] = []
            while i < lines.count {
                let nextLine = lines[i].trimmingCharacters(in: .whitespaces)
                if nextLine.isEmpty || Int(nextLine) != nil { break }
                textLines.append(nextLine)
                i += 1
            }

            let textBlocks = textLines.map { TextBlock(segments: [TextSegment(text: $0)]) }
            subtitles.append(Subtitle(
                startTime: start,
                endTime: end,
                textBlocks: textBlocks,
                verticalPosition: .safeArea(.bottom)
            ))
        }

        return subtitles
    }

    // MARK: - AVID Time Parsing

    private static func parseAVIDTime(_ str: String, frameRate: FrameRate) -> Timecode? {
        let s = str.trimmingCharacters(in: .whitespacesAndNewlines)

        // HH:MM:SS:FF (SMPTE)
        let colonParts = s.components(separatedBy: ":")
        if colonParts.count == 4,
           let h = Int(colonParts[0]), let m = Int(colonParts[1]),
           let sec = Int(colonParts[2]), let f = Int(colonParts[3]) {
            return Timecode(h: h, m: m, s: sec, f: f, frameRate: frameRate)
        }

        // HH:MM:SS.mmm (millisecond)
        if colonParts.count == 3 {
            let secParts = colonParts[2].components(separatedBy: CharacterSet(charactersIn: ".,"))
            if secParts.count == 2,
               let h = Int(colonParts[0]), let m = Int(colonParts[1]),
               let sec = Int(secParts[0]),
               let ms = Int(secParts[1].padding(toLength: 3, withPad: "0", startingAt: 0)) {
                let total = Double(h * 3600 + m * 60 + sec) + Double(ms) / 1000.0
                return Timecode.fromSeconds(total, frameRate: frameRate)
            }
        }

        return nil
    }
}

// MARK: - AVID Exporter

/// AVID DS MC .txt format exporter.
/// Exports in AVID DS tab-separated format: IN\tOUT\tTEXT
public struct AVIDExporter: FormatExporter {
    public static let formatID = FormatID.avid
    public static let formatName = String(localized: "AVID DS/MC (.txt)")
    public static let fileExtension = "txt"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }
        guard !track.subtitles.isEmpty else {
            throw FormatError.invalidData("No subtitles to export")
        }

        let _ = options?.sourceFrameRate ?? track.subtitles.first?.startTime.frameRate ?? .fps25
        let useFrames = options?.extra["timecode_format"] == "frames"

        var output = ""

        for sub in track.subtitles {
            let startTC = useFrames ? sub.startTime.smpteString : formatMsTimecode(sub.startTime)
            let endTC = useFrames ? sub.endTime.smpteString : formatMsTimecode(sub.endTime)
            let text = sub.textBlocks.map { $0.plainText }.joined(separator: "\\n")
            output += "\(startTC)\t\(endTC)\t\(text)\n"
        }

        guard let data = output.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode AVID as UTF-8")
        }
        return data
    }

    private static func formatMsTimecode(_ tc: Timecode) -> String {
        let (h, m, s, _) = tc.components
        let ms = tc.milliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}