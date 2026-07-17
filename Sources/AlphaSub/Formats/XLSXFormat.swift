import Foundation
import AlphaSubCore
import Compression

// MARK: - XLSX Importer

/// Microsoft Excel XLSX subtitle format importer.
/// Reads columns: Number, Timecode In, Timecode Out, Text (with &lt;i&gt; italic markers).
public struct XLSXImporter: FormatImporter {
    public static let formatID = FormatID.xlsx
    public static let formatName = String(localized: "Microsoft Excel (.xlsx)")
    public static let fileExtensions = ["xlsx"]

    public static func canImport(_ data: Data) -> Bool {
        guard data.count > 4 else { return false }
        return data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        let frameRate = opts.targetFrameRate ?? .fps25

        let entries = ZIPReader.read(data: data)
        guard !entries.isEmpty else {
            throw FormatError.invalidData("Cannot open XLSX archive")
        }

        var sharedStrings: [String] = []
        if let ssData = entries["xl/sharedStrings.xml"], let str = String(data: ssData, encoding: .utf8) {
            sharedStrings = parseSharedStrings(str)
        }

        guard let sheetData = entries["xl/worksheets/sheet1.xml"] else {
            throw FormatError.invalidData("No sheet1 found in XLSX")
        }
        guard let sheetStr = String(data: sheetData, encoding: .utf8) else {
            throw FormatError.invalidData("Cannot decode XLSX sheet")
        }

        let rows = parseSheetRows(sheetStr, sharedStrings: sharedStrings)
        guard rows.count > 1 else {
            throw FormatError.invalidData("XLSX has no data rows")
        }

        let header = rows[0].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let inCol: Int? = colIndex(for: ["timecode_in", "timecode in", "tc_in", "tc in", "in", "start", "begin"], in: header)
            ?? (header.count >= 2 ? 1 : nil)
        let outCol: Int? = colIndex(for: ["timecode_out", "timecode out", "tc_out", "tc out", "out", "end"], in: header)
            ?? (header.count >= 3 ? 2 : nil)
        let textCol: Int? = colIndex(for: ["text", "subtitle", "caption", "content", "dialogue"], in: header)
            ?? (header.count >= 4 ? 3 : (header.count >= 3 ? 2 : 1))

        var subtitles: [Subtitle] = []
        for row in rows.dropFirst() {
            let maxCol = [inCol, outCol, textCol].compactMap { $0 }.max() ?? -1
            guard row.count > maxCol else { continue }
            guard let i = inCol, let o = outCol, let t = textCol else { continue }
            let inStr = row[i]
            let outStr = row[o]
            let textStr = row[t]
            guard !inStr.isEmpty, !outStr.isEmpty else { continue }
            guard let startTC = parseTimecode(inStr, frameRate: frameRate),
                  let endTC = parseTimecode(outStr, frameRate: frameRate) else { continue }

            let segments = parseText(textStr)
            guard !segments.isEmpty else { continue }
            subtitles.append(Subtitle(
                startTime: startTC,
                endTime: endTC,
                textBlocks: [TextBlock(segments: segments)]
            ))
        }

        return [Track(
            name: opts.defaultLanguage?.rawValue ?? "XLSX Import",
            language: opts.defaultLanguage ?? LanguageCode(""),
            subtitles: subtitles,
            formatOrigin: "xlsx"
        )]
    }

    private static func colIndex(for names: [String], in header: [String]) -> Int? {
        for name in names {
            if let idx = header.firstIndex(of: name) { return idx }
        }
        return nil
    }

    private static func parseTimecode(_ str: String, frameRate: FrameRate) -> Timecode? {
        let s = str.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }

        if s.contains(",") {
            let parts = s.components(separatedBy: ",")
            guard parts.count >= 2 else { return nil }
            let timePart = parts[0].trimmingCharacters(in: .whitespaces)
            let msPart = parts[1].trimmingCharacters(in: .whitespaces)
            let timeComps = timePart.components(separatedBy: ":")
            guard timeComps.count >= 3,
                  let h = Int(timeComps[0]),
                  let m = Int(timeComps[1]),
                  let sec = Int(timeComps[2]),
                  let ms = Int(msPart.prefix(3))
            else { return nil }
            return Timecode.fromSeconds(Double(h * 3600 + m * 60 + sec) + Double(ms) / 1000.0, frameRate: frameRate)
        }

