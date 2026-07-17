import XCTest
@testable import AlphaSubCore

/// SMPTE drop-frame counting: at 29.97DF, frame labels ;00 and ;01 are skipped
/// at the start of every minute except minutes divisible by 10 (4 labels at
/// 59.94DF). `totalFrames` remains the true frame count; only the component
/// labels compensate.
final class DropFrameTimecodeTests: XCTestCase {

    // MARK: 29.97 DF label → frame count

    func testOneMinuteDF2997() {
        // 00:01:00;02 is the first label of minute 1 → exactly 1798 + 2 - 2 = 1800 true frames
        let tc = Timecode(h: 0, m: 1, s: 0, f: 2, frameRate: .fps29_97_df)
        XCTAssertEqual(tc.totalFrames, 1800)
    }

    func testTenMinutesDF2997() {
        // Minute 10 is a non-drop minute: 00:10:00;00 exists and equals 17982 true frames
        let tc = Timecode(h: 0, m: 10, s: 0, f: 0, frameRate: .fps29_97_df)
        XCTAssertEqual(tc.totalFrames, 17982)
    }

    func testOneHourDF2997() {
        // Classic reference value: 01:00:00;00 DF = 107892 true frames
        let tc = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps29_97_df)
        XCTAssertEqual(tc.totalFrames, 107892)
    }

    // MARK: 29.97 DF frame count → label

    func testComponentsRoundTripAcrossBoundaries() {
        // Sweep frame counts across minute/10-minute boundaries and verify
        // label→frames→label is the identity.
        let interesting: [Int64] = [0, 1, 29, 30, 1799, 1800, 1801, 3597, 3598,
                                    17981, 17982, 17983, 17984, 19779, 19780,
                                    107891, 107892, 215783, 215784]
        for frames in interesting {
            let tc = Timecode(totalFrames: frames, frameRate: .fps29_97_df)
            let c = tc.components
            let rebuilt = Timecode(h: c.h, m: c.m, s: c.s, f: c.f, frameRate: .fps29_97_df)
            XCTAssertEqual(rebuilt.totalFrames, frames, "round-trip failed at \(frames) (label \(tc.smpteString))")
        }
    }

    func testMinuteBoundaryLabelSkipsDroppedFrames() {
        // True frame 1800 must label as 00:01:00;02, never ;00
        let tc = Timecode(totalFrames: 1800, frameRate: .fps29_97_df)
        XCTAssertEqual(tc.smpteString, "00:01:00;02")
        // The frame before is the last of minute 0
        XCTAssertEqual(Timecode(totalFrames: 1799, frameRate: .fps29_97_df).smpteString, "00:00:59;29")
    }

    func testNonDropMinuteKeepsAllLabels() {
        XCTAssertEqual(Timecode(totalFrames: 17982, frameRate: .fps29_97_df).smpteString, "00:10:00;00")
        XCTAssertEqual(Timecode(totalFrames: 17984, frameRate: .fps29_97_df).smpteString, "00:10:00;02")
    }

    func testNoLabelIsEverANonExistentDropFrame() {
        // Exhaustive over the first 20 minutes: a DF label ;00/;01 must never
        // appear at s==0 of a non-10th minute.
        for frames in 0..<(20 * 1798 + 40) {
            let c = Timecode(totalFrames: Int64(frames), frameRate: .fps29_97_df).components
            if c.s == 0 && c.m % 10 != 0 {
                XCTAssertGreaterThanOrEqual(c.f, 2, "invalid DF label at frame \(frames): \(c)")
            }
        }
    }

    func testWallClockStaysTrueToRealTime() {
        // One DF hour of labels ≈ one real hour: 01:00:00;00 = 107892 frames
        // = 107892 / 29.97 s ≈ 3599.964 s (DF error is ~3.6ms/hour, not 3.6s)
        let tc = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps29_97_df)
        XCTAssertEqual(tc.seconds, 3600.0, accuracy: 0.01)
    }

    // MARK: Invalid label snapping

    func testNonExistentLabelSnapsForward() {
        // 00:01:00;00 doesn't exist in DF counting → snaps to 00:01:00;02
        let tc = Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps29_97_df)
        XCTAssertEqual(tc.totalFrames, 1800)
        XCTAssertEqual(tc.smpteString, "00:01:00;02")
    }

    func testParseDropFrameString() throws {
        let tc = try Timecode.parse("00:01:00;02", frameRate: .fps29_97_df)
        XCTAssertEqual(tc.totalFrames, 1800)
    }

    // MARK: 59.94 DF

    func testOneMinuteDF5994() {
        // 4 labels dropped per minute: 00:01:00;04 = 3600 true frames
        let tc = Timecode(h: 0, m: 1, s: 0, f: 4, frameRate: .fps59_94_df)
        XCTAssertEqual(tc.totalFrames, 3600)
        XCTAssertEqual(Timecode(totalFrames: 3600, frameRate: .fps59_94_df).smpteString, "00:01:00;04")
    }

    func testOneHourDF5994() {
        // 2 × the 29.97 reference: 01:00:00;00 = 215784 true frames
        let tc = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps59_94_df)
        XCTAssertEqual(tc.totalFrames, 215784)
    }

    // MARK: NDF is untouched

    func testNDFComponentsUnchanged() {
        let tc = Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps29_97_ndf)
        XCTAssertEqual(tc.totalFrames, 1800)
        XCTAssertEqual(tc.smpteString, "00:01:00:00")
    }

    // MARK: Mixed-frame-rate safety (previously precondition crashes)

    func testMixedRateAdditionConvertsInsteadOfTrapping() {
        let a = Timecode(totalFrames: 25, frameRate: .fps25)   // 1s
        let b = Timecode(totalFrames: 24, frameRate: .fps24)   // 1s
        let sum = a + b
        XCTAssertEqual(sum.frameRate, .fps25)
        XCTAssertEqual(sum.totalFrames, 50)
    }

    func testMixedRateSubtractionConvertsInsteadOfTrapping() {
        let a = Timecode(totalFrames: 50, frameRate: .fps25)   // 2s
        let b = Timecode(totalFrames: 24, frameRate: .fps24)   // 1s
        let diff = a - b
        XCTAssertEqual(diff.totalFrames, 25)
    }

    func testMixedRateComparisonUsesWallClock() {
        let a = Timecode(totalFrames: 24, frameRate: .fps24)   // 1s
        let b = Timecode(totalFrames: 30, frameRate: .fps25)   // 1.2s
        XCTAssertTrue(a < b)
        XCTAssertFalse(b < a)
    }

    // MARK: FormatID codec constants

    func testProResFormatIDsAreDistinct() {
        XCTAssertEqual(FormatID.proRes4444.rawValue, "prores_4444")
        XCTAssertNotEqual(FormatID.proRes4444, FormatID.proRes422)
    }
}
