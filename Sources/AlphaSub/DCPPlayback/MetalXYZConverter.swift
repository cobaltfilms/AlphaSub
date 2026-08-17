import Foundation
import Metal
import CoreVideo
import AlphaSubColor

// MARK: - GPU X'Y'Z' → display RGB conversion (open-core)
//
// The colour conversion is embarrassingly parallel, so it belongs on the GPU:
// this Metal compute kernel reads Grok's planar 16-bit X'Y'Z' straight into an
// IOSurface-backed CVPixelBuffer (BGRA8) that AVSampleBufferDisplayLayer samples
// with no CPU copy. Frees the CPU cores for decoding. Falls back to the CPU
// `XYZColorConverter` when Metal is unavailable (returns nil).
//
// The kernel is generic over the target space: the matrix, both transfer
// curves and the output range arrive as a `ColorKernelParameters` uniform
// derived from the very same `ColorTransform` the CPU path uses. That is what
// keeps the two paths in agreement — neither holds its own copy of the maths.

final class MetalXYZConverter: @unchecked Sendable {

    /// nil when the machine has no usable Metal device.
    static let shared = MetalXYZConverter()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    /// Guards ONLY the pixel-buffer pool and texture cache (not thread-safe).
    /// Metal devices and command queues are thread-safe, so concurrent decode
    /// tasks submit their own command buffers without convoying behind one
    /// global lock.
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var conversionsSinceFlush = 0

    /// Mirrors `ColorKernelParameters` field for field — all 4-byte scalars in
    /// declaration order, so the Swift struct copies straight across.
    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ColorParams {
        float m0, m1, m2, m3, m4, m5, m6, m7, m8;
        float sourceMaximum;
        float sourceScale;
        float sourceGamma;
        float targetGamma;
        float targetScale;
        float rangeLow;
        float rangeSpan;
        uint  transferKind;
    };

    static inline float encode_transfer(float l, constant ColorParams& p) {
        switch (p.transferKind) {
            case 1:  // sRGB piecewise
                return l <= 0.0031308f ? 12.92f * l : 1.055f * pow(l, 1.0f/2.4f) - 0.055f;
            case 2:  // BT.709 OETF
                return l < 0.018f ? 4.5f * l : 1.099f * pow(l, 0.45f) - 0.099f;
            case 3:  // linear
                return l;
            default: // pure power law
                return pow(l / p.targetScale, 1.0f / p.targetGamma);
        }
    }

