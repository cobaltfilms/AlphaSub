import Foundation
import CoreGraphics
import CoreText
import AlphaSubCore

/// Subsets a TrueType font to the glyphs needed for a set of characters.
///
/// DCP InterOp (CineCanvas) limits the embedded font file to 640 KB; full
/// fonts like Arial (~770 KB) exceed it. Mastering tools solve this by
/// subsetting the font to the glyphs the subtitles actually use — which is
/// inherently "per language" since the text carries the language's glyphs.
///
/// Scope: TrueType outlines only (`glyf`/`loca`). CFF/OpenType (`OTTO`) and
/// TrueType Collections (`ttcf`) are not subsettable here and throw
/// `.unsupportedFont`; callers should fall back to the original data.
/// Layout tables (GSUB/GPOS/kern) are dropped — cinema subtitle renderers
/// don't shape, they map characters straight through `cmap`.
public enum FontSubsetter {

    public enum SubsetError: LocalizedError {
        case unsupportedFont(String)
        case malformedFont(String)
        case validationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFont(let s):   return s
            case .malformedFont(let s):      return s
            case .validationFailed(let s):   return s
            }
        }
    }

    /// All characters appearing in the tracks' subtitle text, plus a basic
    /// Latin safety set (ASCII printable) so late text edits of common
    /// characters don't render as .notdef on a mastered reel.
    public static func charactersUsed(in tracks: [Track]) -> Set<Character> {
        var chars = Set<Character>()
        for scalar in UInt32(0x20)...UInt32(0x7E) {
            if let u = Unicode.Scalar(scalar) { chars.insert(Character(u)) }
        }
        chars.insert("\u{00A0}")  // no-break space
        for track in tracks {
            for sub in track.subtitles {
                for block in sub.textBlocks {
                    for seg in block.segments {
                        chars.formUnion(seg.text)
                    }
                }
            }
        }
        return chars
    }

    /// The DLP/CineCanvas embedded-font cap (640 KB). It is an InterOp rule
    /// (TI Subtitle Specification §2.7) — SMPTE ST 428-7 imposes no font size
    /// limit — but ClairMeta enforces it for both standards, so both writers
    /// subset oversized fonts.
    public static let dcpMaxFontBytes = 640 * 1024

    /// Brings an embedded DCP font under the 640 KB cap: subsets to the glyphs
    /// the tracks use when oversized, returns the data unchanged otherwise.
    /// Throws `FormatError.invalidData` when the font can't be brought under
    /// the cap (unsupported format, or still too big after subsetting).
    public static func limitForDCP(fontData: Data, tracks: [Track]) throws -> Data {
        guard fontData.count > dcpMaxFontBytes else { return fontData }
        let used = charactersUsed(in: tracks)
        do {
            let subset = try self.subset(fontData: fontData, keepingCharacters: used)
            guard subset.count <= dcpMaxFontBytes else {
                throw FormatError.invalidData("Font still exceeds 640 KB after subsetting (\(subset.count) bytes) — choose a lighter font for DCP export")
            }
            return subset
        } catch let error as FormatError {
            throw error
        } catch {
            throw FormatError.invalidData("DCP font exceeds 640 KB (\(fontData.count) bytes) and could not be subset (\(error)). Choose a TrueType font under 640 KB.")
        }
    }

    /// Returns a subset font containing only the glyphs for `characters`
    /// (plus .notdef and composite components). The result is validated by
    /// re-loading it with CoreText and checking glyph coverage.
    public static func subset(fontData: Data, keepingCharacters characters: Set<Character>) throws -> Data {
        let font = try SFNTFont(data: fontData)

        // Map wanted characters (BMP only — format 4 cmap) to glyph IDs.
        var keptChars: [UInt16: UInt16] = [:]   // unicode -> old gid
        for ch in characters {
            for scalar in ch.unicodeScalars where scalar.value <= 0xFFFF {
                let code = UInt16(scalar.value)
                if let gid = font.cmap[code], gid != 0 {
                    keptChars[code] = gid
                }
            }
        }
        guard !keptChars.isEmpty else {
            throw SubsetError.malformedFont("no requested characters present in font cmap")
        }

        // Glyph closure: .notdef + mapped glyphs + composite components.
        var keep = Set<UInt16>([0])
        var queue = Array(Set(keptChars.values))
        while let gid = queue.popLast() {
            guard !keep.contains(gid) else { continue }
            keep.insert(gid)
            for comp in try font.compositeComponents(ofGlyph: gid) where !keep.contains(comp) {
                queue.append(comp)
            }
        }

        let oldGIDs = keep.sorted()
        var newGID: [UInt16: UInt16] = [:]
        for (new, old) in oldGIDs.enumerated() { newGID[old] = UInt16(new) }

        // Rebuild glyf + loca (long format), remapping composite references.
        var glyf = Data()
        var loca = Data()
        loca.appendUInt32(0)
        for old in oldGIDs {
            var glyphBytes = try font.glyphData(ofGlyph: old)
            try Self.remapCompositeReferences(in: &glyphBytes, using: newGID)
            glyf.append(glyphBytes)
            while glyf.count % 4 != 0 { glyf.append(0) }   // 4-align entries
            loca.appendUInt32(UInt32(glyf.count))
        }

        // Rebuild hmtx with full metrics for every kept glyph.
        var hmtx = Data()
        for old in oldGIDs {
            let (advance, lsb) = font.horizontalMetrics(ofGlyph: old)
            hmtx.appendUInt16(advance)
            hmtx.appendInt16(lsb)
        }

        // Rebuild cmap: single (3,1) format-4 subtable over the kept chars.
        let cmap = Self.buildCmapFormat4(mapping: keptChars.mapValues { newGID[$0]! })

        // Patch fixed tables.
        var head = font.table("head")!
        head.replaceUInt16(at: 50, with: 1)            // indexToLocFormat = long
        head.replaceUInt32(at: 8, with: 0)             // checkSumAdjustment, recomputed below

        var hhea = font.table("hhea")!
        hhea.replaceUInt16(at: 34, with: UInt16(oldGIDs.count))  // numberOfHMetrics

        var maxp = font.table("maxp")!
        maxp.replaceUInt16(at: 4, with: UInt16(oldGIDs.count))   // numGlyphs

        // post v3.0: keep the 32-byte header, no glyph names.
        var post = font.table("post") ?? Data(count: 32)
        if post.count > 32 { post = post.prefix(32) }
        while post.count < 32 { post.append(0) }
        post.replaceUInt32(at: 0, with: 0x00030000)

        // Assemble the new sfnt. Keep hinting + metadata tables verbatim.
        var tables: [(tag: String, data: Data)] = [
            ("cmap", cmap), ("glyf", glyf), ("head", head),
            ("hhea", hhea), ("hmtx", hmtx), ("loca", loca),
            ("maxp", maxp), ("post", post),
        ]
        for tag in ["cvt ", "fpgm", "prep", "OS/2", "name"] {
            if let data = font.table(tag) { tables.append((tag, data)) }
        }
        var output = Self.assembleSFNT(tables: tables)

        // head.checkSumAdjustment = 0xB1B0AFBA − checksum(entire font)
        let total = Self.checksum(output)
        if let headRecordOffset = Self.tableOffset(in: output, tag: "head") {
            output.replaceUInt32(at: headRecordOffset + 8, with: 0xB1B0AFBA &- total)
        }

        try Self.validate(output, characters: keptChars.keys)
        return output
    }

    // MARK: - Composite remapping

    private static func remapCompositeReferences(in glyph: inout Data, using newGID: [UInt16: UInt16]) throws {
        guard glyph.count >= 10 else { return }                  // empty glyph
        let contours = Int16(bitPattern: glyph.readUInt16(at: 0))
        guard contours < 0 else { return }                       // simple glyph
        var offset = 10
        while true {
            guard offset + 4 <= glyph.count else {
                throw SubsetError.malformedFont("truncated composite glyph")
            }
            let flags = glyph.readUInt16(at: offset)
            let component = glyph.readUInt16(at: offset + 2)
            guard let mapped = newGID[component] else {
                throw SubsetError.malformedFont("composite references unkept glyph \(component)")
            }
            glyph.replaceUInt16(at: offset + 2, with: mapped)
            offset += 4
            offset += (flags & 0x0001) != 0 ? 4 : 2              // ARG_1_AND_2_ARE_WORDS
            if (flags & 0x0008) != 0 { offset += 2 }             // WE_HAVE_A_SCALE
            else if (flags & 0x0040) != 0 { offset += 4 }        // X_AND_Y_SCALE
            else if (flags & 0x0080) != 0 { offset += 8 }        // TWO_BY_TWO
            if (flags & 0x0020) == 0 { break }                   // MORE_COMPONENTS
        }
    }

    // MARK: - cmap format 4

    private static func buildCmapFormat4(mapping: [UInt16: UInt16]) -> Data {
        // Contiguous character ranges; glyph IDs via glyphIdArray (idRangeOffset).
        let codes = mapping.keys.sorted()
        var segments: [(start: UInt16, end: UInt16)] = []
        for code in codes {
            if let last = segments.last, code == last.end + 1 {
                segments[segments.count - 1].end = code
            } else {
                segments.append((code, code))
            }
        }
        segments.append((0xFFFF, 0xFFFF))                        // required final segment
        let segCount = segments.count

        var glyphIdArray: [UInt16] = []
        var idRangeOffsets: [UInt16] = []
        for (i, seg) in segments.enumerated() {
            if seg.start == 0xFFFF {
                idRangeOffsets.append(0)                          // final segment, idDelta path
                continue
            }
            // offset from THIS segment's idRangeOffset slot to its glyph ids
            let remainingSlots = segCount - i
            let offsetWords = remainingSlots + glyphIdArray.count
            idRangeOffsets.append(UInt16(offsetWords * 2))
            for code in seg.start...seg.end {
                glyphIdArray.append(mapping[code] ?? 0)
            }
        }

        var sub = Data()
        sub.appendUInt16(4)                                       // format
        let length = 16 + segCount * 8 + glyphIdArray.count * 2
        sub.appendUInt16(UInt16(length))
        sub.appendUInt16(0)                                       // language
        sub.appendUInt16(UInt16(segCount * 2))                    // segCountX2
        let searchRange = UInt16(2 * Int(pow(2, floor(log2(Double(segCount))))))
        sub.appendUInt16(searchRange)
        sub.appendUInt16(UInt16(log2(Double(searchRange / 2))))
        sub.appendUInt16(UInt16(segCount * 2) - searchRange)
        for seg in segments { sub.appendUInt16(seg.end) }
        sub.appendUInt16(0)                                       // reservedPad
        for seg in segments { sub.appendUInt16(seg.start) }
        for seg in segments {                                     // idDelta
            sub.appendInt16(seg.start == 0xFFFF ? 1 : 0)
        }
        for off in idRangeOffsets { sub.appendUInt16(off) }
        for gid in glyphIdArray { sub.appendUInt16(gid) }

        var cmap = Data()
        cmap.appendUInt16(0)                                      // version
        cmap.appendUInt16(1)                                      // one subtable
        cmap.appendUInt16(3)                                      // platform: Windows
        cmap.appendUInt16(1)                                      // encoding: Unicode BMP
        cmap.appendUInt32(12)                                     // offset to subtable
        cmap.append(sub)
        return cmap
    }

    // MARK: - sfnt assembly

    private static func assembleSFNT(tables: [(tag: String, data: Data)]) -> Data {
        let sorted = tables.sorted { $0.tag < $1.tag }
        let numTables = sorted.count
        var header = Data()
        header.appendUInt32(0x00010000)                           // TrueType
        header.appendUInt16(UInt16(numTables))
        let entrySelector = UInt16(floor(log2(Double(numTables))))
        let searchRange = UInt16(16 * Int(pow(2, Double(entrySelector))))
        header.appendUInt16(searchRange)
        header.appendUInt16(entrySelector)
        header.appendUInt16(UInt16(numTables * 16) - searchRange)

        var records = Data()
        var body = Data()
        var offset = 12 + numTables * 16
        for (tag, data) in sorted {
            var padded = data
            while padded.count % 4 != 0 { padded.append(0) }
            records.append(contentsOf: tag.utf8.prefix(4))
            records.appendUInt32(checksum(padded))
            records.appendUInt32(UInt32(offset))
            records.appendUInt32(UInt32(data.count))
            body.append(padded)
            offset += padded.count
        }
        return header + records + body
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var padded = data
        while padded.count % 4 != 0 { padded.append(0) }
        var sum: UInt32 = 0
        for i in stride(from: 0, to: padded.count, by: 4) {
            sum = sum &+ padded.readUInt32(at: i)
        }
        return sum
    }

    /// Byte offset of a table's directory record in an assembled font, or nil.
    private static func tableOffset(in font: Data, tag: String) -> Int? {
        let numTables = Int(font.readUInt16(at: 4))
        for i in 0..<numTables {
            let rec = 12 + i * 16
            let recTag = String(bytes: font[rec..<rec+4], encoding: .ascii)
            if recTag == tag {
                return Int(font.readUInt32(at: rec + 8))
            }
        }
        return nil
    }

    // MARK: - Validation

    private static func validate<S: Sequence>(_ data: Data, characters: S) throws where S.Element == UInt16 {
        guard let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else {
            throw SubsetError.validationFailed("subset font does not load")
        }
        let ctFont = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
        for code in characters {
            var chars = [UniChar(code)]
            var glyphs = [CGGlyph(0)]
            guard CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, 1), glyphs[0] != 0 else {
                throw SubsetError.validationFailed("missing glyph for U+\(String(code, radix: 16, uppercase: true))")
            }
        }
    }
}

