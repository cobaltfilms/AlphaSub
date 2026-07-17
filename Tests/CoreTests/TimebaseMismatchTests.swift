import XCTest
@testable import AlphaSubCore

/// The heuristic behind the "subtitles are on a different timebase than the
/// video" import warning: cues that fall outside the video's timeline window
/// get a whole-hour shift proposal onto the video's timebase; cues that fit
/// the window are left alone. The window origin is the VIDEO's own program
/// start timecode, not an assumed zero.
final class TimebaseMismatchTests: XCTestCase {

    /// Zero-based video, hour-based subtitle reel → shift down one hour.
    func testHourBasedReelAgainstZeroBasedVideo() {
        // Cues 01:00:13 … 02:35:00 (3613…9300 s), video zero-based, 1h40 long.
        let shift = TimebaseMismatch.proposedShiftSeconds(
            firstCueStart: 3613, lastCueEnd: 9300,
            videoStartSeconds: 0, videoDuration: 6000)
        XCTAssertEqual(shift, -3600)
    }

    /// Video that itself carries a 01:00:00:00 program start, zero-based subs →
    /// shift the subs UP one hour to meet the video's timebase.
    func testZeroBasedSubsAgainstHourBasedVideo() {
        // Video window [3600, 9600]; subs 00:00:13 … 01:35:00 (13…5700).
        let shift = TimebaseMismatch.proposedShiftSeconds(
            firstCueStart: 13, lastCueEnd: 5700,
            videoStartSeconds: 3600, videoDuration: 6000)
        XCTAssertEqual(shift, 3600)
    }

    /// 10:00:00:00 broadcast-master video, zero-based subs → +10 h.
    func testTenHourBroadcastVideo() {
        let shift = TimebaseMismatch.proposedShiftSeconds(
            firstCueStart: 10, lastCueEnd: 2990,
            videoStartSeconds: 36_000, videoDuration: 3200)
        XCTAssertEqual(shift, 36_000)
    }

    /// Same timebase (both zero-based, cues inside the window) → no proposal.
    func testZeroBasedMatchIsLeftAlone() {
        XCTAssertNil(TimebaseMismatch.proposedShiftSeconds(
            firstCueStart: 13, lastCueEnd: 5400,
            videoStartSeconds: 0, videoDuration: 6000))
    }

    /// Reel-based subs against a matching reel-based video (both 01:00:xx) →
    /// cues already inside the window, no proposal.
    func testMatchingReelBasesLeftAlone() {
        XCTAssertNil(TimebaseMismatch.proposedShiftSeconds(
            firstCueStart: 3613, lastCueEnd: 9300,
            videoStartSeconds: 3600, videoDuration: 6000))
    }

    /// In a long (3 h) zero-based video, cues that legitimately start an hour
    /// in and fit within the window must NOT be flagged.
    func testCuesThatFitTheWindowAreNotFlagged() {
        XCTAssertNil(TimebaseMismatch.proposedShiftSeconds(
            firstCueStart: 3613, lastCueEnd: 9300,
            videoStartSeconds: 0, videoDuration: 10_800))
    }

    /// A shift that still doesn't land the cues in the window (wrong video,
    /// e.g. a 10 s clip) must not be proposed.
    func testShiftThatStillMissesTheWindowIsNotProposed() {
        XCTAssertNil(TimebaseMismatch.proposedShiftSeconds(
            firstCueStart: 3613, lastCueEnd: 9300,
            videoStartSeconds: 0, videoDuration: 10))
    }

    /// No video → nothing to compare against.
    func testNoVideoNoProposal() {
        XCTAssertNil(TimebaseMismatch.proposedShiftSeconds(
            firstCueStart: 3613, lastCueEnd: 9300,
            videoStartSeconds: 0, videoDuration: 0))
    }

    /// A sub-hour overrun with a zero-based video is not a whole-hour timebase
    /// offset (rounds to 0) → no proposal.
    func testSubHourOverrunRoundsToNoShift() {
        XCTAssertNil(TimebaseMismatch.proposedShiftSeconds(
            firstCueStart: 300, lastCueEnd: 7200,
            videoStartSeconds: 0, videoDuration: 3000))
    }
}
