import Foundation
import AlphaSubCore

// MARK: - Final Cut Pro 7 / Premiere (xmeml) Importer

/// Importer for the legacy `xmeml` interchange XML shared by Final Cut Pro 7 and
/// Adobe Premiere Pro (`.xml`). Subtitles authored as the Apple **Text**
/// generator appear as `<generatoritem>` elements carrying an
/// `<effect effectid="Text">` whose `str` parameter holds the line; Premiere's
/// graphic clips appear as `<clipitem>`. Both are handled here.
///
/// Timing lives in `<start>`/`<end>` **child elements** (timeline frames at the
/// sequence's `<rate><timebase>`), not attributes — reading them as attributes,
/// and assuming 25 fps, is why this never imported before.
public struct PremiereImporter: FormatImporter {
    public static let formatID = FormatID.premiere
    public static let formatName = String(localized: "Final Cut Pro 7 / Premiere XML (xmeml)")
    public static let fileExtensions = ["xml"]

    public static func canImport(_ data: Data) -> Bool {
        guard let str = decode(data) else { return false }
        return str.contains("xmeml")
            && (str.contains("<sequence") || str.contains("<project"))
            && !str.contains("fcpxml")
            && !str.contains("SubtitleReel")
            && !str.contains("DCSubtitle")
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        guard let str = decode(data) else {
            throw FormatError.unsupportedEncoding("Cannot decode xmeml data")
        }

        let doc = try XMLDocument(xmlString: str, options: [])
        guard let root = doc.rootElement() else {
            throw FormatError.invalidData("No root element in xmeml")
        }

        let sequenceElem = findElement(root, localName: "sequence") ?? root
        let seqName = sequenceElem.elements(forName: "name").first?.stringValue
            ?? sequenceElem.attribute(forName: "name")?.stringValue
            ?? "FCP7 / Premiere Import"

        // The timeline's <rate><timebase> drives the frame→seconds conversion.
        // The frames in <start>/<end> are in this timebase, so the wrong rate
        // stretches or compresses every cue.
        let rate = sequenceRate(sequenceElem)
        let fps = rate?.fps ?? (opts.targetFrameRate?.value ?? FrameRate.fps25.value)
        let displayRate = opts.targetFrameRate ?? rate?.frameRate ?? .fps25
        let trackRate = rate?.frameRate ?? opts.targetFrameRate

        func makeTrack(_ subs: [Subtitle], named name: String) -> Track {
            Track(
                name: name,
                language: opts.defaultLanguage ?? LanguageCode(""),
                subtitles: subs,
                formatOrigin: "premiere",
                metadata: ["xmeml": "true"],
                frameRate: trackRate
            )
        }

        // One AlphaSub track per populated xmeml video track, so a project that
        // stacks several subtitle tracks keeps its layout.
        var tracks: [Track] = []
        for trackElem in videoTrackElements(sequenceElem) {
            let subs = parseSubtitles(in: trackElem, fps: fps, displayRate: displayRate)
            guard !subs.isEmpty else { continue }
            tracks.append(makeTrack(subs, named: seqName))
        }
        // Disambiguate names only when there is more than one track.
        if tracks.count > 1 {
            tracks = tracks.enumerated().map { i, t in
                var t = t; t.name = "\(seqName) \(i + 1)"; return t
            }
        }

        // Fallback: if items aren't wrapped in <video><track> as expected, scan
        // the whole sequence so nothing is silently dropped.
        if tracks.isEmpty {
            let subs = parseSubtitles(in: sequenceElem, fps: fps, displayRate: displayRate)
            if !subs.isEmpty { tracks.append(makeTrack(subs, named: seqName)) }
        }

        if let offset = opts.timecodeOffset {
            tracks = tracks.map { $0.offsetAll(by: offset) }
        }
        return tracks
    }

    // MARK: - Parsing

