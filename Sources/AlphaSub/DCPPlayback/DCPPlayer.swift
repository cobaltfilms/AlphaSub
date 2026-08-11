import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - DCP picture player (open-core)
//
// Presents a DCP picture track (Grok-decoded JPEG2000, X'Y'Z'→Rec709) in one or
// more AVSampleBufferDisplayLayers — the main video area, plus fullscreen and
// detached windows — all fed by a single off-main display loop. In the app it
// runs in FOLLOWER mode: the host's PlaybackEngine plays the DCP's extracted
// WAV (the master clock), and this player only shows the frame for the current
// time — so scrubbing, JKL, play/pause and subtitle sync come from the existing
// engine unchanged.
//
// AVFoundation can't decode cinema JPEG2000, so this is a parallel picture
// engine to the app's AVPlayer. The display loop runs entirely OFF the main
// thread (DCPDisplayLoop) so it never competes with SwiftUI.

@MainActor
public final class DCPPlayer: ObservableObject {

    public let duration: Double
    public var fps: Double { clock.fps }

    /// FOLLOWER clock: thread-safe, returns the master time (seconds) and
    /// whether it is advancing. Read off the main thread by the display loop —
    /// a plain `@Sendable` closure (e.g. reading the live AVPlayer time).
    public var externalClock: (@Sendable () -> (time: Double, isPlaying: Bool))?

    private let source: DCPFrameSource
    private let clock: DCPPlaybackClock
    private var loop: DCPDisplayLoop?

    /// Frames shown and frames thrown away since this player was created, for
    /// the statistics panel. Zero until the display loop exists (it starts with
    /// the first layer or frame hook), which is also the honest answer.
    public var frameTotals: (presented: Int, dropped: Int) {
        loop?.counters.totals ?? (0, 0)
    }

    public convenience init(pictureURL: URL, fps: Double, pictureKey: Data? = nil,
                             cacheCapacity: Int = 64) throws {
        let source = try DCPFrameSource(pictureURL: pictureURL, pictureKey: pictureKey,
                                         cacheCapacity: cacheCapacity)
        self.init(source: source, fps: fps)
    }

    /// Multi-reel init: one (URL, key) pair per reel that has a picture asset.
    /// The caller (which can see DCPComposition) builds this list; the player
    /// stays free of the paywalled DCP types. `fps` is the composition edit
    /// rate (all reels share it).
    public convenience init(pictureURLs: [(url: URL, key: Data?)],
                             fps: Double,
                             cacheCapacity: Int = 64) throws {
        let segments: [(MXFPictureReader, Data?)] = try pictureURLs.map { entry in
            let reader = try MXFPictureReader(url: entry.url, pictureKey: entry.key)
            return (reader, entry.key)
        }
        let source = try DCPFrameSource(segments: segments, cacheCapacity: cacheCapacity)
        self.init(source: source, fps: fps)
    }

    public init(source: DCPFrameSource, fps: Double) {
        self.source = source
        self.clock = DCPPlaybackClock(fps: fps, frameCount: source.frameCount)
        self.duration = clock.duration
    }

    /// Kept for the host view's lifecycle symmetry — the loop actually starts
    /// lazily when the first output layer is added.
    public func beginFollowing() { ensureLoop() }
    public func endFollowing() {}

    /// Create a display layer bound to this player and start feeding it. Each
    /// host (main / fullscreen / detached) calls this for its own layer.
    public func addLayer() -> AVSampleBufferDisplayLayer {
        ensureLoop()
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        loop?.addLayer(layer)
        return layer
    }

    public func removeLayer(_ layer: AVSampleBufferDisplayLayer) {
        loop?.removeLayer(layer)
    }

    /// Hook every shown frame (e.g. to drive DeckLink SDI output). Set to nil
    /// to stop. Called on the display queue with the display-resolution buffer.
    public func setFrameHook(_ hook: (@Sendable (CVPixelBuffer) -> Void)?) {
        ensureLoop()
        loop?.onFrame = hook
    }

    private func ensureLoop() {
        guard loop == nil, let externalClock else { return }
        let l = DCPDisplayLoop(source: source, clock: clock,
                               hz: max(60, clock.fps * 2), clockSource: externalClock)
        loop = l
        l.start()
    }
}