    kernel void xyz_to_display(device const ushort*           planar [[buffer(0)]],
                               constant uint2&                 dims   [[buffer(1)]],
                               constant ColorParams&           p      [[buffer(2)]],
                               texture2d<half, access::write>  out    [[texture(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint w = dims.x, h = dims.y;
        if (gid.x >= w || gid.y >= h) return;
        uint plane = w * h;
        uint i = gid.y * w + gid.x;
        float X = p.sourceScale * pow(float(planar[i])           / p.sourceMaximum, p.sourceGamma);
        float Y = p.sourceScale * pow(float(planar[plane + i])   / p.sourceMaximum, p.sourceGamma);
        float Z = p.sourceScale * pow(float(planar[2*plane + i]) / p.sourceMaximum, p.sourceGamma);
        float r = p.m0*X + p.m1*Y + p.m2*Z;
        float g = p.m3*X + p.m4*Y + p.m5*Z;
        float b = p.m6*X + p.m7*Y + p.m8*Z;
        r = clamp(r, 0.0f, 1.0f); g = clamp(g, 0.0f, 1.0f); b = clamp(b, 0.0f, 1.0f);
        r = p.rangeLow + p.rangeSpan * encode_transfer(r, p);
        g = p.rangeLow + p.rangeSpan * encode_transfer(g, p);
        b = p.rangeLow + p.rangeSpan * encode_transfer(b, p);
        out.write(half4(half(r), half(g), half(b), 1.0h), gid);
    }
    """

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.kernelSource, options: nil)
            guard let fn = library.makeFunction(name: "xyz_to_display") else { return nil }
            self.pipeline = try device.makeComputePipelineState(function: fn)
        } catch { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.queue = queue
        self.textureCache = cache
    }

    /// Converts a decoded X'Y'Z' frame to a BGRA8 CVPixelBuffer on the GPU.
    /// Returns nil on any failure so the caller can fall back to the CPU path
    /// — including a transform the kernel cannot express (a piecewise source
    /// curve), which the CPU pipeline handles fine.
    func pixelBuffer(from frame: GrokDecoder.DecodedFrame,
                     target: ColorSpace = .rec709,
                     adaptation: ChromaticAdaptation = .bradford,
                     range: ColorRange = .full) -> CVPixelBuffer? {
        let transform = ColorTransform(from: .dcdmXYZ, to: target, adaptation: adaptation)
        guard let parameters = transform.kernelParameters(targetRange: range) else { return nil }
        return pixelBuffer(from: frame, parameters: parameters, target: target)
    }

    func pixelBuffer(from frame: GrokDecoder.DecodedFrame,
                     parameters: ColorKernelParameters,
                     target: ColorSpace) -> CVPixelBuffer? {
        let info = frame.info
        guard info.componentCount == 3, info.precision <= 16 else { return nil }
        return pixelBuffer(planar: frame.planarData,
                           width: info.width, height: info.height,
                           parameters: parameters, target: target)
    }

    /// The geometry-only entry point: three contiguous 16-bit planes, no
    /// codestream in sight. Exists so the GPU path can be tested against the
    /// CPU pipeline on a synthetic frame — a real DCP is not always around,
    /// and "GPU matches CPU" is the invariant that keeps the two in step.
    func pixelBuffer(planar: Data,
                     width w: Int,
                     height h: Int,
                     parameters: ColorKernelParameters,
                     target: ColorSpace) -> CVPixelBuffer? {
        guard w > 0, h > 0,
              planar.count >= 3 * w * h * MemoryLayout<UInt16>.size else { return nil }
        let frame = planar

        // Shared-state section: pool + texture cache only.
        //
        // The CVMetalTexture wrapper is carried out of here and kept alive
        // until the GPU is done (see withExtendedLifetime below). Dropping it
        // early leaves the cache free to recycle the texture's backing while
        // another thread's command buffer is still writing to it — which, now
        // that conversions run concurrently, shows up as bands of a different
        // frame smeared across the picture.
        let prepared: (CVPixelBuffer, CVMetalTexture, MTLTexture)? = {
            lock.lock()
            defer { lock.unlock() }
            guard let pb = makePixelBuffer(width: w, height: h),
                  let (cvTex, tex) = makeTexture(from: pb, width: w, height: h) else { return nil }
            return (pb, cvTex, tex)
        }()
        guard let (pixelBuffer, cvTexture, outTexture) = prepared else { return nil }

        // Upload the planar samples ZERO-COPY (shared storage on Apple GPUs).
        // Safe with bytesNoCopy because waitUntilCompleted() below keeps the
        // GPU read inside this withUnsafeBytes scope.
        //
        // bytesNoCopy REQUIRES a page-aligned pointer and a page-multiple
        // length, and Data promises neither: a multi-MB frame happens to get
        // page-aligned storage from malloc, but a small or oddly-sized one
        // (unusual reduce level, non-2K geometry) does not. Copy in that case
        // rather than hand Metal an invalid buffer — a few hundred µs beats a
        // nil buffer that silently demotes the whole conversion to the CPU.
        return withExtendedLifetime(cvTexture) {
        return frame.withUnsafeBytes { raw -> CVPixelBuffer? in
            guard let base = raw.baseAddress, raw.count > 0 else { return nil }
            let page = Int(getpagesize())
            let canAlias = Int(bitPattern: base) % page == 0 && raw.count % page == 0
            let buffer = canAlias
                ? device.makeBuffer(bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                                    length: raw.count, options: .storageModeShared,
                                    deallocator: nil)
                : device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
            guard let inBuffer = buffer,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { return nil }

            var dims = SIMD2<UInt32>(UInt32(w), UInt32(h))
            var params = parameters
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(inBuffer, offset: 0, index: 0)
            enc.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
            enc.setBytes(&params, length: MemoryLayout<ColorKernelParameters>.stride, index: 2)
            enc.setTexture(outTexture, index: 0)
            let tw = pipeline.threadExecutionWidth
            let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
            let tgSize = MTLSize(width: tw, height: th, depth: 1)
            let tgCount = MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1)
            enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            guard cmd.status == .completed else { return nil }
            target.tag(pixelBuffer)
            return pixelBuffer
        }
        }
    }

    // MARK: Buffers

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolW != width || poolH != height {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool) == kCVReturnSuccess else {
                return nil
            }
            pool = newPool; poolW = width; poolH = height
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess else {
            return nil
        }
        return pb
    }

    /// Returns the CVMetalTexture WITH its MTLTexture — the caller must keep
    /// the wrapper alive for as long as the GPU uses the texture. Returning
    /// the MTLTexture alone lets the wrapper deallocate immediately, and the
    /// texture cache is then free to recycle backing store out from under an
    /// in-flight command buffer.
    private func makeTexture(from pb: CVPixelBuffer, width: Int,
                             height: Int) -> (CVMetalTexture, MTLTexture)? {
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil,
            .bgra8Unorm, width, height, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex,
              let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (cvTex, tex)
    }
}
