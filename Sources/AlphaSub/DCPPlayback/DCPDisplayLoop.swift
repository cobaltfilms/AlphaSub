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

final class DCPDisplayLoop: @unchecked Sendable {

    /// Output layers — main video area, fullscreen, detached window — all fed
    /// the same frames. Mutated only on `queue`.
    private var layers: [AVSampleBufferDisplayLayer] = []
    /// Optional per-frame hook (e.g. DeckLink SDI output) receiving the shown
    /// pixel buffer. Called on `queue`.
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?

    private let source: DCPFrameSource
    private let clock: DCPPlaybackClock
    private let hz: Double
    /// Thread-safe: returns the current master time (seconds) and whether it is
    /// advancing. Called on the display queue.
    private let clockSource: @Sendable () -> (time: Double, isPlaying: Bool)

    private let queue = DispatchQueue(label: "com.alphasub.dcp.display", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var lastFrame = -1
    private let formatCache = FrameFormatCache()

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
            self.lastFrame = -1   // force a fresh frame into the new layer
        }
    }

    func removeLayer(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self] in
            self?.layers.removeAll { $0 === layer }
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
        let ahead = playing ? 16 : 6
        let behind = playing ? 2 : 6
        Task { await source.prefetch(around: frame, ahead: ahead, behind: behind) }

        guard force || frame != lastFrame else { return }
        lastFrame = frame
        Task { [weak self] in
            guard let self, let f = try? await self.source.frame(at: frame) else { return }
            // The fetch is async; by the time it returns the playhead may have
            // moved on. Only present it if it's still the current frame — this
            // prevents an out-of-order stale frame flashing (a perceived drop).
            self.queue.async {
                guard self.lastFrame == frame else { return }
                self.enqueue(f.pixelBuffer)
            }
        }
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        onFrame?(pixelBuffer)
        guard !layers.isEmpty, let format = formatCache.format(for: pixelBuffer) else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: .invalid,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return }
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
