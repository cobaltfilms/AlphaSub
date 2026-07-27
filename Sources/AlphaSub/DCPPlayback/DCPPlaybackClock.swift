import Foundation

// MARK: - DCP playback timing (pure, testable)
//
// The scheduling maths for the Grok player, kept free of AVFoundation so it can
// be unit-tested: mapping a wall/audio clock to a frame index, and choosing the
// prefetch window that keeps the decode-ahead cache warm without thrashing.

public struct DCPPlaybackClock: Sendable {
    public let fps: Double
    public let frameCount: Int

    public init(fps: Double, frameCount: Int) {
        self.fps = fps > 0 ? fps : 24
        self.frameCount = max(0, frameCount)
    }

    /// Total duration in seconds.
    public var duration: Double { Double(frameCount) / fps }

    /// The 0-based frame index shown at `time` seconds, clamped to the reel.
    public func frameIndex(at time: Double) -> Int {
        guard frameCount > 0 else { return 0 }
        let raw = Int((max(0, time) * fps).rounded(.down))
        return min(max(0, raw), frameCount - 1)
    }

    /// The presentation time (seconds) of a frame's first field.
    public func time(ofFrame index: Int) -> Double {
        Double(index) / fps
    }

    /// Indices to prefetch given the current playhead frame and direction:
    /// mostly ahead when playing forward, a small pad behind for tiny
    /// back-steps. Returns a contiguous clamped range.
    public func prefetchWindow(around frame: Int,
                               ahead: Int,
                               behind: Int) -> ClosedRange<Int>? {
        guard frameCount > 0 else { return nil }
        let lo = min(max(0, frame - max(0, behind)), frameCount - 1)
        let hi = min(max(0, frame + max(0, ahead)), frameCount - 1)
        return lo <= hi ? lo...hi : nil
    }
}
