import XCTest
@testable import AlphaSubCore

final class CountingLeaderTests: XCTestCase {

    // A file whose first frame is 00:59:50:00 is an hour-01 programme with a
    // 10-second leader.
    func testDetectsTenSecondLeaderBeforeHourOne() {
        let firstFrame = Timecode(h: 0, m: 59, s: 50, f: 0, frameRate: .fps25)
        let d = CountingLeader.detect(firstFrame: firstFrame)
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.programStart.smpteString, "01:00:00:00")
        XCTAssertEqual(d?.leaderSeconds ?? 0, 10.0, accuracy: 0.001)
    }

    func testDetectsLeaderBeforeHourTen() {
        let firstFrame = Timecode(h: 9, m: 59, s: 52, f: 0, frameRate: .fps24)
        let d = CountingLeader.detect(firstFrame: firstFrame)
        XCTAssertEqual(d?.programStart.smpteString, "10:00:00:00")
        XCTAssertEqual(d?.leaderSeconds ?? 0, 8.0, accuracy: 0.001)
    }

    // Exactly 12s before the hour is still a leader (inclusive bound)…
    func testTwelveSecondsIsLeader() {
        let firstFrame = Timecode(h: 0, m: 59, s: 48, f: 0, frameRate: .fps25)
        XCTAssertNotNil(CountingLeader.detect(firstFrame: firstFrame))
    }

    // …13s before is not (outside the window → left alone).
    func testThirteenSecondsIsNotLeader() {
        let firstFrame = Timecode(h: 0, m: 59, s: 47, f: 0, frameRate: .fps25)
        XCTAssertNil(CountingLeader.detect(firstFrame: firstFrame))
    }

    // A first frame already on a round hour is not a leader.
    func testExactHourIsNotLeader() {
        let firstFrame = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25)
        XCTAssertNil(CountingLeader.detect(firstFrame: firstFrame))
    }

    // Zero / near-zero start (no timecode track) is not a leader.
    func testZeroStartIsNotLeader() {
        XCTAssertNil(CountingLeader.detect(firstFrame: Timecode(totalFrames: 0, frameRate: .fps25)))
    }

    // A genuinely odd mid-programme start is left alone.
    func testMidHourStartIsNotLeader() {
        let firstFrame = Timecode(h: 1, m: 12, s: 30, f: 0, frameRate: .fps25)
        XCTAssertNil(CountingLeader.detect(firstFrame: firstFrame))
    }
}
