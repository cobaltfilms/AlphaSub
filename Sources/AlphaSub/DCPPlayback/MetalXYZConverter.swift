import Foundation
import Metal
import CoreVideo

// MARK: - GPU X'Y'Z' → Rec.709 conversion (open-core)
//
// The colour conversion is embarrassingly parallel, so it belongs on the GPU:
// this Metal compute kernel reads Grok's planar 16-bit X'Y'Z' straight into an
// IOSurface-backed CVPixelBuffer (BGRA8) that AVSampleBufferDisplayLayer samples
// with no CPU copy. Frees the CPU cores for decoding. Falls back to the CPU
// `XYZColorConverter` when Metal is unavailable (returns nil).
//
// Same maths as the CPU path (calibrated to the SilenceOfWaves DSM): DCDM
// gamma-2.6 decode with 52.37/48 scaling → XYZ(D65)→Rec.709 matrix → gamma-2.4
// encode.

final class MetalXYZConverter: @unchecked Sendable {

    /// nil when the machine has no usable Metal device.
    static let shared = MetalXYZConverter()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0

    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void xyz_to_rec709(device const ushort*           planar [[buffer(0)]],
                              constant uint2&                 dims   [[buffer(1)]],
                              texture2d<half, access::write>  out    [[texture(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        uint w = dims.x, h = dims.y;
        if (gid.x >= w || gid.y >= h) return;
        uint plane = w * h;
        uint i = gid.y * w + gid.x;
        const float s = 52.37 / 48.0;
        float X = s * pow(float(planar[i])           / 4095.0, 2.6);
        float Y = s * pow(float(planar[plane + i])   / 4095.0, 2.6);
        float Z = s * pow(float(planar[2*plane + i]) / 4095.0, 2.6);
        float r =  3.2406*X - 1.5372*Y - 0.4986*Z;
        float g = -0.9689*X + 1.8758*Y + 0.0415*Z;
        float b =  0.0557*X - 0.2040*Y + 1.0570*Z;
        r = clamp(r, 0.0, 1.0); g = clamp(g, 0.0, 1.0); b = clamp(b, 0.0, 1.0);
        half4 rgba = half4(half(pow(r, 1.0/2.4)), half(pow(g, 1.0/2.4)), half(pow(b, 1.0/2.4)), 1.0h);
        out.write(rgba, gid);
    }
    """

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.kernelSource, options: nil)
            guard let fn = library.makeFunction(name: "xyz_to_rec709") else { return nil }
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
    /// Returns nil on any failure so the caller can fall back to the CPU path.
    func pixelBuffer(from frame: GrokDecoder.DecodedFrame) -> CVPixelBuffer? {
        let info = frame.info
        guard info.componentCount == 3, info.precision <= 16 else { return nil }
        let w = info.width, h = info.height

        lock.lock()
        defer { lock.unlock() }

        guard let pixelBuffer = makePixelBuffer(width: w, height: h),
              let outTexture = makeTexture(from: pixelBuffer, width: w, height: h) else { return nil }

        // Upload the planar samples (shared storage — zero-copy on Apple GPUs).
        let inBuffer: MTLBuffer? = frame.planarData.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
        guard let inBuffer,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }

        var dims = SIMD2<UInt32>(UInt32(w), UInt32(h))
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(inBuffer, offset: 0, index: 0)
        enc.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
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
        return pixelBuffer
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

    private func makeTexture(from pb: CVPixelBuffer, width: Int, height: Int) -> MTLTexture? {
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil,
            .bgra8Unorm, width, height, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex,
              let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return tex
    }
}