    private static func parseSubtitles(in container: XMLElement, fps: Double, displayRate: FrameRate) -> [Subtitle] {
        var subs: [Subtitle] = []
        for item in findElements(root: container, localNames: ["generatoritem", "clipitem"]) {
            guard let (start, end) = itemTiming(item, fps: fps, displayRate: displayRate),
                  let parsed = itemText(item)
            else { continue }

            var sub = Subtitle(startTime: start, endTime: end, textBlocks: parsed.blocks)
            sub.verticalPosition = .safeArea(.bottom)
            sub.horizontalPosition = parsed.horizontal
            sub.alignment = parsed.alignment
            subs.append(sub)
        }
        return subs
    }

    /// Read `<start>`/`<end>` (child elements, attribute fallback) as timeline
    /// frames and convert to time at the sequence frame rate.
    private static func itemTiming(_ item: XMLElement, fps: Double, displayRate: FrameRate) -> (Timecode, Timecode)? {
        guard let startFrames = frameValue(item, "start"),
              let endFrames = frameValue(item, "end"),
              startFrames >= 0, endFrames > startFrames
        else { return nil }
        let start = Timecode.fromSeconds(startFrames / fps, frameRate: displayRate)
        let end = Timecode.fromSeconds(endFrames / fps, frameRate: displayRate)
        return (start, end)
    }

