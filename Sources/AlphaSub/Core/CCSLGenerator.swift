import Foundation

// MARK: - CCSL / Dialogue & Spotting List Generator

/// Builds a Combined Continuity & Spotting List (CCSL) / dialogue list from a
/// subtitle track: every spotted cue with timecodes, speaker, dialogue and —
/// for bilingual deliveries — the subtitle translation from a second track,
/// grouped into scenes. A CCSL is a contractual deliverable productions
/// normally assemble by hand; AlphaSub already has all the ingredients
/// (timed cues, speaker fields, shot changes, multi-track documents).
///
/// The generator is pure (no AppKit / no I/O): it turns tracks into `Row`
/// values and renders them as CSV (RFC 4180), a plain semantic HTML table
/// fragment (the app layer wraps it in the branded report chrome), or a
/// standalone Word `.docx` table (same ZIP + WordprocessingML scaffolding as
/// `DOCXExporter` in AlphaSubFormats).
public enum CCSLGenerator {

    // MARK: Options

    public struct Options {
        /// Programme / project title shown in the DOCX heading.
        public var documentTitle: String
        /// Emit the Speaker column.
        public var includeSpeaker: Bool
        /// Append conventional annotations derived from cue flags to the
        /// dialogue column: `[MUSIC]` (isMusic), `[FN]` (isForced, forced
        /// narrative), `(V.O.)` (isOffSpeech).
        public var includeFlagAnnotations: Bool
        /// Group cues into scenes (see `rows(primary:...)` for the rule).
        public var groupScenes: Bool

        public init(documentTitle: String = "",
                    includeSpeaker: Bool = true,
                    includeFlagAnnotations: Bool = true,
                    groupScenes: Bool = true) {
            self.documentTitle = documentTitle
            self.includeSpeaker = includeSpeaker
            self.includeFlagAnnotations = includeFlagAnnotations
            self.groupScenes = groupScenes
        }
    }

    // MARK: Rows

    /// One line of the list: either a scene header ("SCENE 2 — 00:01:10:05–00:02:31:00")
    /// or a spotted cue.
    public enum Row: Equatable {
        case sceneHeader(String)
        case cue(Cue)
    }

    /// One spotted cue. All timecodes are SMPTE strings at the primary
    /// track's frame rate.
    public struct Cue: Equatable {
        public var index: Int
        public var timecodeIn: String
        public var timecodeOut: String
        public var duration: String
        public var speaker: String
        public var dialogue: String
        public var translation: String

        public init(index: Int, timecodeIn: String, timecodeOut: String,
                    duration: String, speaker: String, dialogue: String,
                    translation: String) {
            self.index = index
            self.timecodeIn = timecodeIn
            self.timecodeOut = timecodeOut
            self.duration = duration
            self.speaker = speaker
            self.dialogue = dialogue
            self.translation = translation
        }
    }

    /// Minimum silence between consecutive cues for a shot change inside that
    /// gap to be read as a scene break.
    public static let sceneGapSeconds: Double = 5.0
    /// Minimum time overlap (fraction of the shorter cue) for a secondary-track
    /// cue to be paired as the translation of a primary cue.
    public static let pairingOverlapThreshold: Double = 0.5

    // MARK: Row building