        if s.contains(":") {
            let parts = s.components(separatedBy: ":")
            if parts.count == 4 {
                guard let h = Int(parts[0]), let m = Int(parts[1]),
                      let sec = Int(parts[2]), let f = Int(parts[3])
                else { return nil }
                return Timecode(h: h, m: m, s: sec, f: f, frameRate: frameRate)
            }
            if parts.count == 3 {
                guard let h = Int(parts[0]), let m = Int(parts[1]),
                      let secFrac = Double(parts[2])
                else { return nil }
                return Timecode.fromSeconds(Double(h * 3600 + m * 60) + secFrac, frameRate: frameRate)
            }
        }

        if let secs = Double(s) {
            return Timecode.fromSeconds(secs, frameRate: frameRate)
        }
        return nil
    }

    private static func parseText(_ input: String) -> [TextSegment] {
        let trimmed: String = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var segments: [TextSegment] = []
        let italicPattern = "<i>(.*?)</i>"
        guard let regex = try? NSRegularExpression(pattern: italicPattern, options: .dotMatchesLineSeparators) else {
            return [TextSegment(text: trimmed, style: [])]
        }

        let fullRange = NSRange(location: 0, length: (trimmed as NSString).length)
        let matches = regex.matches(in: trimmed, options: [], range: fullRange)

        if matches.isEmpty {
            return [TextSegment(text: trimmed, style: [])]
        }

        let nsTrimmed = trimmed as NSString
        var lastEnd: Int = 0
        for match in matches {
            let beforeEnd = match.range.location
            if lastEnd < beforeEnd {
                let beforeText = nsTrimmed.substring(with: NSRange(location: lastEnd, length: beforeEnd - lastEnd))
                    .trimmingCharacters(in: .whitespaces)
                if !beforeText.isEmpty {
                    segments.append(TextSegment(text: beforeText, style: []))
                }
            }
            let italicText = nsTrimmed.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            if !italicText.isEmpty {
                segments.append(TextSegment(text: italicText, style: [.italic]))
            }
            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsTrimmed.length {
            let remaining = nsTrimmed.substring(from: lastEnd)
                .trimmingCharacters(in: .whitespaces)
            if !remaining.isEmpty {
                segments.append(TextSegment(text: remaining, style: []))
            }
        }

        return segments.isEmpty ? [TextSegment(text: trimmed, style: [])] : segments
    }

    private static func parseSharedStrings(_ xml: String) -> [String] {
        var strings: [String] = []
        let pattern = "<t[^>]*>([^<]*)</t>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return strings }
        let range = NSRange(xml.startIndex..., in: xml)
        for match in regex.matches(in: xml, options: [], range: range) {
            if let textRange = Range(match.range(at: 1), in: xml) {
                strings.append(String(xml[textRange]))
            }
        }
        return strings
    }

    private static func parseSheetRows(_ xml: String, sharedStrings: [String]) -> [[String]] {
        let cellPattern = "<c r=\"([A-Z]+)(\\d+)\"[^>]*(?: t=\"([^\"]*)\")?[^>]*(?:>\\s*(?:<v>([^<]*)</v>)?)?"
        guard let regex = try? NSRegularExpression(pattern: cellPattern) else { return [] }
        let range = NSRange(xml.startIndex..., in: xml)
        let matches = regex.matches(in: xml, options: [], range: range)

        var cellsByRow: [Int: [(col: Int, value: String)]] = [:]
        for match in matches {
            guard let colRange = Range(match.range(at: 1), in: xml),
                  let rowRange = Range(match.range(at: 2), in: xml),
                  let row = Int(xml[rowRange]) else { continue }
            let col = columnLetterToIndex(String(xml[colRange]))
            let type = match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound
                ? Range(match.range(at: 3), in: xml).map { String(xml[$0]) } ?? ""
                : ""
            let value = match.numberOfRanges > 4 && match.range(at: 4).location != NSNotFound
                ? Range(match.range(at: 4), in: xml).map { String(xml[$0]) } ?? ""
                : ""

            let cellValue: String
            if type == "s", let idx = Int(value), idx < sharedStrings.count {
                cellValue = sharedStrings[idx]
            } else {
                cellValue = value
            }
            cellsByRow[row, default: []].append((col: col, value: cellValue))
        }

        guard !cellsByRow.isEmpty else { return [] }
        let maxRow = cellsByRow.keys.max() ?? 1
        var result: [[String]] = []
        for row in 1...maxRow {
            guard let cells = cellsByRow[row] else { continue }
            let maxCol = cells.map(\.col).max() ?? 0
            var rowArr = Array(repeating: "", count: maxCol + 1)
            for cell in cells where cell.col < rowArr.count {
                rowArr[cell.col] = cell.value
            }
            result.append(rowArr)
        }
        return result
    }

    private static func columnLetterToIndex(_ letters: String) -> Int {
        var result = 0
        for char in letters.uppercased() {
            if let val = char.asciiValue, val >= 65 {
                result = result * 26 + Int(val - 64)
            }
        }
        return result - 1
    }
}

