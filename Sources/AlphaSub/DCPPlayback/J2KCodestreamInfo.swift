import Foundation

// MARK: - JPEG2000 codestream header (SIZ) parser
//
// The SIZ marker segment (right after SOC) carries everything needed to
// interpret Grok's raw planar output: image geometry, component count and
// per-component bit precision. We parse it directly rather than asking Grok,
// so the fast RAW decode path knows the buffer layout up front.
//
// Layout (all big-endian), ISO/IEC 15444-1 §A.5.1:
//   FF4F                       SOC
//   FF51 Lsiz(2) Rsiz(2)       SIZ marker + length + capabilities
//   Xsiz(4) Ysiz(4)            reference grid size
//   XOsiz(4) YOsiz(4)          image offset
//   XTsiz(4) YTsiz(4)          tile size
//   XTOsiz(4) YTOsiz(4)        tile offset
//   Csiz(2)                    component count
//   per component: Ssiz(1) XRsiz(1) YRsiz(1)

public struct J2KCodestreamInfo: Sendable, Equatable {
    /// Displayed image size (reference grid minus image offset).
    public let width: Int
    public let height: Int
    public let componentCount: Int
    /// Bit precision of component 0 (DCP components share one precision).
    public let precision: Int
    /// True for a 4K DCI profile (Rsiz == 4); false for 2K (Rsiz == 3).
    public let rsiz: Int

    /// Bytes per sample in Grok's raw output: 1 for ≤8-bit, else 2.
    public var bytesPerSample: Int { precision <= 8 ? 1 : 2 }

    /// Expected size, in bytes, of a planar raw decode of this codestream.
    public var planarByteCount: Int {
        width * height * componentCount * bytesPerSample
    }

    public enum ParseError: LocalizedError {
        case notJ2K
        case truncated
        public var errorDescription: String? {
            switch self {
            case .notJ2K: return "Not a JPEG2000 codestream (missing SOC/SIZ)."
            case .truncated: return "JPEG2000 SIZ header is truncated."
            }
        }
    }

    /// Parses the SIZ from the head of a codestream. Only the first ~64 bytes
    /// are read, so a peek is enough — no need for the whole frame.
    public init(codestream data: Data) throws {
        let b = [UInt8](data.prefix(64))
        guard b.count >= 42,
              b[0] == 0xFF, b[1] == 0x4F,   // SOC
              b[2] == 0xFF, b[3] == 0x51     // SIZ
        else { throw ParseError.notJ2K }

        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func u32(_ i: Int) -> Int {
            Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        }

        self.rsiz = u16(6)
        let xsiz = u32(8),  ysiz = u32(12)
        let xosiz = u32(16), yosiz = u32(20)
        let csiz = u16(40)
        guard csiz > 0, b.count >= 42 + 3 else { throw ParseError.truncated }

        self.width = xsiz - xosiz
        self.height = ysiz - yosiz
        self.componentCount = csiz
        // Ssiz of component 0: low 7 bits are (precision − 1).
        self.precision = (Int(b[42]) & 0x7F) + 1
    }

    /// Private full init for deriving a reduced-resolution variant.
    private init(width: Int, height: Int, componentCount: Int, precision: Int, rsiz: Int) {
        self.width = width; self.height = height
        self.componentCount = componentCount; self.precision = precision; self.rsiz = rsiz
    }

    /// Geometry of a Grok `-r r` reduced-resolution decode: each wavelet level
    /// halves the canvas (ceil), matching Grok's output. Used for real-time
    /// preview — decoding 2K at r=1 (→1024-wide) is ~8× faster than full res.
    public func reduced(by r: Int) -> J2KCodestreamInfo {
        guard r > 0 else { return self }
        let rw = (width + (1 << r) - 1) >> r
        let rh = (height + (1 << r) - 1) >> r
        return J2KCodestreamInfo(width: rw, height: rh,
                                 componentCount: componentCount,
                                 precision: precision, rsiz: rsiz)
    }

    /// A sensible reduce level for real-time preview: aim for ~1024px wide.
    /// 2K → 1 (1024), 4K → 2 (1024), already-small → 0.
    /// Decode-time reduction for playback. MEASURED on real DCI streams
    /// (DecodeIntegrityTests, 2026-07-30): a 2K frame costs 103.7 ms full-res
    /// vs 100.6 ms at reduce 1 — 3%. Per-frame cost is dominated by the
    /// grk_decompress process (spawn + temp file + pipe), not by the pixels, so
    /// decoding a preview-sized picture threw away half the resolution in each
    /// direction to save nothing. 2K and below therefore decode FULL RES.
    ///
    /// 4K still reduces once — 4× the pixel work is the one case where the
    /// pixel term stops being noise — which lands it at 2K, the display's
    /// resolution anyway.
    public var previewReduceLevel: Int {
        if width >= 3600 { return 1 }
        return 0
    }
}
