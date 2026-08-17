import Foundation
import CoreVideo
import AlphaSubColor

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
// Throughput (see grok-dcp-playback memory): Grok decode now runs
// multithreaded (-H 4 ≈ 17 ms for a 2K frame at preview reduce; a crash-by-
// signal retries once at -H 1, the historically safe mode), and parallelism
// also comes from decoding several FRAMES at once. Full-res 2K decode is
// ~25 ms/frame multithreaded; a reduced-resolution preview (-r 1 → 1024-wide)
// is a quarter the pixels to convert — the difference between "far from real
// time" and smooth.
//
// Concurrency model:
//   • Codestream extraction (seek + read) touches the shared FileHandle, so it
//     is actor-isolated here — cheap and serial.
//   • Decode + convert (the expensive part) run off-actor in detached tasks,
//     capped by a cancellation-aware semaphore at ~perf-core count and marked
//     userInitiated so the Grok subprocess runs on the performance cores.

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
    private let converter: XYZColorConverter
    /// Display space frames are converted into, and the GPU form of that same
    /// transform so the Metal path cannot drift from the CPU one.
    public let colorTarget: ColorSpace
    private let kernelParameters: ColorKernelParameters?
    private let capacity: Int

    private var cache: [Int: DisplayFrame] = [:]
    private var lru: [Int] = []
    /// In-flight decodes keyed by frame index; the UUID guards `store` against
    /// a stale completion clearing a newer replacement task after a seek.
    private var inFlight: [Int: (id: UUID, task: Task<DisplayFrame, Error>)] = [:]
    private let gate: DecodeGate

    /// Single-reel convenience (preserved for backward compatibility).
    public init(pictureURL: URL,
                pictureKey: Data? = nil,
                decoder: GrokDecoder = GrokDecoder(),
                reduceLevel: Int? = nil,
                cacheCapacity: Int = 64,
                maxConcurrentDecodes: Int = DCPFrameSource.defaultConcurrency,
                colorTarget: ColorSpace = .rec709,
                colorAdaptation: ChromaticAdaptation = .bradford) throws {
        let reader = try MXFPictureReader(url: pictureURL, pictureKey: pictureKey)
        try self.init(segments: [(reader, pictureKey)], decoder: decoder,
                      reduceLevel: reduceLevel, cacheCapacity: cacheCapacity,
                      maxConcurrentDecodes: maxConcurrentDecodes,
                      colorTarget: colorTarget, colorAdaptation: colorAdaptation)
    }

    /// Multi-reel init: one (reader, key) pair per reel that has a picture
    /// asset. Reels without a picture are skipped (a composition may carry a
    /// sound-only reel). The reduce level is picked from the first segment's
    /// first frame so all reels decode at the same preview resolution.
    public init(segments: [(reader: MXFPictureReader, pictureKey: Data?)],
                decoder: GrokDecoder = GrokDecoder(),
                reduceLevel: Int? = nil,
                cacheCapacity: Int = 64,
                maxConcurrentDecodes: Int = DCPFrameSource.defaultConcurrency,
                colorTarget: ColorSpace = .rec709,
                colorAdaptation: ChromaticAdaptation = .bradford) throws {
        guard !segments.isEmpty else {
            throw MXFPictureReader.ReaderError.noPictureFrames
        }
        let concurrency = max(1, maxConcurrentDecodes)
        self.decoder = decoder
        self.capacity = max(4, cacheCapacity)
        self.gate = DecodeGate(limit: concurrency)
        self.colorTarget = colorTarget
        self.converter = XYZColorConverter(target: colorTarget, adaptation: colorAdaptation)
        self.kernelParameters = ColorTransform(from: .dcdmXYZ, to: colorTarget,
                                               adaptation: colorAdaptation).kernelParameters()

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
        // Each decode is a single-threaded grk_decompress process costing
        // ~104 ms for a full-res 2K frame (measured), so 24 fps needs at least
        // 2.5 of them in flight; below that the picture stutters no matter how
        // fast the display loop runs. Five gives ~48 fps of headroom for
        // shuttle and seek while still leaving cores for the UI and the
        // timecode — saturating every core starves the main thread.
        let perf = ProcessInfo.processInfo.activeProcessorCount
        return max(3, min(6, perf / 2))
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

    /// A position jump (scrub, cue seek, JKL shuttle): cancel in-flight
    /// decodes outside the window around the target so the visible frame
    /// isn't queued behind stale work from the old position. Cancelled tasks
    /// unwind through `store` and simply never land in the cache; the cache
    /// itself is kept (LRU-bounded) so seeking back remains instant.
    ///
    /// Cancel-only — prefer `reposition`, which also arms the new window in
    /// the same actor hop.
    public func seek(to index: Int, behind: Int = 6, ahead: Int = 6) {
        let lo = index - max(0, behind), hi = index + max(0, ahead)
        for (i, entry) in inFlight where i < lo || i > hi {
            entry.task.cancel()
            inFlight[i] = nil
        }
    }

    /// Moves the decode window to `index`: optionally drops stale work, then
    /// arms the new window — as ONE actor call. Two separate calls race (the
    /// display loop dispatches unordered `Task`s), and a cancel landing after
    /// an arm kills the frames it just queued; the cancelled range is also the
    /// exact complement of the armed one, so nothing useful is ever dropped.
    public func reposition(to index: Int, ahead: Int = 16, behind: Int = 2,
                           cancelStale: Bool = false) {
        if cancelStale { seek(to: index, behind: behind, ahead: ahead) }
        prefetch(around: index, ahead: ahead, behind: behind)
    }

    /// Full reset — cancels everything and drops the cache (~2 MB per frame,
    /// 64 frames). Teardown only: swapping the source, closing the DCP. A
    /// position jump wants `reposition`, which keeps the cache warm.
    public func flush() {
        for (_, entry) in inFlight { entry.task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        lru.removeAll()
    }

    // MARK: Internals

    private func decodeTask(for index: Int) -> Task<DisplayFrame, Error> {
        if let existing = inFlight[index], !existing.task.isCancelled {
            return existing.task
        }
        let decoder = self.decoder            // Sendable struct
        let converter = self.converter        // Sendable struct
        let target = self.colorTarget
        let parameters = self.kernelParameters
        let gate = self.gate                  // actor
        let reduce = self.reduceLevel
        let id = UUID()
        let task = Task<DisplayFrame, Error>.detached(priority: .userInitiated) { [weak self] in
            guard let self else { throw CancellationError() }
            let codestream = try await self.readCodestream(at: index)
            try Task.checkCancellation()
            // A task cancelled while waiting on the gate resumes WITHOUT a
            // slot — bail before the matching release unbalances the count.
            // Conversely, once a slot is held the release must be installed
            // before anything that can throw: a cancellation landing between
            // the grant and the `defer` would leak the slot permanently, and
            // the gate only has 2–4 of them (picture freezes for good).
            guard await gate.acquire() else { throw CancellationError() }
            defer { Task { await gate.release() } }
            try Task.checkCancellation()
            let decoded = try decoder.decodeToPlanar(codestream, reduce: reduce)
            // Favour the GPU for the colour conversion; fall back to CPU.
            let pb: CVPixelBuffer
            if let gpu = MetalXYZConverter.shared, let parameters,
               let g = gpu.pixelBuffer(from: decoded, parameters: parameters, target: target) {
                pb = g
            } else {
                pb = try converter.pixelBuffer(from: decoded)
            }
            return DisplayFrame(pixelBuffer: pb,
                                width: decoded.info.width, height: decoded.info.height)
        }
        inFlight[index] = (id, task)
        Task { [weak self] in
            let result = await task.result
            await self?.store(index: index, id: id, result: result)
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

    private func store(index: Int, id: UUID, result: Result<DisplayFrame, Error>) {
        // Only the task still tracked for this index may clear its slot — a
        // cancelled task's late completion must not drop a replacement.
        if inFlight[index]?.id == id { inFlight[index] = nil }
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
/// Cancellation-aware: a task cancelled while waiting resumes immediately
/// WITHOUT taking a slot (the waiter resumes with `granted == false`), so
/// seek-cancellation frees the gate for the newly visible frame at once
/// instead of leaking a suspended waiter until the next release.
actor DecodeGate {
    private let limit: Int
    private var active = 0
    private var waiters: [(id: UUID, c: CheckedContinuation<Bool, Never>)] = []
    /// IDs cancelled before their continuation was registered (cancel/await
    /// race) — checked when the waiter is appended.
    private var cancelledIDs: Set<UUID> = []

    init(limit: Int) { self.limit = limit }

    /// Slots currently held. Test hook — a healthy gate returns to 0 once
    /// every decode has finished or been cancelled.
    var activeSlots: Int { active }

    /// Returns true when the caller HOLDS a slot and MUST call `release()`,
    /// false when it was cancelled and holds nothing. The caller has to see
    /// this: installing the matching `release` is only correct on the true
    /// branch, and skipping it is only correct on the false branch.
    func acquire() async -> Bool {
        // An already-cancelled task must not take a slot: its next
        // checkCancellation would throw and the slot would never come back.
        if Task.isCancelled { return false }
        if active < limit, waiters.isEmpty { active += 1; return true }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                if cancelledIDs.remove(id) != nil {
                    c.resume(returning: false)
                } else {
                    waiters.append((id, c))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        if granted { active += 1 }
        // A cancel that landed after the grant left an id behind — drop it.
        if !cancelledIDs.isEmpty { cancelledIDs.remove(id) }
        return granted
    }

    func release() {
        active -= 1
        guard !waiters.isEmpty else { return }
        let w = waiters.removeFirst()
        w.c.resume(returning: true)
    }

    private func cancelWaiter(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.id == id }) {
            let w = waiters.remove(at: i)
            w.c.resume(returning: false)
        } else {
            cancelledIDs.insert(id)
        }
    }
}
