import Foundation
import CoreVideo

// MARK: - Decode-ahead DCP frame source (open-core)
//
// Bridges the single-threaded, single-FileHandle MXFPictureReader to the
// many-frames-at-once appetite of real-time playback. The whole per-frame
// pipeline — read → Grok decode → X'Y'Z'→Rec709 conversion — runs OFF the main
// thread here, and the cache holds display-ready CVPixelBuffers, so the player
// only has to wrap + enqueue on the main actor.
//
// Throughput (see grok-dcp-playback memory): Grok decode must be single-thread
// (-H 1) to avoid the 20.3.7 segfault, so parallelism comes from decoding
// several FRAMES at once. Full-res 2K decode is ~80 ms/frame; a reduced-
// resolution preview (-r 1 → 1024-wide) is ~10 ms and a quarter the pixels to
// convert — the difference between "far from real time" and smooth.
//
// Concurrency model:
//   • Codestream extraction (seek + read) touches the shared FileHandle, so it
//     is actor-isolated here — cheap and serial.
//   • Decode + convert (the expensive part) run off-actor in detached tasks,
//     capped by a semaphore at ~perf-core count and marked userInitiated so
//     the Grok subprocess runs on the performance cores.

public actor DCPFrameSource {

    /// A display-ready frame: a BGRA8 pixel buffer at the (reduced) preview
    /// resolution. CVPixelBuffer is a thread-safe CF type.
    public struct DisplayFrame: @unchecked Sendable {
        public let pixelBuffer: CVPixelBuffer
        public let width: Int
        public let height: Int
    }

    public let frameCount: Int
    /// Reduced-resolution decode level actually used (0 = full res).
    public let reduceLevel: Int

    private let reader: MXFPictureReader
    private let decoder: GrokDecoder
    private let converter = XYZColorConverter()
    private let capacity: Int

    private var cache: [Int: DisplayFrame] = [:]
    private var lru: [Int] = []
    private var inFlight: [Int: Task<DisplayFrame, Error>] = [:]
    private let gate: DecodeGate

    public init(pictureURL: URL,
                pictureKey: Data? = nil,
                decoder: GrokDecoder = GrokDecoder(),
                reduceLevel: Int? = nil,
                cacheCapacity: Int = 64,
                maxConcurrentDecodes: Int = DCPFrameSource.defaultConcurrency) throws {
        self.reader = try MXFPictureReader(url: pictureURL, pictureKey: pictureKey)
        self.frameCount = try reader.frameCount()
        self.decoder = decoder
        self.capacity = max(4, cacheCapacity)
        self.gate = DecodeGate(limit: max(1, maxConcurrentDecodes))
        // Pick a preview reduce level from the first frame's geometry unless the
        // caller pinned one (e.g. full res for a still export).
        if let reduceLevel {
            self.reduceLevel = max(0, reduceLevel)
        } else if frameCount > 0,
                  let cs = try? reader.codestream(at: 0),
                  let info = try? J2KCodestreamInfo(codestream: cs) {
            self.reduceLevel = info.previewReduceLevel
        } else {
            self.reduceLevel = 1
        }
    }

    public static var defaultConcurrency: Int {
        // Keep decode gentle: ~250 fps of headroom means a handful of workers
        // sustains 24 fps with a buffer, while leaving CPU/cores for the main
        // thread (UI + timecode). Saturating all cores starves the UI.
        let perf = ProcessInfo.processInfo.activeProcessorCount
        return max(2, min(4, perf / 3))
    }

    public var isAvailable: Bool { decoder.isAvailable }

    public func frame(at index: Int) async throws -> DisplayFrame {
        if let hit = cache[index] {
            touch(index)
            return hit
        }
        return try await decodeTask(for: index).value
    }

    public func prefetch(around index: Int, ahead: Int = 24, behind: Int = 2) {
        let lo = max(0, index - max(0, behind))
        let hi = min(frameCount - 1, index + max(0, ahead))
        guard lo <= hi else { return }
        for i in lo...hi where cache[i] == nil && inFlight[i] == nil {
            _ = decodeTask(for: i)
        }
    }

    public func flush() {
        for (_, task) in inFlight { task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        lru.removeAll()
    }

    // MARK: Internals

    private func decodeTask(for index: Int) -> Task<DisplayFrame, Error> {
        if let existing = inFlight[index] { return existing }
        let decoder = self.decoder            // Sendable struct
        let converter = self.converter        // Sendable struct
        let gate = self.gate                  // actor
        let reduce = self.reduceLevel
        let task = Task<DisplayFrame, Error>.detached(priority: .utility) { [weak self] in
            guard let self else { throw CancellationError() }
            let codestream = try await self.readCodestream(at: index)
            try Task.checkCancellation()
            await gate.acquire()
            defer { Task { await gate.release() } }
            try Task.checkCancellation()
            let decoded = try decoder.decodeToPlanar(codestream, reduce: reduce)
            // Favour the GPU for the colour conversion; fall back to CPU.
            let pb: CVPixelBuffer
            if let gpu = MetalXYZConverter.shared, let g = gpu.pixelBuffer(from: decoded) {
                pb = g
            } else {
                pb = try converter.pixelBuffer(from: decoded)
            }
            return DisplayFrame(pixelBuffer: pb,
                                width: decoded.info.width, height: decoded.info.height)
        }
        inFlight[index] = task
        Task { [weak self] in
            let result = await task.result
            await self?.store(index: index, result: result)
        }
        return task
    }

    private func readCodestream(at index: Int) throws -> Data {
        try reader.codestream(at: index)
    }

    private func store(index: Int, result: Result<DisplayFrame, Error>) {
        inFlight[index] = nil
        guard case .success(let frame) = result else { return }
        cache[index] = frame
        touch(index)
        evictIfNeeded()
    }

    private func touch(_ index: Int) {
        if let pos = lru.firstIndex(of: index) { lru.remove(at: pos) }
        lru.append(index)
    }

    private func evictIfNeeded() {
        while cache.count > capacity, let oldest = lru.first {
            lru.removeFirst()
            cache[oldest] = nil
        }
    }
}

/// Simple async counting semaphore to cap concurrent decodes.
actor DecodeGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }

    func release() {
        active -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }
}