// MARK: - XLSX Exporter

/// Microsoft Excel XLSX subtitle format exporter.
/// Creates a spreadsheet with columns: Number, Timecode In, Timecode Out, Text.
public struct XLSXExporter: FormatExporter {
    public static let formatID = FormatID.xlsx
    public static let formatName = String(localized: "Microsoft Excel (.xlsx)")
    public static let fileExtension = "xlsx"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        var rows: [[String]] = [
            ["Number", "Timecode In", "Timecode Out", "Text"]
        ]

        for (index, sub) in track.subtitles.enumerated() {
            let inTC = formatTime(sub.startTime)
            let outTC = formatTime(sub.endTime)
            let text = formatText(sub.textBlocks)
            rows.append(["\(index + 1)", inTC, outTC, text])
        }

        return try buildXLSX(rows: rows)
    }

    private static func formatTime(_ tc: Timecode) -> String {
        let (h, m, s, _) = tc.components
        let ms = tc.milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func formatText(_ blocks: [TextBlock]) -> String {
        return blocks.map { block in
            block.segments.map { segment in
                if segment.style.contains(.italic) {
                    return "<i>\(segment.text)</i>"
                }
                return segment.text
            }.joined()
        }.joined(separator: "\n")
    }

    private static func buildXLSX(rows: [[String]]) throws -> Data {
        var sharedStrings: [String] = []
        var sharedIndex: [String: Int] = [:]

        func getOrCreateIndex(_ str: String) -> Int {
            if let idx = sharedIndex[str] { return idx }
            let idx = sharedStrings.count
            sharedStrings.append(str)
            sharedIndex[str] = idx
            return idx
        }

        var sheetXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        sheetXML += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        sheetXML += "<sheetData>"

        for (rowIdx, row) in rows.enumerated() {
            sheetXML += "<row r=\"\(rowIdx + 1)\">"
            for (colIdx, cell) in row.enumerated() {
                let colLetter = columnIndexToLetter(colIdx)
                let cellRef = "\(colLetter)\(rowIdx + 1)"
                if let _ = Int(cell) {
                    sheetXML += "<c r=\"\(cellRef)\"><v>\(cell)</v></c>"
                } else {
                    let idx = getOrCreateIndex(cell)
                    sheetXML += "<c r=\"\(cellRef)\" t=\"s\"><v>\(idx)</v></c>"
                }
            }
            sheetXML += "</row>"
        }
        sheetXML += "</sheetData></worksheet>"

        var ssXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        ssXML += "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"\(sharedStrings.count)\" uniqueCount=\"\(sharedStrings.count)\">"
        for str in sharedStrings {
            let escaped = str
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            ssXML += "<si><t>\(escaped)</t></si>"
        }
        ssXML += "</sst>"

        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>"

        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"

        let workbook = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Subtitles\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"

        let wbRels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"

        let styles = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"2\"><font><sz val=\"11\"/></font><font><sz val=\"11\"/><i/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs></styleSheet>"

        let entries: [(String, Data)] = [
            ("[Content_Types].xml", contentTypes.data(using: .utf8)!),
            ("_rels/.rels", rels.data(using: .utf8)!),
            ("xl/workbook.xml", workbook.data(using: .utf8)!),
            ("xl/_rels/workbook.xml.rels", wbRels.data(using: .utf8)!),
            ("xl/worksheets/sheet1.xml", sheetXML.data(using: .utf8)!),
            ("xl/sharedStrings.xml", ssXML.data(using: .utf8)!),
            ("xl/styles.xml", styles.data(using: .utf8)!),
        ]

        return try ZIPWriter.write(entries)
    }

    private static func columnIndexToLetter(_ index: Int) -> String {
        var result = ""
        var n = index
        repeat {
            result = String(UnicodeScalar(65 + (n % 26))!) + result
            n = (n / 26) - 1
        } while n >= 0
        return result
    }
}

