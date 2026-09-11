import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - Off-main DCP picture display loop (open-core)
//
// The picture pipeline must NEVER run on the main thread: at 24 fps it would
// compete with SwiftUI's own 60 Hz work (timeline playhead, subtitle overlay,
// waveform) and lose — the symptom being "decode is busy but the picture
// crawls". So the tick, frame fetch and AVSampleBufferDisplayLayer enqueue all
// happen on a dedicated userInitiated queue. The clock is a thread-safe closure
// (e.g. the live AVPlayer time), read off-main. AVSampleBufferDisplayLayer.
// enqueue is thread-safe, so nothing here touches the main thread.

/// Running totals of what the display loop did with each frame.
///
/// Written on the display queue, read from the main actor a couple of times a
/// second by the statistics panel — hence a lock rather than bare `Int`s. The
/// lock is uncontended and held for one increment, which is the cheapest thing
/// that is also correct; nothing here allocates, so it is safe on the display
/// queue at frame rate.
public final class DCPFrameCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var presentedCount = 0
    private var droppedCount = 0

    public init() {}

    func recordPresented() {
        lock.lock(); presentedCount += 1; lock.unlock()
    }

    /// A frame that was decoded but never shown: the playhead had already moved
    /// past it, or the decode failed outright. Only counted while playing —
    /// during a scrub, superseded frames are the mechanism working, not a fault.
    func recordDropped() {
        lock.lock(); droppedCount += 1; lock.unlock()
    }

    /// `(shown, thrown away)` since this player was created.
    public var totals: (presented: Int, dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (presentedCount, droppedCount)
    }
}

final class DCPDisplayLoop: @unchecked Sendable {

    /// Shared with the owning DCPPlayer so the host can sample it.
    let counters = DCPFrameCounters()

    /// Output layers — main video area, fullscreen, detached window — all fed
    /// the same frames. Mutated only on `queue`.
    private var layers: [AVSampleBufferDisplayLayer] = []
    /// Per-frame observers (DeckLink SDI output, video scopes) receiving the
    /// shown pixel buffer, keyed so they do not evict each other. Called on
    /// `queue`, and — like `layers` — mutated only on `queue`:
    /// `setFrameObserver` hops, so nothing else may touch this directly.
    ///
    /// It used to be a single slot, which meant turning on the scopes silently
    /// turned off SDI output and vice versa: whichever attached last won, and
    /// the other simply went quiet with nothing to say why.
    private var observers: [String: @Sendable (CVPixelBuffer) -> Void] = [:]

    private let source: DCPFrameSource
    private let clock: DCPPlaybackClock
    private let hz: Double
    /// Thread-safe: returns the current master time (seconds) and whether it is
    /// advancing. Called on the display queue.
    private let clockSource: @Sendable () -> (time: Double, isPlaying: Bool)

