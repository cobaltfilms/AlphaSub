import Foundation

// Marker export — renders a list of timeline markers into the file formats the
// three big NLEs import as timeline markers:
//   • DaVinci Resolve  → CMX3600 EDL (`.edl`) with Resolve's |C:|M:|D: comment
//   • Premiere Pro     → Markers-panel CSV (`.csv`)
//   • Final Cut Pro X  → FCPXML (`.fcpxml`) with <marker> on a spine gap
//
// Pure string builders in Core so they are unit-testable without AppKit. The
// caller supplies markers whose `timeSeconds` is already in the timeline
// timecode domain (i.e. the media time plus the timeline timecode offset), so a
// marker lands at the same SMPTE timecode the operator saw in AlphaSub.

/// One marker to export, in the timeline timecode domain.
public struct MarkerExportItem: Equatable, Sendable {
    /// Absolute timeline position in seconds (offset already applied).
    public let timeSeconds: Double
    public let name: String
    public let comment: String
    /// DaVinci-style colour name (see `TimelineMarker.colorNames`).
    public let color: String

    public init(timeSeconds: Double, name: String, comment: String, color: String) {
        self.timeSeconds = timeSeconds
        self.name = name
        self.comment = comment
        self.color = color
    }

    /// The marker label preferred for NLEs that only carry one string: the
    /// name, falling back to the comment, falling back to "Marker".
    public var primaryLabel: String {
        if !name.isEmpty { return name }
        if !comment.isEmpty { return comment }
        return "Marker"
    }
}

public enum MarkerExport {

    // MARK: DaVinci Resolve — CMX3600 EDL

    /// Colour names Resolve recognises, mapped from our stored names. Unknown
    /// colours fall back to Blue.
    private static let resolveColors: Set<String> = [
        "Blue", "Cyan", "Green", "Yellow", "Red", "Pink", "Purple",
        "Fuchsia", "Rose", "Lavender", "Sky", "Mint", "Lemon", "Sand",
        "Cocoa", "Cream",
    ]

    private static func resolveColor(_ name: String) -> String {
        "ResolveColor" + (resolveColors.contains(name) ? name : "Blue")
    }

    /// A CMX3600 EDL whose events are markers. Resolve imports these via
    /// Timeline ▸ Import ▸ Timeline Markers from EDL. Each event records the
    /// marker's timecode; the `|C:|M:|D:` note carries colour, name and a
    /// 1-frame duration — Resolve's own timeline-marker EDL convention.
    public static func edl(markers: [MarkerExportItem],
                           frameRate: FrameRate,
                           title: String = "AlphaSub Markers") -> String {
        let fps = max(1.0, frameRate.value)
        let frameDur = 1.0 / fps
        var lines: [String] = ["TITLE: \(title)", "FCM: \(frameRate.isDropFrame ? "DROP FRAME" : "NON-DROP FRAME")"]
        let sorted = markers.sorted { $0.timeSeconds < $1.timeSeconds }
        for (i, m) in sorted.enumerated() {
            let inTC = Timecode.fromSeconds(m.timeSeconds, frameRate: frameRate).smpteString
            let outTC = Timecode.fromSeconds(m.timeSeconds + frameDur, frameRate: frameRate).smpteString
            let num = String(format: "%03d", i + 1)
            // event: <num> <reel> <track> <transition> <srcIn> <srcOut> <recIn> <recOut>
            lines.append("\(num)  001      V     C        \(inTC) \(outTC) \(inTC) \(outTC)")
            let name = m.primaryLabel.replacingOccurrences(of: "\n", with: " ")
            lines.append(" |C:\(resolveColor(m.color)) |M:\(name) |D:1")
            // A human-readable comment line for the full note (ignored by the
            // marker importer but useful when the EDL is read directly).
            if !m.comment.isEmpty {
                lines.append("* \(m.comment.replacingOccurrences(of: "\n", with: " "))")
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Adobe Premiere Pro — Markers CSV

    /// The Markers-panel CSV Premiere imports: Name, Description, In, Out,
    /// Duration, Marker Type. Times are SMPTE strings; markers are zero-length
    /// ("Comment" type), so Out == In and Duration is one frame.
    public static func premiereCSV(markers: [MarkerExportItem],
                                   frameRate: FrameRate) -> String {
        func esc(_ s: String) -> String {
            let needsQuote = s.contains(",") || s.contains("\"") || s.contains("\n")
            let body = s.replacingOccurrences(of: "\"", with: "\"\"")
            return needsQuote ? "\"\(body)\"" : body
        }
        let header = ["Marker Name", "Description", "In", "Out", "Duration", "Marker Type"]
        var lines = [header.map(esc).joined(separator: ",")]
        let oneFrame = Timecode(totalFrames: 1, frameRate: frameRate).smpteString
        for m in markers.sorted(by: { $0.timeSeconds < $1.timeSeconds }) {
            let inTC = Timecode.fromSeconds(m.timeSeconds, frameRate: frameRate).smpteString
            let row = [
                m.name.isEmpty ? m.primaryLabel : m.name,
                m.comment,
                inTC,
                inTC,
                oneFrame,
                "Comment",
            ]
            lines.append(row.map(esc).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Final Cut Pro X — FCPXML markers

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Rational seconds `N/Ds` string FCPXML expects, quantised to the frame
    /// grid so FCP places markers on exact frames.
    private static func rational(_ seconds: Double, frameRate: FrameRate) -> String {
        let timebase = 2400   // divisible by 24/25/30 nominal rates
        let frames = Int((seconds * Double(timebase)).rounded())
        return "\(frames)/\(timebase)s"
    }

    /// An FCPXML document whose single spine gap carries `<marker>` elements.
    /// FCP X imports the markers onto the timeline. `totalDurationSeconds`
    /// sizes the gap so every marker falls within it.
    public static func fcpxml(markers: [MarkerExportItem],
                              frameRate: FrameRate,
                              totalDurationSeconds: Double) -> String {
        let sorted = markers.sorted { $0.timeSeconds < $1.timeSeconds }
        let lastMarker = sorted.last?.timeSeconds ?? 0
        let dur = max(totalDurationSeconds, lastMarker + 1.0, 1.0)
        let nominal = frameRate.nominalFPS
        let frameDurRational = "\(100 * (frameRate.isDropFrame ? 1001 : 1000))/\(nominal * 100 * 1000)s"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" name="AlphaSubFormat" frameDuration="\(frameDurRational)"/>
            </resources>
            <library>
                <event name="AlphaSub Markers">
                    <project name="AlphaSub Markers">
                        <sequence format="r1">
                            <spine>
                                <gap name="Markers" offset="0s" duration="\(rational(dur, frameRate: frameRate))" start="0s">

        """
        for m in sorted {
            let start = rational(m.timeSeconds, frameRate: frameRate)
            let value = escapeXML(m.primaryLabel)
            if m.comment.isEmpty {
                xml += "                                <marker start=\"\(start)\" duration=\"\(rational(1.0 / max(1.0, frameRate.value), frameRate: frameRate))\" value=\"\(value)\"/>\n"
            } else {
                xml += "                                <marker start=\"\(start)\" duration=\"\(rational(1.0 / max(1.0, frameRate.value), frameRate: frameRate))\" value=\"\(value)\" note=\"\(escapeXML(m.comment))\"/>\n"
            }
        }
        xml += """
                                </gap>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """
        return xml
    }
}