    /// Extract the subtitle text, inline style and alignment from a Text
    /// generator's `<effect>` parameters (`str`, `fontstyle`, `fontalign`), with
    /// a fallback to a Premiere clip's `<name>`.
    private static func itemText(_ item: XMLElement) -> (blocks: [TextBlock], horizontal: HorizontalPosition, alignment: TextAlignment)? {
        var raw: String?
        var style: TextStyle = []
        var horizontal: HorizontalPosition = .centered
        var alignment: TextAlignment = .center

        for param in findElements(root: item, localNames: ["parameter"]) {
            let pid = (param.elements(forName: "parameterid").first?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = param.elements(forName: "value").first?.stringValue
            switch pid {
            case "str":
                raw = value
            case "fontstyle":
                // 1 Plain, 2 Bold, 3 Italic, 4 Bold/Italic.
                if let n = intValue(value) {
                    if n == 2 || n == 4 { style.insert(.bold) }
                    if n == 3 || n == 4 { style.insert(.italic) }
                }
            case "fontalign":
                // 1 Left, 2 Center, 3 Right.
                switch intValue(value) {
                case 1: horizontal = .leftAligned;  alignment = .left
                case 3: horizontal = .rightAligned; alignment = .right
                default: horizontal = .centered;    alignment = .center
                }
            default:
                break
            }
        }

        // Premiere graphic clips often keep the line in <name>; the FCP7 Text
        // generator's own <name> is the literal "Text", which we ignore.
        if raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            let name = item.elements(forName: "name").first?.stringValue
            raw = (name == "Text") ? nil : name
        }

        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // FCP7 Text generators break lines with a carriage return (stored as the
        // `&#xd;` entity → "\r"); normalise every newline flavour before splitting.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n").map {
            TextBlock(segments: [TextSegment(text: $0, style: style)])
        }
        return (blocks, horizontal, alignment)
    }

    // MARK: - XML helpers

    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func intValue(_ s: String?) -> Int? {
        s.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Read a frame count from a direct child element, falling back to an
    /// attribute of the same name (some Premiere variants use attributes).
    private static func frameValue(_ el: XMLElement, _ name: String) -> Double? {
        if let v = el.elements(forName: name).first?.stringValue,
           let d = Double(v.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
        if let a = el.attribute(forName: name)?.stringValue, let d = Double(a) { return d }
        return nil
    }

    /// The sequence's `<rate>`: real fps (NTSC-corrected) plus the closest
    /// `FrameRate` case. The first `<rate>` in document order is the sequence's.
    private static func sequenceRate(_ seq: XMLElement) -> (fps: Double, frameRate: FrameRate?)? {
        for rate in findElements(root: seq, localNames: ["rate"]) {
            guard let tbStr = rate.elements(forName: "timebase").first?.stringValue,
                  let tb = Double(tbStr.trimmingCharacters(in: .whitespacesAndNewlines)), tb > 0
            else { continue }
            let ntsc = (rate.elements(forName: "ntsc").first?.stringValue ?? "FALSE")
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "TRUE"
            let fps = ntsc ? tb * 1000.0 / 1001.0 : tb
            let match = FrameRate.allCases.first { abs($0.value - fps) < 0.05 }
            return (fps, match)
        }
        return nil
    }

    private static func videoTrackElements(_ seq: XMLElement) -> [XMLElement] {
        guard let video = findElement(seq, localName: "video") else { return [] }
        return (video.children ?? []).compactMap { $0 as? XMLElement }
            .filter { resolveLocal($0.name) == "track" }
    }

    private static func findElement(_ root: XMLElement, localName: String) -> XMLElement? {
        func walk(_ elem: XMLElement) -> XMLElement? {
            if resolveLocal(elem.name) == localName { return elem }
            for child in (elem.children ?? []).compactMap({ $0 as? XMLElement }) {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(root)
    }

    private static func findElements(root: XMLElement, localNames targets: Set<String>) -> [XMLElement] {
        var results: [XMLElement] = []
        func walk(_ elem: XMLElement) {
            if targets.contains(resolveLocal(elem.name)) { results.append(elem) }
            for child in (elem.children ?? []).compactMap({ $0 as? XMLElement }) { walk(child) }
        }
        walk(root)
        return results
    }

    private static func resolveLocal(_ name: String?) -> String {
        guard let name = name else { return "" }
        if let colon = name.lastIndex(of: ":") { return String(name[name.index(after: colon)...]) }
        return name
    }
}

// MARK: - Final Cut Pro 7 / Premiere (xmeml) Exporter

/// Exports subtitles as the Apple **Text** generator inside `xmeml` — the real
/// structure Final Cut Pro 7, Premiere Pro and DaVinci Resolve all import (and
/// the structure `PremiereImporter` round-trips). Each cue becomes a
/// `<generatoritem>` on a video track, timed in frames at the chosen rate.
public struct PremiereExporter: FormatExporter {
    public static let formatID = FormatID.premiere
    public static let formatName = String(localized: "Final Cut Pro 7 / Premiere XML (xmeml)")
    public static let fileExtension = "xml"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        let opts = options ?? ExportOptions()
        let populated = tracks.filter { !$0.subtitles.isEmpty }
        let exportTracks = populated.isEmpty ? Array(tracks.prefix(1)) : populated
        guard let firstTrack = exportTracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        let frameRate = opts.sourceFrameRate ?? firstTrack.subtitles.first?.startTime.frameRate ?? .fps25
        let (timebase, ntsc) = xmemlRate(frameRate)
        let seqName = firstTrack.name.isEmpty ? "AlphaSub Export" : firstTrack.name
        let totalFrames = exportTracks.flatMap { $0.subtitles }
            .map { frame($0.endTime.seconds, frameRate) }.max() ?? 0

        let rateXML = "<rate><timebase>\(timebase)</timebase><ntsc>\(ntsc)</ntsc></rate>"

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<!DOCTYPE xmeml>\n"
        xml += "<xmeml version=\"5\">\n"
        xml += "  <sequence>\n"
        xml += "    <name>\(escapeXML(seqName))</name>\n"
        xml += "    <duration>\(totalFrames)</duration>\n"
        xml += "    \(rateXML)\n"
        xml += "    <in>-1</in>\n    <out>-1</out>\n"
        xml += "    <timecode><string>00:00:00:00</string><frame>0</frame><displayformat>NDF</displayformat>\(rateXML)</timecode>\n"
        xml += "    <media>\n"
        xml += "      <video>\n"
        xml += "        <format><samplecharacteristics>\(rateXML)<width>1920</width><height>1080</height></samplecharacteristics></format>\n"

        for track in exportTracks {
            xml += "        <track>\n"
            let sorted = track.subtitles.sorted { $0.startTime.seconds < $1.startTime.seconds }
            for (i, sub) in sorted.enumerated() {
                xml += generatorItem(sub, index: i, frameRate: frameRate, rateXML: rateXML)
            }
            xml += "        </track>\n"
        }

        xml += "      </video>\n"
        xml += "      <audio><track></track></audio>\n"
        xml += "    </media>\n"
        xml += "  </sequence>\n"
        xml += "</xmeml>\n"

        guard let data = xml.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode xmeml as UTF-8")
        }
        return data
    }

    private static func generatorItem(_ sub: Subtitle, index: Int, frameRate: FrameRate, rateXML: String) -> String {
        let startF = frame(sub.startTime.seconds, frameRate)
        let endF = max(frame(sub.endTime.seconds, frameRate), startF + 1)
        let durF = endF - startF
        // Lines join with the FCP7 carriage-return entity, each escaped first so
        // the entity itself survives (escaping after would mangle the "&").
        let text = sub.textBlocks
            .map { escapeXML($0.segments.map(\.text).joined()) }
            .joined(separator: "&#xd;")

        // Whole-cue style → FCP fontstyle (1 Plain, 2 Bold, 3 Italic, 4 both).
        let segs = sub.textBlocks.flatMap { $0.segments }.filter { !$0.text.isEmpty }
        let bold = !segs.isEmpty && segs.allSatisfy { $0.style.contains(.bold) }
        let italic = !segs.isEmpty && segs.allSatisfy { $0.style.contains(.italic) }
        let fontStyle = (bold && italic) ? 4 : italic ? 3 : bold ? 2 : 1
        let fontAlign: Int
        switch sub.alignment {
        case .left, .start: fontAlign = 1
        case .right, .end:  fontAlign = 3
        default:            fontAlign = 2
        }

        var s = "          <generatoritem id=\"Text \(index)\">\n"
        s += "            <name>Text</name>\n"
        s += "            <duration>\(durF)</duration>\n"
        s += "            \(rateXML)\n"
        s += "            <in>0</in>\n            <out>\(durF)</out>\n"
        s += "            <start>\(startF)</start>\n            <end>\(endF)</end>\n"
        s += "            <enabled>TRUE</enabled>\n            <anamorphic>FALSE</anamorphic>\n            <alphatype>black</alphatype>\n"
        s += "            <effect>\n"
        s += "              <name>Text</name>\n              <effectid>Text</effectid>\n"
        s += "              <effecttype>generator</effecttype>\n              <mediatype>video</mediatype>\n              <effectcategory>Text</effectcategory>\n"
        s += "              <parameter>\n                <parameterid>str</parameterid>\n                <name>Text</name>\n                <value>\(text)</value>\n              </parameter>\n"
        s += "              <parameter>\n                <parameterid>fontstyle</parameterid>\n                <name>Style</name>\n                <value>\(fontStyle)</value>\n              </parameter>\n"
        s += "              <parameter>\n                <parameterid>fontalign</parameterid>\n                <name>Alignment</name>\n                <value>\(fontAlign)</value>\n              </parameter>\n"
        s += "            </effect>\n"
        s += "          </generatoritem>\n"
        return s
    }

    /// FCP7 `xmeml` timebase + NTSC flag for a frame rate. Fractional rates are
    /// written as the integer timebase with `<ntsc>TRUE</ntsc>`.
    private static func xmemlRate(_ frameRate: FrameRate) -> (timebase: Int, ntsc: String) {
        switch frameRate {
        case .fps23_976:                  return (24, "TRUE")
        case .fps29_97_ndf, .fps29_97_df: return (30, "TRUE")
        case .fps47_952:                  return (48, "TRUE")
        case .fps59_94_ndf, .fps59_94_df: return (60, "TRUE")
        default:                          return (Int(frameRate.value.rounded()), "FALSE")
        }
    }

    private static func frame(_ seconds: Double, _ frameRate: FrameRate) -> Int {
        Int((seconds * frameRate.value).rounded())
    }

    private static func escapeXML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
