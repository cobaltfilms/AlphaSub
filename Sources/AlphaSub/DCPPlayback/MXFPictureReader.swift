import Foundation

// MARK: - Frame-wrapped MXF picture reader (open-core)
//
// A DCP picture track is a SMPTE 429-4 MXF that FRAME-wraps JPEG2000: every
// frame is its own KLV triplet (16-byte SMPTE UL key + BER length + value),
// and each value is a complete J2K codestream (SOC `FF 4F` … EOC `FF D9`).
// Random access is therefore just "seek to the Nth picture KLV and read its
// value"; `codestream(at:)` is a single seek + read.
//
// The frame index is built once on open, from the MXF's OWN index table.
//
// It used to be built by walking the whole KLV stream — three small reads and
// a seek per frame. That is fine on an NVMe (a few seconds for a feature) and
// catastrophic over SMB or NFS, where each of those becomes a network round
// trip: a 119 000-frame feature costs the best part of half a million of them,
// and the picture takes twenty minutes to open. Which is how DCPs are actually
// stored — on a shared volume, not a local disk.
//
// The index table makes that three reads TOTAL, because every conformant MXF
// already carries the answer:
//
//   RandomIndexPack   last 4 bytes → its own length → the partition offsets.
//                     Note there are THREE of them (header, body, footer) —
//                     an OP-Atom DCP does NOT put each frame in its own
//                     partition, so the RIP is a map of the file, not of the
//                     frames.
//   IndexTableSegment in the footer partition, one 11-byte entry per frame
//                     carrying a StreamOffset. ~1.3 MB for a feature, read in
//                     one go, parsed in ~20 ms.
//
// The KLV walk survives as the last resort, for the MXF that carries no usable
// index table — a validator's job is to describe a malformed file, and a
// player's is to play it anyway if it can.
//
// This reader is deliberately dependency-free (Foundation only) so DCP
// *playback* can live in the open-core package independently of the
// paywalled DCP-authoring code. The caller supplies the picture MXF URL
// (resolved from the composition) — this type knows nothing about ASSETMAP,
// CPL or reels.

public final class MXFPictureReader {