// MARK: - SFNT parsing

private struct SFNTFont {
    let data: Data
    private var tableRanges: [String: Range<Int>] = [:]
    let cmap: [UInt16: UInt16]
    private let locaOffsets: [Int]
    private let glyfRange: Range<Int>
    private let metrics: (count: Int, hmtxRange: Range<Int>)

    init(data: Data) throws {
        self.data = data
        guard data.count >= 12 else { throw FontSubsetter.SubsetError.malformedFont("too small") }
        let version = data.readUInt32(at: 0)
        if version == 0x4F54544F {                                 // 'OTTO'
            throw FontSubsetter.SubsetError.unsupportedFont("CFF/OpenType outlines cannot be subset")
        }
        if version == 0x74746366 {                                 // 'ttcf'
            throw FontSubsetter.SubsetError.unsupportedFont("TrueType Collections cannot be subset")
        }
        guard version == 0x00010000 || version == 0x74727565 else { // 1.0 or 'true'
            throw FontSubsetter.SubsetError.unsupportedFont("not a TrueType font")
        }
        let numTables = Int(data.readUInt16(at: 4))
        var ranges: [String: Range<Int>] = [:]
        for i in 0..<numTables {
            let rec = 12 + i * 16
            guard rec + 16 <= data.count,
                  let tag = String(bytes: data[rec..<rec+4], encoding: .ascii) else { continue }
            let offset = Int(data.readUInt32(at: rec + 8))
            let length = Int(data.readUInt32(at: rec + 12))
            guard offset + length <= data.count else {
                throw FontSubsetter.SubsetError.malformedFont("table \(tag) out of bounds")
            }
            ranges[tag] = offset..<(offset + length)
        }
        self.tableRanges = ranges

        guard let headR = ranges["head"], let maxpR = ranges["maxp"],
              let locaR = ranges["loca"], let glyfR = ranges["glyf"],
              let cmapR = ranges["cmap"], let hheaR = ranges["hhea"],
              let hmtxR = ranges["hmtx"] else {
            throw FontSubsetter.SubsetError.unsupportedFont("missing required TrueType tables")
        }

        let numGlyphs = Int(data.readUInt16(at: maxpR.lowerBound + 4))
        let longLoca = data.readUInt16(at: headR.lowerBound + 50) == 1
        var offsets: [Int] = []
        offsets.reserveCapacity(numGlyphs + 1)
        for i in 0...numGlyphs {
            if longLoca {
                offsets.append(Int(data.readUInt32(at: locaR.lowerBound + i * 4)))
            } else {
                offsets.append(Int(data.readUInt16(at: locaR.lowerBound + i * 2)) * 2)
            }
        }
        self.locaOffsets = offsets
        self.glyfRange = glyfR

        let numberOfHMetrics = Int(data.readUInt16(at: hheaR.lowerBound + 34))
        self.metrics = (numberOfHMetrics, hmtxR)

        self.cmap = Self.parseCmap(data: data, range: cmapR)
    }