// MARK: - Minimal ZIP Writer

/// Minimal ZIP archive writer using stored (no compression) entries.
/// Sufficient for XLSX/DOCX which are just ZIP containers of XML files.
enum ZIPWriter {
    static func write(_ entries: [(String, Data)]) throws -> Data {
        var out = Data()
        var centralEntries: [(offset: UInt32, name: String, size: UInt32, crc: UInt32)] = []

        for (name, data) in entries {
            let nameData = name.data(using: .utf8)!
            let crc = data.crc32
            let size = UInt32(data.count)
            let nameLen = UInt16(nameData.count)
            let localStart = UInt32(out.count)

            // Local file header
            out.append(contentsOf: pack32(0x04034b50)) // signature
            out.append(contentsOf: pack16(20))          // version needed
            out.append(contentsOf: pack16(0))           // flags
            out.append(contentsOf: pack16(0))            // compression: stored
            out.append(contentsOf: pack16(0))           // mod time
            out.append(contentsOf: pack16(0))           // mod date
            out.append(contentsOf: pack32(crc))
            out.append(contentsOf: pack32(size))         // compressed size
            out.append(contentsOf: pack32(size))         // uncompressed size
            out.append(contentsOf: pack16(nameLen))
            out.append(contentsOf: pack16(0))            // extra field len
            out.append(nameData)
            out.append(data)

            centralEntries.append((offset: localStart, name: name, size: size, crc: crc))
        }

        let centralStart = UInt32(out.count)

        for entry in centralEntries {
            let nameData = entry.name.data(using: .utf8)!
            let nameLen = UInt16(nameData.count)

            out.append(contentsOf: pack32(0x02014b50))   // signature
            out.append(contentsOf: pack16(20))            // version made by
            out.append(contentsOf: pack16(20))            // version needed
            out.append(contentsOf: pack16(0))             // flags
            out.append(contentsOf: pack16(0))              // compression: stored
            out.append(contentsOf: pack16(0))              // mod time
            out.append(contentsOf: pack16(0))              // mod date
            out.append(contentsOf: pack32(entry.crc))
            out.append(contentsOf: pack32(entry.size))     // compressed size
            out.append(contentsOf: pack32(entry.size))     // uncompressed size
            out.append(contentsOf: pack16(nameLen))
            out.append(contentsOf: pack16(0))               // extra field len
            out.append(contentsOf: pack16(0))               // file comment len
            out.append(contentsOf: pack16(0))               // disk number
            out.append(contentsOf: pack16(0))               // internal attrs
            out.append(contentsOf: pack32(0))               // external attrs
            out.append(contentsOf: pack32(entry.offset))    // local header offset
            out.append(nameData)
        }

        let centralSize = UInt32(out.count) - centralStart
        let entryCount = UInt16(centralEntries.count)

        // End of central directory
        out.append(contentsOf: pack32(0x06054b50))
        out.append(contentsOf: pack16(0))                 // disk number
        out.append(contentsOf: pack16(0))                 // disk with central dir
        out.append(contentsOf: pack16(entryCount))        // entries on this disk
        out.append(contentsOf: pack16(entryCount))        // total entries
        out.append(contentsOf: pack32(centralSize))        // central dir size
        out.append(contentsOf: pack32(centralStart))       // central dir offset
        out.append(contentsOf: pack16(0))                  // comment len

        return out
    }

    private static func pack16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func pack32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}

// MARK: - CRC32

