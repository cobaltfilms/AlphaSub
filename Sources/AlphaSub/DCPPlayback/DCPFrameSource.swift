import Foundation
import CoreVideo

// MARK: - Multi-reel global↔local frame mapping (pure, testable)
//
// Maps a global frame index (across all reels concatenated) to the segment
// that owns it and the local frame index within that segment. Kept pure so
// the mapping logic is unit-testable without a real MXF.

public struct ReelSegmentMap: Sendable {
    /// A located frame: which segment it lives in and the local index within
    /// that segment.
    public struct Location: Sendable, Equatable {
        public let segment: Int
        public let local: Int
        public init(segment: Int, local: Int) {
            self.segment = segment
            self.local = local
        }
    }

    /// Cumulative start offset (global frame index) of each segment.
    public let offsets: [Int]
    /// Frame count of each segment.
    public let counts: [Int]
    /// Total frames across all segments.
    public let total: Int

    public init(counts: [Int]) {
        self.counts = counts
        var off: [Int] = []
        var acc = 0
        for c in counts {
            off.append(acc)
            acc += c
        }
        self.offsets = off
        self.total = acc
    }

    /// Returns the segment + local frame for a global frame index, or nil if
    /// the global index is out of range.
    public func locate(_ globalIndex: Int) -> Location? {
        guard globalIndex >= 0, globalIndex < total else { return nil }
        for i in offsets.indices where globalIndex >= offsets[i]
            && globalIndex < offsets[i] + counts[i] {
            return Location(segment: i, local: globalIndex - offsets[i])
        }
        return nil
    }
}

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

    /// One reel's picture track inside a multi-reel composition. The reader
    /// owns its own FileHandle (one per MXF); segments are concatenated in
    /// global-frame-index order to form the full composition timeline.
    struct Segment {
        let reader: MXFPictureReader
        let localFrameCount: Int
        /// First global frame index covered by this segment.
        let globalOffset: Int
    }

    public let frameCount: Int
    /// Reduced-resolution decode level actually used (0 = full res).
    public let reduceLevel: Int

    private var segments: [Segment] = []
    private var map: ReelSegmentMap = ReelSegmentMap(counts: [])
    private let decoder: GrokDecoder
    private let converter = XYZColorConverter()
    private let capacity: Int

    private var cache: [Int: DisplayFrame] = [:]
    private var lru: [Int] = []
    private var inFlight: [Int: Task<DisplayFrame, Error>] = [:]
    private let gate: DecodeGate

    /// Single-reel convenience (preserved for backward compatibility).
    public init(pictureURL: URL,
                pictureKey: Data? = nil,
                decoder: GrokDecoder = GrokDecoder(),
                reduceLevel: Int? = nil,
                cacheCapacity: Int = 64,
                maxConcurrentDecodes: Int = DCPFrameSource.defaultConcurrency) throws {
        let reader = try MXFPictureReader(url: pictureURL, pictureKey: pictureKey)
        try self.init(segments: [(reader, pictureKey)], decoder: decoder,
                      reduceLevel: reduceLevel, cacheCapacity: cacheCapacity,
                      maxConcurrentDecodes: maxConcurrentDecodes)
    }

    /// Multi-reel init: one (reader, key) pair per reel that has a picture
    /// asset. Reels without a picture are skipped (a composition may carry a
    /// sound-only reel). The reduce level is picked from the first segment's
    /// first frame so all reels decode at the same preview resolution.
    public init(segments: [(reader: MXFPictureReader, pictureKey: Data?)],
                decoder: GrokDecoder = GrokDecoder(),
                reduceLevel: Int? = nil,
                cacheCapacity: Int = 64,
                maxConcurrentDecodes: Int = DCPFrameSource.defaultConcurrency) throws {
        guard !segments.isEmpty else {
            throw MXFPictureReader.ReaderError.noPictureFrames
        }
        self.decoder = decoder
        self.capacity = max(4, cacheCapacity)
        self.gate = DecodeGate(limit: max(1, maxConcurrentDecodes))

        var built: [Segment] = []
        var globalOffset = 0
        for (reader, _) in segments {
            let count = try reader.frameCount()
            guard count > 0 else { continue }
            built.append(Segment(reader: reader,
                                 localFrameCount: count,
                                 globalOffset: globalOffset))
            globalOffset += count
        }
        guard !built.isEmpty else {
            throw MXFPictureReader.ReaderError.noPictureFrames
        }
        self.segments = built
        self.map = ReelSegmentMap(counts: built.map(\.localFrameCount))
        self.frameCount = map.total

        // Pick a preview reduce level from the first segment's first frame
        // unless the caller pinned one (e.g. full res for a still export).
        if let reduceLevel {
            self.reduceLevel = max(0, reduceLevel)
        } else if let first = built.first,
                  let cs = try? first.reader.codestream(at: 0),
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

    /// Maps a global frame index to its segment and reads the codestream from
    /// that segment's reader. The actor isolation serialises FileHandle
    /// access per reader (each reader has its own handle).
    private func readCodestream(at globalIndex: Int) throws -> Data {
        guard let loc = map.locate(globalIndex) else {
            throw MXFPictureReader.ReaderError.frameOutOfRange(globalIndex)
        }
        return try segments[loc.segment].reader.codestream(at: loc.local)
    }

    /// Locates the segment owning a global frame index. Linear scan is fine —
    /// DCPs have at most a handful of reels.
    private func segment(for globalIndex: Int) -> Segment? {
        guard let loc = map.locate(globalIndex) else { return nil }
        return segments[loc.segment]
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