    func table(_ tag: String) -> Data? {
        tableRanges[tag].map { Data(data[$0]) }
    }

    func glyphData(ofGlyph gid: UInt16) throws -> Data {
        let i = Int(gid)
        guard i + 1 < locaOffsets.count else {
            throw FontSubsetter.SubsetError.malformedFont("glyph \(gid) out of range")
        }
        let start = glyfRange.lowerBound + locaOffsets[i]
        let end = glyfRange.lowerBound + locaOffsets[i + 1]
        guard start <= end, end <= glyfRange.upperBound else {
            throw FontSubsetter.SubsetError.malformedFont("bad loca for glyph \(gid)")
        }
        return Data(data[start..<end])
    }

    func compositeComponents(ofGlyph gid: UInt16) throws -> [UInt16] {
        let glyph = try glyphData(ofGlyph: gid)
        guard glyph.count >= 10 else { return [] }
        let contours = Int16(bitPattern: glyph.readUInt16(at: 0))
        guard contours < 0 else { return [] }
        var comps: [UInt16] = []
        var offset = 10
        while true {
            guard offset + 4 <= glyph.count else { break }
            let flags = glyph.readUInt16(at: offset)
            comps.append(glyph.readUInt16(at: offset + 2))
            offset += 4
            offset += (flags & 0x0001) != 0 ? 4 : 2
            if (flags & 0x0008) != 0 { offset += 2 }
            else if (flags & 0x0040) != 0 { offset += 4 }
            else if (flags & 0x0080) != 0 { offset += 8 }
            if (flags & 0x0020) == 0 { break }
        }
        return comps
    }

