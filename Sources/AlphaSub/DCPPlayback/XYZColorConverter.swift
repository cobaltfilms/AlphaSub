import Foundation
import CoreGraphics
import CoreVideo
import AlphaSubColor

// MARK: - DCI X'Y'Z' → display RGB conversion (open-core)
//
// DCP picture is encoded in the DCDM colour space (SMPTE ST 428-1): each 12-bit
// component is a gamma-2.6-encoded, luminance-scaled X, Y or Z value. Grok
// hands us those raw code values (planar, 16-bit little-endian); this type
// turns a decoded frame into something a display can show.
//
// The colour science itself lives in AlphaSubColor — primaries, transfer
// functions, Bradford adaptation and the matrices derived from them — because
// AlphaDCP needs the same maths running backwards to author a DCP. What
// remains here is the frame plumbing: allocate the buffer, run the pipeline
// over it, tag the result so ColorSync does not transform it a second time.
//
// White handling: DCI white (x 0.314, y 0.351) is not D65, so every target
// except DCI P3 needs chromatic adaptation. The previous implementation had
// none — it fed DCI-white XYZ to the D65 matrix, which renders reference white
// as RGB (0.886, 1.049, 0.855): a green bias of about 5 %. Bradford is now the
// default and maps it to a true neutral. `.none` reproduces the old look for
// side-by-side comparison against a reference master.

public struct XYZColorConverter {

    /// The display space frames are converted into.
    public let target: ColorSpace

    /// White-point adaptation between DCI white and the target's white.
    public let adaptation: ChromaticAdaptation

    private let pipeline: ColorPipeline

    /// Defaults reproduce the shipped playback path's target — Rec.709
    /// primaries with a pure gamma 2.4 (BT.1886) encode, which measured
    /// correct against the reference DSM where the sRGB piecewise curve came
    /// out about 15 % too dark — but with chromatic adaptation now applied.
    public init(target: ColorSpace = .rec709,
                adaptation: ChromaticAdaptation = .bradford,
                range: ColorRange = .full) {
        self.target = target
        self.adaptation = adaptation
        self.pipeline = ColorPipeline(from: .dcdmXYZ, to: target,
                                      adaptation: adaptation,
                                      sourceBitDepth: DCDM.bitDepth,
                                      targetRange: range)
    }

    /// The transform this converter runs, for callers that need to mirror it
    /// (the Metal path) or describe it (export tagging).
    public var transform: ColorTransform { pipeline.transform }

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
        frame.planarData.withUnsafeBytes { raw in
            pipeline.convertPlanar(source: raw, width: w, height: h,
                                   into: base.assumingMemoryBound(to: UInt8.self),
                                   destinationStride: dstStride,
                                   order: .bgra)
        }
        target.tag(buffer)
        return buffer
    }

    /// Converts to a CGImage (for tests, thumbnails, and the fallback still).
    public func cgImage(from frame: GrokDecoder.DecodedFrame) throws -> CGImage {
        let info = frame.info
        let w = info.width, h = info.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        frame.planarData.withUnsafeBytes { raw in
            rgba.withUnsafeMutableBufferPointer { buf in
                pipeline.convertPlanar(source: raw, width: w, height: h,
                                       into: buf.baseAddress!, destinationStride: w * 4,
                                       order: .rgba)
            }
        }
        let cs = target.cgColorSpace ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &rgba, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = ctx?.makeImage() else { throw ConvertError.cgFailed }
        return image
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
