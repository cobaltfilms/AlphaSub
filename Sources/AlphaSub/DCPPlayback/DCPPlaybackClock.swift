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

/// Tracks which frame the display loop believes is on screen, and whether a
/// frame whose fetch came back empty should be asked for again.
///
/// The loop marks a frame as "handled" BEFORE the fetch, because the fetch is
/// async and the marker is what stops every later tick re-requesting the same
/// index. The cost is that a fetch which fails leaves the loop believing it has
/// done its job while the screen still holds the PREVIOUS frame, and no later
/// tick ever asks again. While the playhead keeps moving that self-heals within
/// a frame or two — which is why dragging the playhead always looked right —
/// but a parked playhead makes exactly one request, which is why stepping cue
/// to cue with the arrow keys could sit on the previous picture indefinitely.
///
/// Pure, so the rule can be tested without a decoder: see DCPFramePresentationTests.
public struct DCPFramePresentation: Sendable, Equatable {
    /// The frame the loop has committed to; -1 means "nothing claimed".
    public private(set) var current: Int = -1
    private var retryFrame: Int = -1
    private var retryCount: Int = 0

    /// How many times one frame may be re-requested. A cancelled decode — the
    /// normal outcome when a jump drops the work queued for the old position —
    /// succeeds on the next attempt, so the retry is cheap; a genuinely
    /// undecodable frame must not spin the loop at tick rate forever.
    public static let maxRetries = 3

    public init() {}

    /// True when this tick should fetch `frame`.
    public mutating func shouldFetch(_ frame: Int, force: Bool) -> Bool {
        guard force || frame != current else { return false }
        current = frame
        return true
    }

    /// A fetch came back empty. Returns true if the frame was reopened, so the
    /// next tick asks again.
    public mutating func noteFailure(of frame: Int) -> Bool {
        guard current == frame else { return false }   // a newer target owns it
        if retryFrame != frame { retryFrame = frame; retryCount = 0 }
        guard retryCount < Self.maxRetries else { return false }
        retryCount += 1
        current = -1
        return true
    }

    /// A frame reached the screen.
    public mutating func notePresented(_ frame: Int) {
        if retryFrame == frame { retryFrame = -1; retryCount = 0 }
    }

    /// A new output layer needs a frame pushed into it regardless of position.
    public mutating func invalidate() { current = -1 }

    /// True while `frame` is still the frame the loop is waiting on.
    public func isCurrent(_ frame: Int) -> Bool { current == frame }
}