    /// Build the list rows.
    ///
    /// - Scene grouping (when `options.groupScenes`): a new scene starts at a
    ///   cue when a shot change falls inside a gap of at least
    ///   `sceneGapSeconds` between it and the previous cue, OR when the cue is
    ///   flagged `isNewScene`. The two signals are OR'd. When neither signal
    ///   ever fires, the whole track is a single group and no scene headers
    ///   are emitted.
    /// - Translation pairing: each primary cue is paired with every
    ///   secondary-track cue whose time overlap is at least 50% of the shorter
    ///   of the two cues; matches are joined in time order. No match → empty
    ///   cell.
    public static func rows(primary: Track,
                            secondary: Track? = nil,
                            shotChanges: [Double]? = nil,
                            options: Options = Options()) -> [Row] {
        let cues = primary.subtitles.sorted { $0.startTime.seconds < $1.startTime.seconds }
        guard !cues.isEmpty else { return [] }
        let secondaryCues = secondary?.subtitles ?? []

        // Scene-break decision per cue (a break BEFORE cue i starts scene n+1).
        var breakBefore = [Bool](repeating: false, count: cues.count)
        if options.groupScenes {
            let shots = (shotChanges ?? []).sorted()
            for i in 1..<cues.count {
                if cues[i].isNewScene {
                    breakBefore[i] = true
                    continue
                }
                let gapStart = cues[i - 1].endTime.seconds
                let gapEnd = cues[i].startTime.seconds
                if gapEnd - gapStart >= sceneGapSeconds,
                   shots.contains(where: { $0 >= gapStart && $0 <= gapEnd }) {
                    breakBefore[i] = true
                }
            }
        }
        let hasScenes = breakBefore.contains(true)

        var rows: [Row] = []
        var sceneNumber = 0
        var sceneStart = 0
        var i = 0
        while i < cues.count {
            // Find the extent of the current scene.
            sceneStart = i
            var end = i + 1
            while end < cues.count && !breakBefore[end] { end += 1 }

            if hasScenes {
                sceneNumber += 1
                let first = cues[sceneStart].startTime.smpteString
                let last = cues[end - 1].endTime.smpteString
                rows.append(.sceneHeader("\(String(localized: "SCENE")) \(sceneNumber) — \(first)–\(last)"))
            }
            for j in sceneStart..<end {
                rows.append(.cue(cueRow(for: cues[j], index: j + 1,
                                        secondary: secondaryCues, options: options)))
            }
            i = end
        }
        return rows
    }

    private static func cueRow(for sub: Subtitle, index: Int,
                               secondary: [Subtitle], options: Options) -> Cue {
        var dialogue = joinedLines(sub.plainText)
        if options.includeFlagAnnotations {
            var annotations: [String] = []
            if sub.isMusic { annotations.append("[MUSIC]") }
            if sub.isForced { annotations.append("[FN]") }
            if sub.isOffSpeech { annotations.append("(V.O.)") }
            if !annotations.isEmpty {
                let suffix = annotations.joined(separator: " ")
                dialogue = dialogue.isEmpty ? suffix : dialogue + " " + suffix
            }
        }
        return Cue(index: index,
                   timecodeIn: sub.startTime.smpteString,
                   timecodeOut: sub.endTime.smpteString,
                   duration: (sub.endTime - sub.startTime).smpteString,
                   speaker: options.includeSpeaker ? sub.speaker : "",
                   dialogue: dialogue,
                   translation: pairedTranslation(for: sub, in: secondary))
    }

