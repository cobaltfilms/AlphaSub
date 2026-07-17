import Foundation
import AlphaSubCore

// MARK: - TXT Importer

/// Plain text subtitle format importer.
/// Supports HH:MM:SS,ms and HH:MM:SS:FF timecode formats.
public struct TXTImporter: FormatImporter {
    public static let formatID = FormatID.txt
    public static let formatName = String(localized: "Plain Text (.txt)")
    public static let fileExtensions = ["txt"]

    public static func canImport(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        let normalized = str
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Reject SRT: starts with a cue index (lone integer) followed by a timecode line.
        // SRT files have the pattern: number\nTC-->TC\ntext\n\nnumber\nTC-->TC\n...
        if lines.first(where: { !$0.isEmpty }) != nil {
            let firstNonBlank = lines.first(where: { !$0.isEmpty })!
            if Int(firstNonBlank) != nil {
                // First non-blank line is a number — looks like an SRT cue index.
                // Check if the next non-blank line is a timecode with "-->".
                let firstIdx = lines.firstIndex(where: { !$0.isEmpty })!
                for j in (firstIdx + 1)..<min(lines.count, firstIdx + 5) {
                    let line = lines[j]
                    if line.isEmpty { continue }
                    if line.contains("-->") { return false }
                    break
                }
            }
        }
        var timecodeLines = 0
        for line in lines.filter({ !$0.isEmpty }).prefix(20) {
            if matchesTXTTimecodeLine(line) {
                timecodeLines += 1
            }
        }
        return timecodeLines >= 2
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw FormatError.unsupportedEncoding("Cannot decode TXT data")
        }

        let normalized = str
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.components(separatedBy: "\n")
        let frameRate = opts.targetFrameRate ?? .fps25
        var subtitles: [Subtitle] = []

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }

            guard let tcLine = parseTXTTimecodeLine(line, frameRate: frameRate) else {
                i += 1
                continue
            }

            var textLines: [String] = []
            i += 1
            while i < lines.count {
                let nextLine = lines[i].trimmingCharacters(in: .whitespaces)
                if nextLine.isEmpty { i += 1; continue }
                if parseTXTTimecodeLine(nextLine, frameRate: frameRate) != nil { break }
                textLines.append(nextLine)
                i += 1
            }

            if !textLines.isEmpty {
                let textBlocks = textLines.map { line in
                    TextBlock(segments: [TextSegment(text: line)])
                }
                subtitles.append(Subtitle(
                    startTime: tcLine.start,
                    endTime: tcLine.end,
                    textBlocks: textBlocks,
                    verticalPosition: .safeArea(.bottom)
                ))
            }
        }

        return [Track(
            name: "TXT Import",
            language: opts.defaultLanguage ?? "",
            subtitles: subtitles,
            formatOrigin: "txt"
        )]
    }

    // MARK: - TXT Parsing

    private struct TXTTimecodeLine {
        var start: Timecode
        var end: Timecode
    }

    private static func matchesTXTTimecodeLine(_ line: String) -> Bool {
        return parseTXTTimecodeLine(line, frameRate: .fps25) != nil
    }

    private static func parseTXTTimecodeLine(_ line: String, frameRate: FrameRate) -> TXTTimecodeLine? {
        // HH:MM:SS,mmm --> HH:MM:SS,mmm (SRT-like with comma ms)
        let arrowPattern = #"\s*-+>\s*"#
        guard let arrowRange = line.range(of: arrowPattern, options: .regularExpression) else { return nil }

        let startStr = String(line[line.startIndex..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let endStr = String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        guard let startTC = parseTXTTime(startStr, frameRate: frameRate),
              let endTC = parseTXTTime(endStr, frameRate: frameRate)
        else { return nil }

        return TXTTimecodeLine(start: startTC, end: endTC)
    }

    private static func parseTXTTime(_ str: String, frameRate: FrameRate) -> Timecode? {
        let s = str.trimmingCharacters(in: .whitespaces)

        // HH:MM:SS:FF (frame-based)
        let frameParts = s.components(separatedBy: ":")
        if frameParts.count == 4,
           let h = Int(frameParts[0]),
           let m = Int(frameParts[1]),
           let sec = Int(frameParts[2]),
           let f = Int(frameParts[3]) {
            return Timecode(h: h, m: m, s: sec, f: f, frameRate: frameRate)
        }

        // HH:MM:SS,mmm or HH:MM:SS.mmm (millisecond-based)
        let normalized = s.replacingOccurrences(of: ",", with: ".")
        let msParts = normalized.components(separatedBy: ":")
        if msParts.count == 3 {
            guard let h = Int(msParts[0]),
                  let m = Int(msParts[1])
            else { return nil }
            let secParts = msParts[2].components(separatedBy: ".")
            guard secParts.count == 2,
                  let sec = Int(secParts[0]),
                  let ms = Int(secParts[1].padding(toLength: 3, withPad: "0", startingAt: 0))
            else { return nil }
            let totalSeconds = Double(h * 3600 + m * 60 + sec) + Double(ms) / 1000.0
            return Timecode.fromSeconds(totalSeconds, frameRate: frameRate)
        }

        // MM:SS,mmm
        let shortMsParts = normalized.components(separatedBy: ":")
        if shortMsParts.count == 2 {
            guard let m = Int(shortMsParts[0]) else { return nil }
            let secParts = shortMsParts[1].components(separatedBy: ".")
            guard secParts.count == 2,
                  let sec = Int(secParts[0]),
                  let ms = Int(secParts[1].padding(toLength: 3, withPad: "0", startingAt: 0))
            else { return nil }
            let totalSeconds = Double(m * 60 + sec) + Double(ms) / 1000.0
            return Timecode.fromSeconds(totalSeconds, frameRate: frameRate)
        }

        return nil
    }
}

// MARK: - TXT Exporter

/// Plain text subtitle format exporter with configurable timecode format.
public struct TXTExporter: FormatExporter {
    public static let formatID = FormatID.txt
    public static let formatName = String(localized: "Plain Text (.txt)")
    public static let fileExtension = "txt"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }
        guard !track.subtitles.isEmpty else {
            throw FormatError.invalidData("No subtitles to export")
        }

        let opts = options ?? ExportOptions()
        _ = opts.sourceFrameRate ?? track.subtitles.first?.startTime.frameRate ?? .fps25
        let useFrames = opts.extra["timecode_format"] == "frames"

        var output = ""

        for (index, sub) in track.subtitles.enumerated() {
            let num = index + 1
            if useFrames {
                output += "\(num)\n"
                output += "\(formatFrameTimecode(sub.startTime)) --> \(formatFrameTimecode(sub.endTime))\n"
            } else {
                output += "\(num)\n"
                output += "\(formatMsTimecode(sub.startTime)) --> \(formatMsTimecode(sub.endTime))\n"
            }
            for block in sub.textBlocks {
                output += "\(block.plainText)\n"
            }
            output += "\n"
        }

        guard let data = output.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode TXT as UTF-8")
        }
        return data
    }

    private static func formatMsTimecode(_ tc: Timecode) -> String {
        let (h, m, s, _) = tc.components
        let ms = tc.milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func formatFrameTimecode(_ tc: Timecode) -> String {
        return tc.smpteString
    }
}