    private let queue = DispatchQueue(label: "com.alphasub.dcp.display", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    /// Which frame the loop has claimed, and the bounded retry for one whose
    /// fetch came back empty. The rule is pure and lives in
    /// `DCPFramePresentation` so it can be tested without a decoder.
    private var presentation = DCPFramePresentation()
    private var lastPrefetchFrame = -1
    private let formatCache = FrameFormatCache()

    /// Notified on `queue` with the presentation time of each frame actually
    /// put on screen, so the subtitle overlay can be driven by the picture the
    /// operator is looking at rather than by the transport clock. Mutated only
    /// on `queue`, for the same reason `observers` is.
    private var presentationObserver: (@Sendable (Double) -> Void)?

    init(source: DCPFrameSource,
         clock: DCPPlaybackClock,
         hz: Double,
         clockSource: @escaping @Sendable () -> (time: Double, isPlaying: Bool)) {
        self.source = source
        self.clock = clock
        self.hz = max(30, hz)
        self.clockSource = clockSource
    }

    func addLayer(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self] in
            guard let self, !self.layers.contains(where: { $0 === layer }) else { return }
            self.layers.append(layer)
            self.presentation.invalidate()   // force a fresh frame into the new layer
        }
    }

    func removeLayer(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self] in
            self?.layers.removeAll { $0 === layer }
        }
    }

    /// Install (or clear) the per-frame hook.
    ///
    /// Hops to `queue` for the same reason `addLayer` does. The hook is
    /// assigned from the main actor — every playback start re-attaches it, and
    /// starting or stopping SDI output sets and clears it — while the display
    /// loop reads it on `queue` at frame rate. Writing the closure reference
    /// straight across those two threads is a data race, and the way it shows
    /// up is the card going quiet: the loop keeps calling a hook that the
    /// other thread has already replaced, or reads a half-published one.
    func setFrameObserver(_ hook: (@Sendable (CVPixelBuffer) -> Void)?, for key: String) {
        queue.async { [weak self] in
            self?.observers[key] = hook
        }
    }

    /// Install (or clear) the presentation hook. Hops to `queue` like every
    /// other cross-thread mutation here.
    func setPresentationObserver(_ hook: (@Sendable (Double) -> Void)?) {
        queue.async { [weak self] in
            self?.presentationObserver = hook
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0 / self.hz, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// Force the frame for the current time to be shown now (e.g. right after
    /// attaching, so a paused DCP isn't blank).
    func showCurrentFrame() {
        queue.async { [weak self] in self?.render(force: true) }
    }

    // MARK: Loop body (runs on `queue`)

    private func tick() { render(force: false) }

    private func render(force: Bool) {
        let (t, playing) = clockSource()
        let frame = clock.frameIndex(at: min(max(0, t), clock.duration))

        // Keep a modest buffer ahead of the playhead — enough to smooth a slow
        // decode, but not so deep that filling it bursts CPU and starves the UI.
        // Only re-arm when the playhead actually moved: scanning the window is
        // actor traffic that competes with the visible-frame fetch at 60 Hz.
        //
        // A jump beyond the normal advance/prefetch window is a seek (scrub,
        // cue jump, JKL shuttle): the source also drops decodes for the old
        // position, otherwise the newly visible frame queues behind them and
        // the picture "hangs" on the pre-seek frame. Cancel and arm go in ONE
        // call — as two unordered Tasks the cancel can land after the arm and
        // kill the window it just queued.
        if frame != lastPrefetchFrame {
            let last = presentation.current
            let jumped = last >= 0 && (frame < last - 4 || frame > last + 16)
            lastPrefetchFrame = frame
            let ahead = playing ? 16 : 6
            let behind = playing ? 2 : 6
            Task {
                await source.reposition(to: frame, ahead: ahead, behind: behind,
                                        cancelStale: jumped)
            }
        }

        guard presentation.shouldFetch(frame, force: force) else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let f = try? await self.source.frame(at: frame) else {
                self.queue.async {
                    if playing { self.counters.recordDropped() }
                    // Nothing reached the screen, so the picture still shows
                    // the PREVIOUS frame. Reopen this one for another attempt
                    // unless the playhead has already moved on (a newer target
                    // owns the marker now) or this frame has failed too often.
                    _ = self.presentation.noteFailure(of: frame)
                }
                return
            }
            // The fetch is async; by the time it returns the playhead may have
            // moved on. Only present it if it's still the current frame — this
            // prevents an out-of-order stale frame flashing (a perceived drop).
            self.queue.async {
                guard self.presentation.isCurrent(frame) else {
                    // Decoded too late to be of use. While playing that is a
                    // genuine dropped frame; while scrubbing it is the loop
                    // discarding work the operator has already moved past, and
                    // counting it would bury the signal in noise.
                    if playing { self.counters.recordDropped() }
                    return
                }
                self.enqueue(f.pixelBuffer)
                self.counters.recordPresented()
                self.presentation.notePresented(frame)
                // Announce the picture AFTER it has been handed to the layers,
                // so a consumer that redraws in response (the subtitle
                // overlay) is never ahead of the frame it belongs to.
                self.presentationObserver?(self.clock.time(ofFrame: frame))
            }
        }
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        if !layers.isEmpty, let format = formatCache.format(for: pixelBuffer) {
            var timing = CMSampleTimingInfo(duration: .invalid,
                                            presentationTimeStamp: .invalid,
                                            decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            let status = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
            if status == noErr, let sample {
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
                   CFArrayGetCount(attachments) > 0 {
                    let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                    CFDictionarySetValue(dict,
                        unsafeBitCast(kCMSampleAttachmentKey_DisplayImmediately, to: UnsafeRawPointer.self),
                        unsafeBitCast(kCFBooleanTrue, to: UnsafeRawPointer.self))
                }
                for layer in layers {
                    if layer.status == .failed { layer.flush() }
                    layer.enqueue(sample)
                }
            }
        }
        // Observers run AFTER the on-screen enqueue: a slow DeckLink feed or a
        // scope raster must never delay the picture the operator is looking at.
        for observer in observers.values { observer(pixelBuffer) }
    }
}

/// Caches the CMVideoFormatDescription for a pixel-buffer geometry so we don't
/// rebuild it every frame (all frames of a reel share one format).
final class FrameFormatCache {
    private var format: CMVideoFormatDescription?
    private var w = 0, h = 0
    func format(for pb: CVPixelBuffer) -> CMVideoFormatDescription? {
        let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb)
        if let format, pw == w, ph == h { return format }
        var fmt: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard status == noErr else { return nil }
        format = fmt; w = pw; h = ph
        return fmt
    }
}