    /// Multi-line cue text as a single list line, subtitle lines joined " / ".
    private static func joinedLines(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    /// All secondary cues overlapping `sub` by ≥50% of the shorter cue,
    /// joined in time order. Empty when the track has no counterpart.
    static func pairedTranslation(for sub: Subtitle, in secondary: [Subtitle]) -> String {
        guard !secondary.isEmpty else { return "" }
        let a0 = sub.startTime.seconds, a1 = sub.endTime.seconds
        var matches: [(start: Double, text: String)] = []
        for candidate in secondary {
            let b0 = candidate.startTime.seconds, b1 = candidate.endTime.seconds
            let overlap = min(a1, b1) - max(a0, b0)
            guard overlap > 0 else { continue }
            let shorter = max(0.001, min(a1 - a0, b1 - b0))
            if overlap / shorter >= pairingOverlapThreshold {
                matches.append((b0, joinedLines(candidate.plainText)))
            }
        }
        return matches.sorted { $0.start < $1.start }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    // MARK: Column layout

    /// The visible columns for a given option set (speaker / translation are
    /// optional), shared by all three renderers so they always agree.
    static func headers(includeSpeaker: Bool, includeTranslation: Bool) -> [String] {
        var h = [String(localized: "No."),
                 String(localized: "TC In"),
                 String(localized: "TC Out"),
                 String(localized: "Duration")]
        if includeSpeaker { h.append(String(localized: "Speaker")) }
        h.append(String(localized: "Dialogue"))
        if includeTranslation { h.append(String(localized: "Translation")) }
        return h
    }

    static func fields(for cue: Cue, includeSpeaker: Bool, includeTranslation: Bool) -> [String] {
        var f = [String(cue.index), cue.timecodeIn, cue.timecodeOut, cue.duration]
        if includeSpeaker { f.append(cue.speaker) }
        f.append(cue.dialogue)
        if includeTranslation { f.append(cue.translation) }
        return f
    }

    // MARK: CSV (RFC 4180)

    public static func csv(rows: [Row], includeSpeaker: Bool, includeTranslation: Bool) -> String {
        func esc(_ s: String) -> String {
            let needsQuote = s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
            let body = s.replacingOccurrences(of: "\"", with: "\"\"")
            return needsQuote ? "\"\(body)\"" : body
        }
        let header = headers(includeSpeaker: includeSpeaker, includeTranslation: includeTranslation)
        var lines = [header.map(esc).joined(separator: ",")]
        for row in rows {
            switch row {
            case .sceneHeader(let title):
                // Keep the column count stable: header text in the first field.
                var f = [String](repeating: "", count: header.count)
                f[0] = title
                lines.append(f.map(esc).joined(separator: ","))
            case .cue(let cue):
                lines.append(fields(for: cue, includeSpeaker: includeSpeaker,
                                    includeTranslation: includeTranslation)
                    .map(esc).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: HTML (semantic table fragment)

    /// A plain `<table>` fragment with `class="ccsl"`, scene headers as
    /// `<tr class="scene">` colspan rows. The app layer wraps it in the
    /// branded report page (title, subtitle, CSS) — see the CCSL export sheet.
    public static func html(rows: [Row], includeSpeaker: Bool, includeTranslation: Bool) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        let header = headers(includeSpeaker: includeSpeaker, includeTranslation: includeTranslation)
        var out = "<table class=\"ccsl\">\n<thead><tr>"
        out += header.map { "<th>\(esc($0))</th>" }.joined()
        out += "</tr></thead>\n<tbody>\n"
        for row in rows {
            switch row {
            case .sceneHeader(let title):
                out += "<tr class=\"scene\"><td colspan=\"\(header.count)\">\(esc(title))</td></tr>\n"
            case .cue(let cue):
                let cells = fields(for: cue, includeSpeaker: includeSpeaker,
                                   includeTranslation: includeTranslation)
                out += "<tr>" + cells.map { "<td>\(esc($0))</td>" }.joined() + "</tr>\n"
            }
        }
        out += "</tbody></table>"
        return out
    }

    // MARK: DOCX

    /// Standalone Word document: title heading + one table with the same
    /// columns as CSV/HTML. Reuses the WordprocessingML + stored-ZIP
    /// scaffolding of `DOCXExporter` (AlphaSubFormats); duplicated here
    /// because Core cannot depend on Formats.
    public static func docx(rows: [Row], title: String,
                            includeSpeaker: Bool, includeTranslation: Bool) throws -> Data {
        let documentXML = documentXML(rows: rows, title: title,
                                      includeSpeaker: includeSpeaker,
                                      includeTranslation: includeTranslation)

        let stylesXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Calibri\"/>"
            + "<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"CCSLTitle\">"
            + "<w:name w:val=\"CCSL Title\"/>"
            + "<w:pPr><w:spacing w:after=\"240\"/></w:pPr>"
            + "<w:rPr><w:b/><w:sz w:val=\"32\"/></w:rPr>"
            + "</w:style>"
            + "</w:styles>"

        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
            + "</Types>"

        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
            + "</Relationships>"

        let wordRels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            + "</Relationships>"

        let entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("word/document.xml", Data(documentXML.utf8)),
            ("word/_rels/document.xml.rels", Data(wordRels.utf8)),
            ("word/styles.xml", Data(stylesXML.utf8)),
        ]
        return CCSLZIPWriter.write(entries)
    }

    /// The inner `word/document.xml` of the DOCX. Internal so tests can assert
    /// on the XML directly instead of unzipping the archive.
    static func documentXML(rows: [Row], title: String,
                            includeSpeaker: Bool, includeTranslation: Bool) -> String {
        let header = headers(includeSpeaker: includeSpeaker, includeTranslation: includeTranslation)

        // Column widths in twentieths of a point (dxa); page is ~10160 dxa
        // wide inside 720-dxa margins on landscape US Letter.
        func widths() -> [Int] {
            let textColumns = 1 + (includeTranslation ? 1 : 0)
            var w = [600, 1300, 1300, 1100]                     // No., TC In, TC Out, Duration
            if includeSpeaker { w.append(1500) }
            let remaining = max(2000, 14000 - w.reduce(0, +))
            for _ in 0..<textColumns { w.append(remaining / textColumns) }
            return w
        }
        let colWidths = widths()
        let tableWidth = colWidths.reduce(0, +)

        func cell(_ text: String, width: Int, bold: Bool = false,
                  span: Int = 1, shaded: Bool = false) -> String {
            var props = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
            if span > 1 { props += "<w:gridSpan w:val=\"\(span)\"/>" }
            if shaded { props += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"E7EAF0\"/>" }
            let rPr = bold ? "<w:rPr><w:b/></w:rPr>" : ""
            let run = text.isEmpty
                ? ""
                : "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(escapeXML(text))</w:t></w:r>"
            return "<w:tc><w:tcPr>\(props)</w:tcPr><w:p>\(run)</w:p></w:tc>"
        }

        var body = ""
        if !title.isEmpty {
            body += "<w:p><w:pPr><w:pStyle w:val=\"CCSLTitle\"/></w:pPr>"
                + "<w:r><w:t xml:space=\"preserve\">\(escapeXML(title))</w:t></w:r></w:p>"
        }

        body += "<w:tbl><w:tblPr>"
            + "<w:tblW w:w=\"\(tableWidth)\" w:type=\"dxa\"/>"
            + "<w:tblBorders>"
            + "<w:top w:val=\"single\" w:sz=\"4\" w:color=\"999999\"/>"
            + "<w:left w:val=\"single\" w:sz=\"4\" w:color=\"999999\"/>"
            + "<w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"999999\"/>"
            + "<w:right w:val=\"single\" w:sz=\"4\" w:color=\"999999\"/>"
            + "<w:insideH w:val=\"single\" w:sz=\"4\" w:color=\"CCCCCC\"/>"
            + "<w:insideV w:val=\"single\" w:sz=\"4\" w:color=\"CCCCCC\"/>"
            + "</w:tblBorders>"
            + "<w:tblCellMar><w:left w:w=\"80\" w:type=\"dxa\"/><w:right w:w=\"80\" w:type=\"dxa\"/></w:tblCellMar>"
            + "</w:tblPr>"
        body += "<w:tblGrid>" + colWidths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"

        // Header row.
        body += "<w:tr><w:trPr><w:tblHeader/></w:trPr>"
        for (i, h) in header.enumerated() {
            body += cell(h, width: colWidths[i], bold: true, shaded: true)
        }
        body += "</w:tr>"

        for row in rows {
            switch row {
            case .sceneHeader(let text):
                body += "<w:tr>" + cell(text, width: tableWidth, bold: true,
                                        span: header.count, shaded: true) + "</w:tr>"
            case .cue(let cue):
                let fields = fields(for: cue, includeSpeaker: includeSpeaker,
                                    includeTranslation: includeTranslation)
                body += "<w:tr>"
                for (i, f) in fields.enumerated() {
                    body += cell(f, width: colWidths[i])
                }
                body += "</w:tr>"
            }
        }
        body += "</w:tbl>"

        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<w:document xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            + "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:body>"
            + body
            // Landscape US Letter so the dialogue/translation columns get room.
            + "<w:sectPr><w:pgSz w:w=\"15840\" w:h=\"12240\" w:orient=\"landscape\"/>"
            + "<w:pgMar w:top=\"720\" w:right=\"720\" w:bottom=\"720\" w:left=\"720\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/>"
            + "</w:sectPr>"
            + "</w:body>"
            + "</w:document>"
    }

    private static func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Minimal ZIP Writer (stored entries)

/// Same stored-entry ZIP layout as `ZIPWriter` in AlphaSubFormats
/// (XLSXFormat.swift); duplicated because AlphaSubCore cannot depend on
/// AlphaSubFormats. Sufficient for DOCX, which is a ZIP of small XML parts.
private enum CCSLZIPWriter {
    static func write(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central: [(offset: UInt32, name: String, size: UInt32, crc: UInt32)] = []

        for (name, data) in entries {
            let nameData = Data(name.utf8)
            let crc = crc32(data)
            let size = UInt32(data.count)
            let localStart = UInt32(out.count)

            out.append(contentsOf: pack32(0x04034b50))   // local header signature
            out.append(contentsOf: pack16(20))           // version needed
            out.append(contentsOf: pack16(0))            // flags
            out.append(contentsOf: pack16(0))            // compression: stored
            out.append(contentsOf: pack16(0))            // mod time
            out.append(contentsOf: pack16(0))            // mod date
            out.append(contentsOf: pack32(crc))
            out.append(contentsOf: pack32(size))         // compressed size
            out.append(contentsOf: pack32(size))         // uncompressed size
            out.append(contentsOf: pack16(UInt16(nameData.count)))
            out.append(contentsOf: pack16(0))            // extra field len
            out.append(nameData)
            out.append(data)

            central.append((localStart, name, size, crc))
        }

        let centralStart = UInt32(out.count)
        for entry in central {
            let nameData = Data(entry.name.utf8)
            out.append(contentsOf: pack32(0x02014b50))   // central dir signature
            out.append(contentsOf: pack16(20))           // version made by
            out.append(contentsOf: pack16(20))           // version needed
            out.append(contentsOf: pack16(0))            // flags
            out.append(contentsOf: pack16(0))            // compression: stored
            out.append(contentsOf: pack16(0))            // mod time
            out.append(contentsOf: pack16(0))            // mod date
            out.append(contentsOf: pack32(entry.crc))
            out.append(contentsOf: pack32(entry.size))
            out.append(contentsOf: pack32(entry.size))
            out.append(contentsOf: pack16(UInt16(nameData.count)))
            out.append(contentsOf: pack16(0))            // extra field len
            out.append(contentsOf: pack16(0))            // comment len
            out.append(contentsOf: pack16(0))            // disk number
            out.append(contentsOf: pack16(0))            // internal attrs
            out.append(contentsOf: pack32(0))            // external attrs
            out.append(contentsOf: pack32(entry.offset))
            out.append(nameData)
        }

        let centralSize = UInt32(out.count) - centralStart
        let count = UInt16(central.count)
        out.append(contentsOf: pack32(0x06054b50))       // end of central directory
        out.append(contentsOf: pack16(0))
        out.append(contentsOf: pack16(0))
        out.append(contentsOf: pack16(count))
        out.append(contentsOf: pack16(count))
        out.append(contentsOf: pack32(centralSize))
        out.append(contentsOf: pack32(centralStart))
        out.append(contentsOf: pack16(0))
        return out
    }

    private static func pack16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    private static func pack32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