    func horizontalMetrics(ofGlyph gid: UInt16) -> (advance: UInt16, lsb: Int16) {
        let i = Int(gid)
        let base = metrics.hmtxRange.lowerBound
        if i < metrics.count {
            return (data.readUInt16(at: base + i * 4),
                    Int16(bitPattern: data.readUInt16(at: base + i * 4 + 2)))
        }
        let lastAdvance = metrics.count > 0 ? data.readUInt16(at: base + (metrics.count - 1) * 4) : 0
        let lsbIndex = base + metrics.count * 4 + (i - metrics.count) * 2
        let lsb = lsbIndex + 2 <= metrics.hmtxRange.upperBound
            ? Int16(bitPattern: data.readUInt16(at: lsbIndex)) : 0
        return (lastAdvance, lsb)
    }

    private static func parseCmap(data: Data, range: Range<Int>) -> [UInt16: UInt16] {
        let base = range.lowerBound
        let numTables = Int(data.readUInt16(at: base + 2))
        var best: Int? = nil
        for i in 0..<numTables {
            let rec = base + 4 + i * 8
            let platform = data.readUInt16(at: rec)
            let encoding = data.readUInt16(at: rec + 2)
            let offset = Int(data.readUInt32(at: rec + 4))
            let format = data.readUInt16(at: base + offset)
            if format == 4, (platform == 3 && encoding == 1) || platform == 0 {
                best = base + offset
                break
            }
            if format == 4, best == nil { best = base + offset }
        }
        guard let sub = best else { return [:] }

        var map: [UInt16: UInt16] = [:]
        let segCountX2 = Int(data.readUInt16(at: sub + 6))
        let segCount = segCountX2 / 2
        let endCodes = sub + 14
        let startCodes = endCodes + segCountX2 + 2
        let idDeltas = startCodes + segCountX2
        let idRangeOffsets = idDeltas + segCountX2
        for seg in 0..<segCount {
            let end = data.readUInt16(at: endCodes + seg * 2)
            let start = data.readUInt16(at: startCodes + seg * 2)
            guard start <= end, start != 0xFFFF else { continue }
            let delta = data.readUInt16(at: idDeltas + seg * 2)
            let rangeOffset = Int(data.readUInt16(at: idRangeOffsets + seg * 2))
            for code in start...end {
                let gid: UInt16
                if rangeOffset == 0 {
                    gid = code &+ delta
                } else {
                    let addr = idRangeOffsets + seg * 2 + rangeOffset + Int(code - start) * 2
                    guard addr + 2 <= data.count else { continue }
                    let raw = data.readUInt16(at: addr)
                    gid = raw == 0 ? 0 : raw &+ delta
                }
                if gid != 0 { map[code] = gid }
                if code == 0xFFFF { break }
            }
        }
        return map
    }
}

// MARK: - Big-endian Data helpers

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }
    func readUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8(v >> 8)); append(UInt8(v & 0xFF))
    }
    mutating func appendInt16(_ v: Int16) {
        appendUInt16(UInt16(bitPattern: v))
    }
    mutating func appendUInt32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }
    mutating func replaceUInt16(at offset: Int, with v: UInt16) {
        let i = startIndex + offset
        self[i] = UInt8(v >> 8); self[i + 1] = UInt8(v & 0xFF)
    }
    mutating func replaceUInt32(at offset: Int, with v: UInt32) {
        let i = startIndex + offset
        self[i] = UInt8(v >> 24); self[i + 1] = UInt8((v >> 16) & 0xFF)
        self[i + 2] = UInt8((v >> 8) & 0xFF); self[i + 3] = UInt8(v & 0xFF)
    }
}
