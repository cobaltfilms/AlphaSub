import Foundation
import AlphaSubCore

// MARK: - DOCX Exporter

/// Microsoft Word DOCX subtitle format exporter.
/// Creates a simple Word document with subtitle entries, each showing
/// timecode-in, timecode-out, and text (with italic markup for styling).
/// Useful for translation workflows and proofing.
public struct DOCXExporter: FormatExporter {
    public static let formatID = FormatID.docx
    public static let formatName = String(localized: "Microsoft Word (.docx)")
    public static let fileExtension = "docx"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        var bodyXML = ""
        for (index, sub) in track.subtitles.enumerated() {
            let inTC = formatTime(sub.startTime)
            let outTC = formatTime(sub.endTime)
            let text = formatDocText(sub.textBlocks)

            bodyXML += "<w:p>"
            bodyXML += "<w:pPr><w:pStyle w:val=\"SubtitleNumber\"/></w:pPr>"
            bodyXML += "<w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">\(index + 1). </w:t></w:r>"
            bodyXML += "<w:r><w:rPr><w:b/><w:color w:val=\"4472C4\"/></w:rPr><w:t xml:space=\"preserve\">\(inTC) → \(outTC)</w:t></w:r>"
            bodyXML += "</w:p>"

            bodyXML += "<w:p>"
            bodyXML += "<w:pPr><w:pStyle w:val=\"SubtitleText\"/><w:spacing w:after=\"120\"/></w:pPr>"
            bodyXML += text
            bodyXML += "</w:p>"
        }

        let documentXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<w:document xmlns:wpc=\"http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas\" "
            + "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" "
            + "xmlns:o=\"urn:schemas-microsoft-com:office:office\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            + "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\" "
            + "xmlns:v=\"urn:schemas-microsoft-com:vml\" "
            + "xmlns:wp14=\"http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing\" "
            + "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" "
            + "xmlns:w10=\"urn:schemas-microsoft-com:office:word\" "
            + "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" "
            + "xmlns:w14=\"http://schemas.microsoft.com/office/word/2010/wordml\" "
            + "xmlns:wpg=\"http://schemas.microsoft.com/office/word/2010/wordprocessingGroup\" "
            + "xmlns:wpi=\"http://schemas.microsoft.com/office/word/2010/wordprocessingInk\" "
            + "xmlns:wne=\"http://schemas.microsoft.com/office/word/2006/wordml\" "
            + "xmlns:wps=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\" "
            + "mc:Ignorable=\"w14 wp14\">"
            + "<w:body>"
            + bodyXML
            + "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/>"
            + "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/>"
            + "</w:sectPr>"
            + "</w:body>"
            + "</w:document>"

        let stylesXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Calibri\"/>"
            + "<w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"200\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"SubtitleNumber\">"
            + "<w:name w:val=\"Subtitle Number\"/>"
            + "<w:pPr><w:spacing w:after=\"0\"/></w:pPr>"
            + "<w:rPr><w:b/><w:sz w:val=\"20\"/><w:color w:val=\"4472C4\"/></w:rPr>"
            + "</w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"SubtitleText\">"
            + "<w:name w:val=\"Subtitle Text\"/>"
            + "<w:pPr><w:spacing w:after=\"120\"/></w:pPr>"
            + "<w:rPr><w:sz w:val=\"24\"/></w:rPr>"
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
            ("[Content_Types].xml", contentTypes.data(using: .utf8)!),
            ("_rels/.rels", rels.data(using: .utf8)!),
            ("word/document.xml", documentXML.data(using: .utf8)!),
            ("word/_rels/document.xml.rels", wordRels.data(using: .utf8)!),
            ("word/styles.xml", stylesXML.data(using: .utf8)!),
        ]

        return try ZIPWriter.write(entries)
    }

    private static func formatTime(_ tc: Timecode) -> String {
        let (h, m, s, _) = tc.components
        let ms = tc.milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func formatDocText(_ blocks: [TextBlock]) -> String {
        return blocks.map { block in
            block.segments.map { segment in
                let escaped = escapeXML(segment.text)
                if segment.style.contains(.italic) {
                    return "<w:r><w:rPr><w:i/></w:rPr><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>"
                }
                if segment.style.contains(.bold) {
                    return "<w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>"
                }
                return "<w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>"
            }.joined()
        }.joined(separator: "<w:r><w:br/></w:r>")
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