private extension Data {
    var crc32: UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in self {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - ZIP Reader

/// Minimal ZIP archive reader supporting stored (uncompressed) entries.
/// Sufficient for XLSX/DOCX files where the central directory is at the end of the file.
enum ZIPReader {
    static func read(data: Data) -> [String: Data] {
        var entries: [String: Data] = [:]
        guard data.count > 22 else { return entries }
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard let eocdRange = data.range(of: Data(signature)) else { return entries }
        let eocdOffset = eocdRange.lowerBound
        guard eocdOffset + 22 <= data.count else { return entries }

        let totalEntries: Int = data.withUnsafeBytes { ptr -> Int in
            let base = ptr.baseAddress!.advanced(by: eocdOffset).assumingMemoryBound(to: UInt8.self)
            return Int(UInt16(base[10]) | (UInt16(base[11]) << 8))
        }
        let cdOffset: Int = data.withUnsafeBytes { ptr -> Int in
            let base = ptr.baseAddress!.advanced(by: eocdOffset).assumingMemoryBound(to: UInt8.self)
            let lo = UInt32(base[12]) | (UInt32(base[13]) << 8) | (UInt32(base[14]) << 16) | (UInt32(base[15]) << 24)
            return Int(lo)
        }

        var pos = cdOffset
        for _ in 0..<totalEntries {
            guard pos + 46 <= data.count else { break }
            guard data[pos] == 0x50, data[pos + 1] == 0x4B, data[pos + 2] == 0x01, data[pos + 3] == 0x02 else { break }
            let compMethod: UInt16 = data.withUnsafeBytes { ptr in
                let base = ptr.baseAddress!.advanced(by: pos + 10).assumingMemoryBound(to: UInt8.self)
                return UInt16(base[0]) | (UInt16(base[1]) << 8)
            }
            let compSize: Int = data.withUnsafeBytes { ptr in
                let base = ptr.baseAddress!.advanced(by: pos + 20).assumingMemoryBound(to: UInt8.self)
                let lo = UInt32(base[0]) | (UInt32(base[1]) << 8) | (UInt32(base[2]) << 16) | (UInt32(base[3]) << 24)
                return Int(lo)
            }
            let uncompSize: Int = data.withUnsafeBytes { ptr in
                let base = ptr.baseAddress!.advanced(by: pos + 24).assumingMemoryBound(to: UInt8.self)
                let lo = UInt32(base[0]) | (UInt32(base[1]) << 8) | (UInt32(base[2]) << 16) | (UInt32(base[3]) << 24)
                return Int(lo)
            }
            let nameLen: Int = data.withUnsafeBytes { ptr in
                let base = ptr.baseAddress!.advanced(by: pos + 28).assumingMemoryBound(to: UInt8.self)
                return Int(UInt16(base[0]) | (UInt16(base[1]) << 8))
            }
            let extraLen: Int = data.withUnsafeBytes { ptr in
                let base = ptr.baseAddress!.advanced(by: pos + 30).assumingMemoryBound(to: UInt8.self)
                return Int(UInt16(base[0]) | (UInt16(base[1]) << 8))
            }
            let commentLen: Int = data.withUnsafeBytes { ptr in
                let base = ptr.baseAddress!.advanced(by: pos + 32).assumingMemoryBound(to: UInt8.self)
                return Int(UInt16(base[0]) | (UInt16(base[1]) << 8))
            }
            let localHeaderOffset: Int = data.withUnsafeBytes { ptr in
                let base = ptr.baseAddress!.advanced(by: pos + 42).assumingMemoryBound(to: UInt8.self)
                let lo = UInt32(base[0]) | (UInt32(base[1]) << 8) | (UInt32(base[2]) << 16) | (UInt32(base[3]) << 24)
                return Int(lo)
            }

            guard pos + 46 + nameLen <= data.count else { break }
            let nameData = data.subdata(in: (pos + 46)..<(pos + 46 + nameLen))
            guard let name = String(data: nameData, encoding: .utf8) else {
                pos += 46 + nameLen + extraLen + commentLen
                continue
            }

            guard localHeaderOffset + 30 + nameLen + compSize <= data.count else {
                pos += 46 + nameLen + extraLen + commentLen
                continue
            }
            let fileDataStart = localHeaderOffset + 30 + nameLen
            let entryData = data.subdata(in: fileDataStart..<(fileDataStart + compSize))

            if compMethod == 0 {
                entries[name] = entryData
            } else if compMethod == 8 {
                if let decompressed = inflateDeflate(entryData, uncompressedSize: uncompSize) {
                    entries[name] = decompressed
                }
            }

            pos += 46 + nameLen + extraLen + commentLen
        }

        return entries
    }

    private static func inflateDeflate(_ data: Data, uncompressedSize: Int) -> Data? {
        let bufferSize = max(uncompressedSize, 1024)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let resultCount = data.withUnsafeBytes { src -> Int in
            guard let srcBase = src.baseAddress else { return 0 }
            return compression_decode_buffer(
                buffer,
                bufferSize,
                srcBase.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard resultCount > 0 else { return nil }
        return Data(bytes: buffer, count: resultCount)
    }
}