import XCTest
@testable import AlphaSubCore

final class ContextWindowTests: XCTestCase {

    func testAudioOnlyWindowWithPadding() {
        // Cue 10–13 s in a 120 s media file. ±6 s padding → 4–19 s.
        let w = ContextWindow.window(
            cueStart: 10, cueEnd: 13,
            mediaDuration: 120, mode: .audioOnly)
        XCTAssertEqual(w.audioStart, 4, accuracy: 0.001)
        XCTAssertEqual(w.audioEnd, 19, accuracy: 0.001)
        XCTAssertEqual(w.mode, .audioOnly)
        XCTAssertEqual(w.expectedFrameCount, 0)
    }

    func testAudioClampedToMediaStart() {
        // Cue at 2 s: padding would go negative → clamp to 0.
        let w = ContextWindow.window(
            cueStart: 2, cueEnd: 4,
            mediaDuration: 120, mode: .audioOnly)
        XCTAssertEqual(w.audioStart, 0, accuracy: 0.001)
        XCTAssertEqual(w.audioEnd, 10, accuracy: 0.001)
    }

    func testAudioClampedToMediaEnd() {
        // Cue at 118 s in 120 s media.
        let w = ContextWindow.window(
            cueStart: 118, cueEnd: 120,
            mediaDuration: 120, mode: .audioOnly)
        XCTAssertEqual(w.audioStart, 112, accuracy: 0.001)
        XCTAssertEqual(w.audioEnd, 120, accuracy: 0.001)
    }

    func testAudioCappedAt30Seconds() {
        // Long cue (40 s) with ±6 s padding would exceed 30 s audio cap.
        // Center on cue midpoint and truncate to 30 s.
        let w = ContextWindow.window(
            cueStart: 100, cueEnd: 140,
            mediaDuration: 1000, mode: .audioOnly)
        XCTAssertEqual(w.audioDuration, 30, accuracy: 0.001)
        // Midpoint is 120; window should be 105–135.
        XCTAssertEqual(w.audioStart, 105, accuracy: 0.001)
        XCTAssertEqual(w.audioEnd, 135, accuracy: 0.001)
    }

    func testAudioAndVideoModeHasFrames() {
        let w = ContextWindow.window(
            cueStart: 10, cueEnd: 13,
            mediaDuration: 120, mode: .audioAndVideo)
        XCTAssertEqual(w.mode, .audioAndVideo)
        XCTAssertGreaterThan(w.expectedFrameCount, 0)
        // Frame window should match audio window for time alignment.
        XCTAssertEqual(w.frameStart, w.audioStart, accuracy: 0.001)
        XCTAssertEqual(w.frameEnd, w.audioEnd, accuracy: 0.001)
    }

    func testAudioAndVideoCappedAt60Frames() {
        // A 40 s cue with ±6 padding → 52 s window → capped at 60 frames (60 s).
        // 52 s < 60 s so no truncation needed; expect 52 frames.
        let w = ContextWindow.window(
            cueStart: 100, cueEnd: 140,
            mediaDuration: 1000, mode: .audioAndVideo)
        // Audio is capped at 30 s; frames follow audio for time alignment.
        XCTAssertEqual(w.audioDuration, 30, accuracy: 0.001)
        XCTAssertLessThanOrEqual(w.expectedFrameCount, ContextWindow.maxFrames)
    }

    func testContextModeRawValues() {
        XCTAssertEqual(ContextWindow.ContextMode.audioOnly.rawValue, "audioOnly")
        XCTAssertEqual(ContextWindow.ContextMode.audioAndVideo.rawValue, "audioAndVideo")
        XCTAssertEqual(ContextWindow.ContextMode.allCases.count, 2)
    }

    func testDefaultConstants() {
        XCTAssertEqual(ContextWindow.paddingSeconds, 6.0)
        XCTAssertEqual(ContextWindow.maxAudioSeconds, 30.0)
        XCTAssertEqual(ContextWindow.maxFrames, 60)
        XCTAssertEqual(ContextWindow.framesPerSecond, 1.0)
    }
}