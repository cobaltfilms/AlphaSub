import Foundation

// MARK: - Frame-wrapped MXF picture reader (open-core)
//
// A DCP picture track is a SMPTE 429-4 MXF that FRAME-wraps JPEG2000: every
// frame is its own KLV triplet (16-byte SMPTE UL key + BER length + value),
// and each value is a complete J2K codestream (SOC `FF 4F` … EOC `FF D9`).
// Random access is therefore just "seek to the Nth picture KLV and read its
// value" — no MXF library, no index-table parsing required. We build the
// frame offset/length index once on open by walking the KLV stream and
// sniffing values that begin with the J2K SOC marker; thereafter
// `codestream(at:)` is a single seek + read.
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

    /// One frame's location inside the MXF: byte offset of the codestream and
    /// its length. Kept tiny (16 bytes) so even a 3-hour feature — ~260 000
    /// frames — indexes in a few MB.
    public struct FrameEntry: Sendable {
        public let offset: UInt64
        public let length: UInt64
        /// True when the value is a SMPTE 429-6 encrypted triplet (decrypt on read).
        public let encrypted: Bool
    }

    private static let ulPrefix: [UInt8] = [0x06, 0x0E, 0x2B, 0x34]
    /// J2K codestream start-of-codestream + SIZ markers.
    private static let socMarker: [UInt8] = [0xFF, 0x4F, 0xFF, 0x51]

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
        try handle.seek(toOffset: entry.offset)
        guard let data = try handle.read(upToCount: Int(entry.length)),
              data.count == Int(entry.length) else {
            throw ReaderError.malformed("truncated picture frame \(i)")
        }
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
        try handle.seek(toOffset: 0)

        var frames: [FrameEntry] = []
        while true {
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
                    frames.append(FrameEntry(offset: valueStart, length: length, encrypted: false))
                } else if DCPEssenceDecryptor.isEncryptedFrame(peek, kind: .picture) {
                    frames.append(FrameEntry(offset: valueStart, length: length, encrypted: true))
                }
            }
            try handle.seek(toOffset: valueStart + length)
        }

        guard !frames.isEmpty else { throw ReaderError.noPictureFrames }
        frameIndex = frames
        return frames
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
