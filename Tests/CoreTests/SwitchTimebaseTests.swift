import XCTest
@testable import AlphaSubCore

/// "Switch Timebase" changes ONLY the hour digits of every timecode in a track,
/// preserving minutes/seconds/frames and hour carry-over. It is not a time
/// offset that snaps the first cue to HH:00:00:00.
///
/// These tests exercise the pure rebasing formula used by
/// `SubtitleDocumentViewModel.switchTimebase(newBaseHours:)`.
final class SwitchTimebaseTests: XCTestCase {

    /// Mirrors the view-model logic: shift by a whole-hour delta taken from the
    /// first cue's hour, rebuilding each timecode from its SMPTE components.
    private func rebase(_ tcs: [Timecode], to newBaseHours: Int) -> [Timecode] {
        guard let first = tcs.first else { return tcs }
        let deltaHours = newBaseHours - first.components.h
        return tcs.map { tc in
            let c = tc.components
            return Timecode(h: max(0, c.h + deltaHours), m: c.m, s: c.s, f: c.f, frameRate: tc.frameRate)
        }
    }

    func testHourDigitsSwapPreservesSubHourPart() {
        let fr = FrameRate.fps25
        let first = Timecode(h: 1, m: 0, s: 46, f: 12, frameRate: fr)   // 01:00:46:12
        let result = rebase([first], to: 10)
        XCTAssertEqual(result[0].smpteString, "10:00:46:12")
    }

    func testCarryOverPastOneHour() {
        let fr = FrameRate.fps25
        let first = Timecode(h: 1, m: 0, s: 46, f: 12, frameRate: fr)   // 01:00:46:12
        let later = Timecode(h: 2, m: 23, s: 3, f: 13, frameRate: fr)   // 02:23:03:13
        let result = rebase([first, later], to: 10)
        XCTAssertEqual(result[0].smpteString, "10:00:46:12")
        XCTAssertEqual(result[1].smpteString, "11:23:03:13")   // +9h, NOT 10:23:03:13
    }

    func testNoDeltaWhenAlreadyOnBase() {
        let fr = FrameRate.fps24
        let first = Timecode(h: 10, m: 5, s: 1, f: 3, frameRate: fr)
        let later = Timecode(h: 10, m: 59, s: 59, f: 23, frameRate: fr)
        let result = rebase([first, later], to: 10)
        XCTAssertEqual(result[0].smpteString, "10:05:01:03")
        XCTAssertEqual(result[1].smpteString, "10:59:59:23")
    }

    func testDownwardRebase() {
        let fr = FrameRate.fps25
        let first = Timecode(h: 10, m: 0, s: 12, f: 5, frameRate: fr)
        let later = Timecode(h: 11, m: 30, s: 0, f: 0, frameRate: fr)
        let result = rebase([first, later], to: 1)
        XCTAssertEqual(result[0].smpteString, "01:00:12:05")
        XCTAssertEqual(result[1].smpteString, "02:30:00:00")
    }

    // MARK: - Synced video switch: minimum allowable target hour

    /// The sheet's rule: switching subtitles + video together, the lowest
    /// target hour that keeps the video's first frame ≥ 00:00:00 is
    /// `max(0, firstSubtitleHour − floor(videoOffsetSeconds / 3600))`.
    private func minAllowedHour(firstSubHour: Int, videoOffsetSeconds: Double) -> Int {
        max(0, firstSubHour - Int(videoOffsetSeconds / 3600.0))
    }

    func testMinHourWhenVideoStartsJustBeforeFirstCue() {
        // Video first frame 09:59:30, first subtitle at hour 10. A delta of −10
        // (target 00) would drag the video below zero, so the floor is 01.
        let videoOffset = Double(9 * 3600 + 59 * 60 + 30)   // 09:59:30
        XCTAssertEqual(minAllowedHour(firstSubHour: 10, videoOffsetSeconds: videoOffset), 1)
        // Target 01 → delta −9 → video 09:59:30 − 9h = 00:59:30 (valid).
        let fr = FrameRate.fps25
        let deltaHours = 1 - 10
        let videoNew = videoOffset + Double(deltaHours) * 3600.0
        XCTAssertEqual(Timecode.fromSeconds(videoNew, frameRate: fr).smpteString, "00:59:30:00")
        XCTAssertGreaterThanOrEqual(videoNew, 0)
        // Target 00 → delta −10 → video below zero (must be blocked).
        XCTAssertLessThan(videoOffset + Double(0 - 10) * 3600.0, 0)
    }

    func testMinHourZeroWhenVideoOnWholeHour() {
        // Video first frame exactly 10:00:00 with first cue at hour 10 → the
        // video can reach 00:00:00, so target 00 is allowed.
        XCTAssertEqual(minAllowedHour(firstSubHour: 10, videoOffsetSeconds: 36000), 0)
    }

    func testMinHourZeroWhenVideoStartsAfterFirstCue() {
        // Video later than the subtitles → the subtitles are the binding
        // constraint and can always reach hour 00.
        XCTAssertEqual(minAllowedHour(firstSubHour: 10, videoOffsetSeconds: 11 * 3600), 0)
    }
}
