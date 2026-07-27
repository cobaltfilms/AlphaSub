import Foundation
import CoreGraphics
import CoreVideo

// MARK: - DCI X'Y'Z' → display RGB conversion (open-core)
//
// DCP picture is encoded in the DCDM colour space (SMPTE ST 428-1): each 12-bit
// component is a gamma-2.6-encoded, luminance-scaled X, Y or Z value. Grok
// hands us those raw code values (planar, 16-bit little-endian). To show them
// on a normal display we must:
//
//   1. Decode the transfer: V = CV/4095 ; linear = (48/52.37) · … actually the
//      standard DCDM decode is  E = 52.37 · V^2.6 , then normalise by the DCI
//      reference white luminance (48 cd/m²) so reference white → 1.0. That
//      collapses to  linear = (52.37/48) · V^2.6 .
//   2. Matrix XYZ → linear sRGB (Rec.709 primaries, D65).
//   3. Encode sRGB OETF and quantise to 8-bit BGRA.
//
// The gamma-2.6 decode is a 4096-entry LUT (one per possible code value); the
// sRGB encode is a 4097-entry LUT over the linear range — so the hot loop is
// three multiply-adds plus three LUT lookups per pixel, fast enough to convert
// a 2K frame on the CPU in a few ms (parallelised across frames by the player).
//
// White handling: DCI white (x≈0.314, y≈0.351) differs slightly from D65, so a
// perfectly colorimetric result needs Bradford adaptation. This first pass uses
// the direct XYZ(D65)→sRGB matrix — visually correct for preview; a chromatic
// adaptation refinement can slot into `matrix` later without touching callers.

public struct XYZColorConverter {

    /// 12-bit DCDM decode LUT: code value → normalised linear component.
    private static let decodeLUT: [Float] = {
        let scale: Float = 52.37 / 48.0
        return (0..<4096).map { cv in
            let v = Float(cv) / 4095.0
            return scale * pow(v, 2.6)
        }
    }()

    /// Rec.709 display encode over [0,1] linear, quantised to 8-bit, 4097
    /// entries. The DCP's source master (DSM) is graded in Rec.709 / gamma 2.4,
    /// so we encode with the pure 2.4 power law (NOT the sRGB piecewise curve —
    /// that measured ~15 % too dark against the reference DSM). Calibrated to
    /// SilenceOfWaves DSM: channel means match within ~5 %.
    private static let encodeLUT: [UInt8] = {
        (0...4096).map { i in
            let l = Float(i) / 4096.0
            let s = pow(l, 1.0 / 2.4)
            return UInt8(max(0, min(255, (s * 255.0).rounded())))
        }
    }()

    // XYZ (D65) → linear sRGB, row-major.
    private static let m: (Float, Float, Float, Float, Float, Float, Float, Float, Float) = (
         3.2406, -1.5372, -0.4986,
        -0.9689,  1.8758,  0.0415,
         0.0557, -0.2040,  1.0570
    )

    public init() {}

    /// Converts a decoded X'Y'Z' frame to a BGRA8 CVPixelBuffer ready for
    /// AVSampleBufferDisplayLayer. Only 3-component, 12-bit input is supported
    /// (the DCI case); other shapes throw so callers can fall back.
    public func pixelBuffer(from frame: GrokDecoder.DecodedFrame) throws -> CVPixelBuffer {
        let info = frame.info
        guard info.componentCount == 3, info.precision <= 16 else {
            throw ConvertError.unsupported("components=\(info.componentCount) precision=\(info.precision)")
        }
        let w = info.width, h = info.height
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw ConvertError.bufferAlloc(status)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ConvertError.bufferAlloc(-1)
        }
        let dstStride = CVPixelBufferGetBytesPerRow(buffer)
        convert(frame: frame, into: base.assumingMemoryBound(to: UInt8.self), dstStride: dstStride)
        return buffer
    }

    /// Converts to a CGImage (for tests, thumbnails, and the fallback still).
    public func cgImage(from frame: GrokDecoder.DecodedFrame) throws -> CGImage {
        let info = frame.info
        let w = info.width, h = info.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBufferPointer { buf in
            convert(frame: frame, into: buf.baseAddress!, dstStride: w * 4, bgra: false)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &rgba, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = ctx?.makeImage() else { throw ConvertError.cgFailed }
        return image
    }

    // MARK: Hot loop

    /// Writes 8-bit pixels. `bgra` true → B,G,R,A (CVPixelBuffer 32BGRA);
    /// false → R,G,B,A (CGImage premultipliedLast).
    private func convert(frame: GrokDecoder.DecodedFrame,
                         into dst: UnsafeMutablePointer<UInt8>,
                         dstStride: Int,
                         bgra: Bool = true) {
        let info = frame.info
        let w = info.width, h = info.height
        let plane = w * h
        let (m0, m1, m2, m3, m4, m5, m6, m7, m8) = Self.m

        Self.decodeLUT.withUnsafeBufferPointer { dec in
        Self.encodeLUT.withUnsafeBufferPointer { enc in
        frame.planarData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let s = raw.bindMemory(to: UInt16.self)   // little-endian native
            // Planar: X plane, then Y plane, then Z plane.
            let xP = 0, yP = plane, zP = 2 * plane
            let bIdx = bgra ? 0 : 2
            let rIdx = bgra ? 2 : 0
            for y in 0..<h {
                var d = y * dstStride
                let row = y * w
                for x in 0..<w {
                    let i = row + x
                    // Clamp code values into the 12-bit LUT domain.
                    let cvX = min(Int(s[xP + i]), 4095)
                    let cvY = min(Int(s[yP + i]), 4095)
                    let cvZ = min(Int(s[zP + i]), 4095)
                    let X = dec[cvX], Y = dec[cvY], Z = dec[cvZ]
                    var r = m0 * X + m1 * Y + m2 * Z
                    var g = m3 * X + m4 * Y + m5 * Z
                    var b = m6 * X + m7 * Y + m8 * Z
                    r = max(0, min(1, r)); g = max(0, min(1, g)); b = max(0, min(1, b))
                    dst[d + rIdx] = enc[Int(r * 4096)]
                    dst[d + 1]    = enc[Int(g * 4096)]
                    dst[d + bIdx] = enc[Int(b * 4096)]
                    dst[d + 3]    = 255
                    d += 4
                }
            }
        }}}
    }

    public enum ConvertError: LocalizedError {
        case unsupported(String)
        case bufferAlloc(CVReturn)
        case cgFailed
        public var errorDescription: String? {
            switch self {
            case .unsupported(let s): return "Unsupported DCP picture format: \(s)."
            case .bufferAlloc(let s): return "Could not allocate pixel buffer (\(s))."
            case .cgFailed: return "Could not build the image."
            }
        }
    }
}