    public enum ReaderError: LocalizedError {
        case cannotOpen
        case notMXF
        case noPictureFrames
        case frameOutOfRange(Int)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen:
                return String(localized: "Cannot open the DCP picture MXF.")
            case .notMXF:
                return String(localized: "This file is not an MXF (no KLV structure found).")
            case .noPictureFrames:
                return String(localized: "No JPEG2000 picture frames were found in the MXF. If the DCP is encrypted, it must be decrypted first.")
            case .frameOutOfRange(let i):
                return String(localized: "Requested picture frame \(i) is out of range.")
            case .malformed(let m):
                return String(localized: "The picture MXF is malformed: \(m)")
            }
        }
    }

    /// One frame's KLV triplet inside the MXF: where the 16-byte key starts and
    /// how many bytes the whole triplet occupies. Kept tiny (17 bytes) so even
    /// a 3-hour feature — ~260 000 frames — indexes in a few MB.
    ///
    /// The KLV EXTENT rather than the value extent, deliberately. The index
    /// table gives frame positions as offsets to the key; deriving the value
    /// position from one would mean knowing the BER length's own size, and
    /// that is a property of the writer, not of the format. Every asdcplib
    /// file measured here uses a 4-byte BER, but a reader that assumed it
    /// would silently hand the decoder twenty bytes of KLV header on a file
    /// that did not. So the header is parsed from the bytes already read for
    /// the frame — no assumption, and no extra I/O.
    public struct FrameEntry: Sendable {
        /// Byte offset of the 16-byte KLV key.
        public let klvOffset: UInt64
        /// Total bytes of key + BER length + value.
        public let klvLength: UInt64
        /// True when the value is a SMPTE 429-6 encrypted triplet (decrypt on read).
        public let encrypted: Bool
    }

    /// Which strategy produced the index. Diagnostics and tests only — nothing
    /// in playback branches on it, but "why was this open slow?" is otherwise
    /// unanswerable from the outside.
    public enum IndexSource: String, Sendable {
        case indexTable, klvWalk
    }

    private(set) public var indexSource: IndexSource = .klvWalk

    private static let ulPrefix: [UInt8] = [0x06, 0x0E, 0x2B, 0x34]
    /// J2K codestream start-of-codestream + SIZ markers.
    private static let socMarker: [UInt8] = [0xFF, 0x4F, 0xFF, 0x51]

    // SMPTE ULs, compared on the bytes that identify the item and ignoring the
    // registry-version byte (7) and the trailing qualifiers, which differ
    // legitimately between writers and spec editions.

    /// ST 377-1 RandomIndexPack.
    private static let ripKey: [UInt8] =
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x11, 0x01, 0x00]
    /// ST 377-1 IndexTableSegment (first 14 bytes; the last two vary).
    private static let indexTableKeyPrefix: [UInt8] =
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x10]
    /// Any partition pack (header/body/footer): 0d.01.02.01.01.__.__ with the
    /// pack kind in byte 13.
    private static let partitionKeyPrefix: [UInt8] =
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01]
    /// KLV Fill item, which may sit between the partition pack and the essence.
    private static let fillKeyPrefix: [UInt8] =
        [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x02, 0x03, 0x01, 0x02, 0x10, 0x01]

    public let url: URL
    private let handle: FileHandle
    /// 16-byte AES content key (MDIK) for an ENCRYPTED picture track. nil for a
    /// plaintext track. Required to read frames from a KDM-encrypted DCP.
    private let pictureKey: Data?
    /// Built lazily on first access, then cached.
    private var frameIndex: [FrameEntry]?

    public init(url: URL, pictureKey: Data? = nil) throws {
        self.url = url
        self.pictureKey = pictureKey
        guard let h = try? FileHandle(forReadingFrom: url) else {
            throw ReaderError.cannotOpen
        }
        self.handle = h
    }

    deinit { try? handle.close() }

    /// Total picture frames in the track.
    public func frameCount() throws -> Int {
        try index().count
    }

    /// The complete J2K codestream for frame `i` (0-based), ready to hand to
    /// the decoder. Bytes are exactly SOC…EOC — no KLV key/length, no fill.
    public func codestream(at i: Int) throws -> Data {
        let idx = try index()
        guard idx.indices.contains(i) else { throw ReaderError.frameOutOfRange(i) }
        let entry = idx[i]
        try handle.seek(toOffset: entry.klvOffset)
        guard let klv = try handle.read(upToCount: Int(entry.klvLength)),
              klv.count == Int(entry.klvLength) else {
            throw ReaderError.malformed("truncated picture frame \(i)")
        }
        // Strip key + BER in memory. One read, whatever the writer's BER form.
        guard klv.count > 17,
              let (valueStart, valueLength) = Self.parseKLVHeader(klv),
              valueStart + valueLength <= klv.count else {
            throw ReaderError.malformed("frame \(i) is not a well-formed KLV triplet")
        }
        let data = klv.subdata(in: valueStart ..< (valueStart + valueLength))
        if entry.encrypted {
            guard let key = pictureKey else {
                throw ReaderError.malformed("encrypted picture frame \(i) but no content key")
            }
            do {
                return try DCPEssenceDecryptor.decryptFrame(data, key: key)
            } catch {
                throw ReaderError.malformed("decrypt frame \(i): \(error.localizedDescription)")
            }
        }
        return data
    }

    // MARK: KLV indexing

    private func index() throws -> [FrameEntry] {
        if let frameIndex { return frameIndex }

        // First key must be a SMPTE UL (the header partition pack).
        try handle.seek(toOffset: 0)
        guard let first = try handle.read(upToCount: 4), Array(first) == Self.ulPrefix else {
            throw ReaderError.notMXF
        }

        // The file's own index table, when it has a usable one. Three reads for
        // the whole feature instead of four per frame.
        if let fast = try? indexFromIndexTable(), !fast.isEmpty {
            indexSource = .indexTable
            frameIndex = fast
            return fast
        }

        indexSource = .klvWalk
        return try indexByWalkingKLVs()
    }

    /// The original strategy: walk every KLV triplet from byte 0 and sniff the
    /// values. Correct on anything, including files with no index table and
    /// files whose index table lies, and far too slow over a network — which
    /// is why it is the fallback rather than the path.
    /// Internal rather than private so the tests can hold the two strategies
    /// side by side and demand identical output — the only check that catches a
    /// fast index which is subtly, silently wrong.
    func indexByWalkingKLVs() throws -> [FrameEntry] {
        try handle.seek(toOffset: 0)

        var frames: [FrameEntry] = []
        while true {
            let keyStart = try handle.offset()
            guard let keyData = try handle.read(upToCount: 16), keyData.count == 16 else {
                break   // clean EOF
            }
            guard Array(keyData.prefix(4)) == Self.ulPrefix else {
                throw ReaderError.malformed("lost KLV sync at offset \(try handle.offset() - 16)")
            }
            let length = try readBERLength(handle)
            let valueStart = try handle.offset()

            // Sniff the value head. A PLAINTEXT picture frame begins with the
            // J2K SOC marker. An ENCRYPTED frame is a SMPTE 429-6 triplet whose
            // SourceKey is a picture essence element (byte 12 == 0x15) — peek
            // enough for the triplet header. Either way, partition packs, header
            // metadata and index tables are skipped.
            if length >= 4 {
                let peekCount = Int(min(length, 96))
                let peek = try handle.read(upToCount: peekCount) ?? Data()
                if Array(peek.prefix(4)) == Self.socMarker {
                    frames.append(FrameEntry(klvOffset: keyStart,
                                             klvLength: (valueStart - keyStart) + length,
                                             encrypted: false))
                } else if DCPEssenceDecryptor.isEncryptedFrame(peek, kind: .picture) {
                    frames.append(FrameEntry(klvOffset: keyStart,
                                             klvLength: (valueStart - keyStart) + length,
                                             encrypted: true))
                }
            }
            try handle.seek(toOffset: valueStart + length)
        }

        guard !frames.isEmpty else { throw ReaderError.noPictureFrames }
        frameIndex = frames
        return frames
    }

    // MARK: The index-table fast path

    /// Builds the frame index from the MXF's RandomIndexPack + IndexTableSegments.
    ///
    /// Returns an empty array — rather than throwing — whenever anything about
    /// the file is not what this path needs. Every such case is a *fallback*,
    /// not an error: the KLV walk will still produce a correct index, and a
    /// picture that opens slowly beats a picture that refuses to open.
    func indexFromIndexTable() throws -> [FrameEntry] {
        let fileSize = try handle.seekToEnd()
        guard fileSize > 64 else { return [] }

        // 1. RandomIndexPack — the last four bytes are its own length.
        try handle.seek(toOffset: fileSize - 4)
        guard let tail = try handle.read(upToCount: 4), tail.count == 4 else { return [] }
        let ripLength = UInt64(tail.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard ripLength > 20, ripLength <= min(fileSize, 1 << 20) else { return [] }

        try handle.seek(toOffset: fileSize - ripLength)
        guard let rip = try handle.read(upToCount: Int(ripLength)), rip.count == Int(ripLength),
              Array(rip.prefix(16)) == Self.ripKey,
              let (ripValueStart, _) = Self.parseKLVHeader(rip) else { return [] }

        // Value: 4-byte overall length, then 12-byte (BodySID, ByteOffset) pairs.
        var partitions: [(bodySID: UInt32, offset: UInt64)] = []
        var p = ripValueStart
        while p + 12 <= rip.count - 4 {
            let sid = rip.subdata(in: p ..< p + 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let off = rip.subdata(in: p + 4 ..< p + 12).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard off < fileSize else { return [] }
            partitions.append((sid, off))
            p += 12
        }
        guard !partitions.isEmpty else { return [] }

        // 2. The index table. It lives in a partition with BodySID 0 — the
        //    footer for every DCP measured, but the header for writers that
        //    front-load it, so both are tried, nearest-the-end first.
        let indexCandidates = partitions
            .filter { $0.bodySID == 0 }
            .map(\.offset)
            .sorted(by: >)
        var streamOffsets: [UInt64] = []
        for candidate in indexCandidates {
            streamOffsets = (try? frameStreamOffsets(fromPartitionAt: candidate,
                                                     fileSize: fileSize)) ?? []
            if !streamOffsets.isEmpty { break }
        }
        guard streamOffsets.count > 1 else { return [] }

        // 3. Where the essence begins: the body partition's first content KLV.
        guard let body = partitions.first(where: { $0.bodySID != 0 })?.offset,
              let essenceStart = try essenceStart(ofPartitionAt: body, fileSize: fileSize)
        else { return [] }

        // 4. The last frame has no successor to measure against. Its KLV runs
        //    to the start of whatever follows the essence — the footer, or the
        //    next partition after the body.
        let afterEssence = partitions
            .map(\.offset)
            .filter { $0 > essenceStart }
            .min() ?? fileSize
        var bounds = streamOffsets.map { essenceStart + $0 }
        bounds.append(afterEssence)
        guard bounds == bounds.sorted(), bounds.last! <= fileSize else { return [] }

        // 5. Trust, then verify. Frame 0's key must actually be a picture
        //    element where the table says it is — an index table that
        //    disagrees with the essence is worse than none, and cheap to
        //    disprove.
        try handle.seek(toOffset: bounds[0])
        guard let head = try handle.read(upToCount: 32), head.count == 32,
              Array(head.prefix(4)) == Self.ulPrefix,
              let encrypted = Self.essenceKind(head) else { return [] }

        var frames: [FrameEntry] = []
        frames.reserveCapacity(bounds.count - 1)
        for i in 0 ..< bounds.count - 1 {
            frames.append(FrameEntry(klvOffset: bounds[i],
                                     klvLength: bounds[i + 1] - bounds[i],
                                     encrypted: encrypted))
        }
        return frames
    }

    /// Every frame's StreamOffset, from the IndexTableSegments in one partition.
    ///
    /// Read in a single sequential pass over the partition — 1.3 MB for a
    /// feature — because the whole point of this path is to stop making one
    /// I/O request per frame.
    private func frameStreamOffsets(fromPartitionAt offset: UInt64,
                                    fileSize: UInt64) throws -> [UInt64] {
        guard offset < fileSize else { return [] }
        let span = min(fileSize - offset, 64 << 20)
        try handle.seek(toOffset: offset)
        guard let buf = try handle.read(upToCount: Int(span)), buf.count > 20 else { return [] }

        // Segments carry their own start position, and a writer is entitled to
        // emit them out of order. Collected with it, then sorted — assuming
        // file order would silently scramble the timeline.
        var segments: [(start: Int64, offsets: [UInt64])] = []
        var i = 0
        while i + 20 <= buf.count {
            let key = Array(buf[i ..< i + 16])
            guard Array(key.prefix(4)) == Self.ulPrefix else { break }
            guard let (valueStart, valueLength) = Self.parseKLVHeader(buf, from: i),
                  valueStart + valueLength <= buf.count else { break }
            if Array(key.prefix(14)) == Self.indexTableKeyPrefix {
                let segment = buf.subdata(in: valueStart ..< valueStart + valueLength)
                if let parsed = Self.parseIndexTableSegment(segment) {
                    segments.append(parsed)
                }
            }
            i = valueStart + valueLength
        }
        guard !segments.isEmpty else { return [] }
        segments.sort { $0.start < $1.start }
        return segments.flatMap(\.offsets)
    }

    /// The byte offset the index table measures its StreamOffsets from: the
    /// first content KLV after a partition pack, skipping any Fill.
    private func essenceStart(ofPartitionAt offset: UInt64, fileSize: UInt64) throws -> UInt64? {
        var cursor = offset
        // A handful of iterations at most: pack, optional fill, essence.
        for _ in 0 ..< 8 {
            guard cursor + 20 < fileSize else { return nil }
            try handle.seek(toOffset: cursor)
            guard let head = try handle.read(upToCount: 32), head.count == 32,
                  Array(head.prefix(4)) == Self.ulPrefix,
                  let (valueStart, valueLength) = Self.parseKLVHeader(head) else { return nil }
            let key = Array(head.prefix(16))
            let isPartition = Array(key.prefix(13)) == Self.partitionKeyPrefix
            let isFill = Array(key.prefix(13)) == Self.fillKeyPrefix
            if !isPartition && !isFill { return cursor }
            cursor += UInt64(valueStart) + UInt64(valueLength)
        }
        return nil
    }

    /// One IndexTableSegment → its start position and its frames' StreamOffsets.
    ///
    /// Handles both index forms: CBE, where every edit unit is the same size
    /// and offsets are arithmetic, and VBE, where each entry carries its own
    /// offset. JPEG2000 is always VBE — frames compress differently — but a
    /// silent-black or test MXF can legitimately be CBE.
    private static func parseIndexTableSegment(_ seg: Data) -> (start: Int64, offsets: [UInt64])? {
        var start: Int64 = 0
        var editUnitByteCount: UInt32 = 0
        var duration: Int64 = 0
        var entryOffsets: [UInt64] = []

        var k = seg.startIndex
        while k + 4 <= seg.endIndex {
            let tag = (UInt16(seg[k]) << 8) | UInt16(seg[k + 1])
            let length = Int((UInt16(seg[k + 2]) << 8) | UInt16(seg[k + 3]))
            let vStart = k + 4
            guard vStart + length <= seg.endIndex else { break }
            let value = seg.subdata(in: vStart ..< vStart + length)

            switch tag {
            case 0x3F0C where length >= 8:      // IndexStartPosition
                start = Int64(bitPattern: value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
            case 0x3F0D where length >= 8:      // IndexDuration
                duration = Int64(bitPattern: value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
            case 0x3F05 where length >= 4:      // EditUnitByteCount (0 = VBE)
                editUnitByteCount = value.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            case 0x3F0A where length >= 8:      // IndexEntryArray
                let count = Int(value.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                let size = Int(value.subdata(in: 4 ..< 8).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                // TemporalOffset(1) + KeyFrameOffset(1) + Flags(1) + StreamOffset(8).
                guard size >= 11, 4 + 4 + count * size <= length else { break }
                entryOffsets.reserveCapacity(count)
                for e in 0 ..< count {
                    let base = 8 + e * size + 3
                    let raw = value.subdata(in: base ..< base + 8)
                    entryOffsets.append(raw.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
                }
            default:
                break
            }
            k = vStart + length
        }

        if !entryOffsets.isEmpty { return (start, entryOffsets) }
        if editUnitByteCount > 0, duration > 0 {
            let stride = UInt64(editUnitByteCount)
            let base = UInt64(max(0, start)) * stride
            return (start, (0 ..< Int(duration)).map { base + UInt64($0) * stride })
        }
        return nil
    }

    /// Whether a KLV key at the head of `head` is a picture essence element
    /// (plaintext) or a SMPTE 429-6 encrypted triplet. nil for anything else,
    /// which means the index table did not point where it claimed to.
    private static func essenceKind(_ head: Data) -> Bool? {
        let key = Array(head.prefix(16))
        // ST 429-4 JPEG2000 picture element: …0d.01.03.01.15.01.08.01.
        if key.count >= 14, key[10] == 0x03, key[11] == 0x01, key[12] == 0x15 { return false }
        // ST 429-6 encrypted triplet.
        if let (valueStart, _) = parseKLVHeader(head), valueStart < head.count {
            let peek = head.subdata(in: valueStart ..< head.count)
            if DCPEssenceDecryptor.isEncryptedFrame(peek, kind: .picture) { return true }
        }
        if key.count >= 14, key[5] == 0x04, key[12] == 0x7E { return true }
        return nil
    }

    /// KLV key + BER length → (value start index, value length), or nil when
    /// the bytes are not a well-formed header.
    static func parseKLVHeader(_ data: Data, from start: Int = 0) -> (Int, Int)? {
        let base = data.startIndex + start
        guard base + 17 <= data.endIndex else { return nil }
        let first = data[base + 16]
        if first < 0x80 {
            return (base + 17, Int(first))
        }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 8, base + 17 + count <= data.endIndex else { return nil }
        var length = 0
        for i in 0 ..< count {
            length = (length << 8) | Int(data[base + 17 + i])
        }
        guard length >= 0 else { return nil }
        return (base + 17 + count, length)
    }


    /// BER length: short form (< 0x80) or long form (0x80 | count, then
    /// count big-endian bytes). 429-4 uses 8-byte long form for picture.
    private func readBERLength(_ handle: FileHandle) throws -> UInt64 {
        guard let firstByte = try handle.read(upToCount: 1)?.first else {
            throw ReaderError.malformed("EOF in BER length")
        }
        if firstByte < 0x80 { return UInt64(firstByte) }
        let count = Int(firstByte & 0x7F)
        guard count > 0, count <= 8,
              let bytes = try handle.read(upToCount: count), bytes.count == count else {
            throw ReaderError.malformed("bad BER length")
        }
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
