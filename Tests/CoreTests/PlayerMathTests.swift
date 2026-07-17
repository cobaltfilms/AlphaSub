import XCTest
@testable import AlphaSubCore

final class PlayerMathTests: XCTestCase {
    func testFractionClampsAndHandlesZeroDuration() {
        XCTAssertEqual(PlayerMath.fraction(time: 5, duration: 10), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PlayerMath.fraction(time: -1, duration: 10), 0)
        XCTAssertEqual(PlayerMath.fraction(time: 99, duration: 10), 1)
        XCTAssertEqual(PlayerMath.fraction(time: 5, duration: 0), 0)
    }

    func testTimeAtXRoundTrip() {
        XCTAssertEqual(PlayerMath.time(atX: 0, width: 200, duration: 60), 0)
        XCTAssertEqual(PlayerMath.time(atX: 200, width: 200, duration: 60), 60)
        XCTAssertEqual(PlayerMath.time(atX: 100, width: 200, duration: 60), 30, accuracy: 1e-9)
        XCTAssertEqual(PlayerMath.time(atX: 50, width: 0, duration: 60), 0)
        XCTAssertEqual(PlayerMath.time(atX: -10, width: 200, duration: 60), 0)
    }

    func testBottomPaddingIsPercentOfPictureHeight() {
        XCTAssertEqual(PlayerMath.bottomPadding(vPositionPercent: 8, pictureHeight: 540), 43.2, accuracy: 0.001)
        XCTAssertEqual(PlayerMath.bottomPadding(vPositionPercent: 8, pictureHeight: 0), 0)
    }

    func testHorizontalOffset() {
        XCTAssertEqual(PlayerMath.horizontalOffset(hPositionPercent: -50, pictureWidth: 1000), -500)
        XCTAssertEqual(PlayerMath.horizontalOffset(hPositionPercent: 0, pictureWidth: 1000), 0)
        XCTAssertEqual(PlayerMath.horizontalOffset(hPositionPercent: 25, pictureWidth: 1000), 250)
    }

    func testPixelAlignedBorderWidthLandsOnDeviceGrid() {
        // Retina (scale 2): at ≥1 device pixel, result × 2 must be a whole
        // number of device pixels (no subpixel rendering at output scales).
        let w = PlayerMath.pixelAlignedBorderWidth(contentPixels: 2, scaleFactor: 0.296, displayScale: 2)
        XCTAssertEqual((w * 2).truncatingRemainder(dividingBy: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(PlayerMath.pixelAlignedBorderWidth(contentPixels: 1, scaleFactor: 1, displayScale: 2), 1)
        // Zero stays zero; identity case is exact.
        XCTAssertEqual(PlayerMath.pixelAlignedBorderWidth(contentPixels: 0, scaleFactor: 1, displayScale: 2), 0)
        XCTAssertEqual(PlayerMath.pixelAlignedBorderWidth(contentPixels: 3, scaleFactor: 1, displayScale: 1), 3)
    }

    func testPixelAlignedBorderWidthStaysProportionalInSmallPreviews() {
        // Below one device pixel, the exact proportional width is returned —
        // regression for the "outline way too large in small preview" bug
        // (the old max(1, …) floor forced 0.3 pt up to 0.5 pt on Retina and
        // a 3.3× too-thick 1.0 pt on 1× displays).
        XCTAssertEqual(PlayerMath.pixelAlignedBorderWidth(contentPixels: 1, scaleFactor: 0.3, displayScale: 2),
                       0.3, accuracy: 1e-9)
        XCTAssertEqual(PlayerMath.pixelAlignedBorderWidth(contentPixels: 1, scaleFactor: 0.3, displayScale: 1),
                       0.3, accuracy: 1e-9)
        XCTAssertEqual(PlayerMath.pixelAlignedBorderWidth(contentPixels: 1, scaleFactor: 0.05, displayScale: 2),
                       0.05, accuracy: 1e-9)
        // Exactly at the 1-device-pixel boundary, snapping resumes:
        // 2 px × 0.3 × scale2 = 1.2 device px → rounds to 1 → 0.5 pt.
        XCTAssertEqual(PlayerMath.pixelAlignedBorderWidth(contentPixels: 2, scaleFactor: 0.3, displayScale: 2),
                       0.5, accuracy: 1e-9)
    }

    func testSubtitleIndexHonorsTimecodeOffset() {
        // Project starts at 01:00:00:00 → subtitle times are absolute.
        let intervals: [(start: Double, end: Double)] = [(3600.0, 3602.5), (3605.0, 3607.0)]
        // Player at 1 s into the media = 3601 s absolute → first subtitle.
        XCTAssertEqual(PlayerMath.subtitleIndex(at: 1.0, timecodeOffset: 3600, intervals: intervals), 0)
        // Without the offset nothing matches — this is the old fullscreen bug.
        XCTAssertNil(PlayerMath.subtitleIndex(at: 1.0, timecodeOffset: 0, intervals: intervals))
        // Gap between cues → nil.
        XCTAssertNil(PlayerMath.subtitleIndex(at: 3.0, timecodeOffset: 3600, intervals: intervals))
        // Inclusive bounds.
        XCTAssertEqual(PlayerMath.subtitleIndex(at: 2.5, timecodeOffset: 3600, intervals: intervals), 0)
    }

    func testActiveRectInsetsAndClamping() {
        let picture = CGRect(x: 0, y: 0, width: 960, height: 540)   // half-size 1920×1080
        let insets = PlayerMath.ActivePictureInsets(top: 138, bottom: 138, left: 0, right: 0) // 2.39:1 letterbox
        let active = PlayerMath.activeRect(picture: picture, insets: insets, videoNaturalSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(active.minY, 69, accuracy: 0.001)            // 138 × 0.5
        XCTAssertEqual(active.height, 540 - 138, accuracy: 0.001)
        // Over-inset clamps to zero size, never negative.
        let crazy = PlayerMath.ActivePictureInsets(top: 600, bottom: 600, left: 0, right: 0)
        XCTAssertEqual(PlayerMath.activeRect(picture: picture, insets: crazy, videoNaturalSize: CGSize(width: 1920, height: 1080)).height, 0)
        // Zero insets are the identity.
        XCTAssertEqual(PlayerMath.activeRect(picture: picture, insets: .init(), videoNaturalSize: CGSize(width: 1920, height: 1080)), picture)
    }

    func testPreviewScaleFactorTracksDisplayedHeight() {
        // 320 pt pane showing 1080p video — the historical default. 320/1080
        // ≈ 0.296 sits just below the 0.3 legibility clamp, so it resolves to
        // 0.3 — exactly what the old hand-rolled max(320/reference, 0.3) did.
        XCTAssertEqual(PlayerMath.previewScaleFactor(displayedHeight: 320, naturalHeight: 1080),
                       0.3, accuracy: 1e-9)
        // Above the clamp, the scale tracks the pane height linearly.
        XCTAssertEqual(PlayerMath.previewScaleFactor(displayedHeight: 640, naturalHeight: 1080),
                       640.0/1080.0, accuracy: 1e-9)
        // Doubling the pane height doubles the subtitle scale.
        XCTAssertEqual(PlayerMath.previewScaleFactor(displayedHeight: 1280, naturalHeight: 1080),
                       1280.0/1080.0, accuracy: 1e-9)
    }

    func testPreviewScaleFactorFallbacksAndClamp() {
        XCTAssertEqual(PlayerMath.previewScaleFactor(displayedHeight: 540, naturalHeight: 0),
                       0.5, accuracy: 1e-9)                       // unknown → 1080 reference
        XCTAssertEqual(PlayerMath.previewScaleFactor(displayedHeight: 100, naturalHeight: 1080), 0.3) // clamp
        XCTAssertEqual(PlayerMath.previewScaleFactor(displayedHeight: 0, naturalHeight: 1080), 0.3)
    }

    func testPictureScaleFactorScalesWithVideoRaster() {
        // 1:1 when the on-screen picture matches the video raster.
        XCTAssertEqual(PlayerMath.pictureScaleFactor(pictureHeight: 1080, naturalHeight: 1080),
                       1.0, accuracy: 1e-9)
        // Halving the displayed picture height halves the subtitle scale.
        XCTAssertEqual(PlayerMath.pictureScaleFactor(pictureHeight: 540, naturalHeight: 1080),
                       0.5, accuracy: 1e-9)
        // 4K fullscreen of 1080p material doubles the scale.
        XCTAssertEqual(PlayerMath.pictureScaleFactor(pictureHeight: 2160, naturalHeight: 1080),
                       2.0, accuracy: 1e-9)
    }

    func testPictureScaleFactorFallbacks() {
        // Unknown natural size: assume 1:1 so the overlay is still usable.
        XCTAssertEqual(PlayerMath.pictureScaleFactor(pictureHeight: 540, naturalHeight: 0),
                       1.0, accuracy: 1e-9)
        // Degenerate container: same fallback.
        XCTAssertEqual(PlayerMath.pictureScaleFactor(pictureHeight: 0, naturalHeight: 1080),
                       1.0, accuracy: 1e-9)
    }

    func testPercentInsetStaysWithinAvailableSpace() {
        // Available space = picture extent − label extent: 0 = flush start,
        // 100 = flush end, label fully inside at both extremes.
        XCTAssertEqual(PlayerMath.percentInset(percent: 0, available: 400), 0)
        XCTAssertEqual(PlayerMath.percentInset(percent: 50, available: 400), 200)
        XCTAssertEqual(PlayerMath.percentInset(percent: 100, available: 400), 400)
        XCTAssertEqual(PlayerMath.percentInset(percent: 130, available: 400), 400) // clamped
        XCTAssertEqual(PlayerMath.percentInset(percent: -10, available: 400), 0)   // clamped
        XCTAssertEqual(PlayerMath.percentInset(percent: 50, available: 0), 0)      // degenerate
    }

    func testCenteredPercentOffsetIsFlushAtExtremes() {
        // Per-cue percentages: 0 = flush left, 50 = centered, 100 = flush right.
        XCTAssertEqual(PlayerMath.centeredPercentOffset(percent: 0, available: 600), -300)
        XCTAssertEqual(PlayerMath.centeredPercentOffset(percent: 50, available: 600), 0)
        XCTAssertEqual(PlayerMath.centeredPercentOffset(percent: 100, available: 600), 300)
        // Global H Pos (−50…+50) maps via percent = hPosition + 50.
        XCTAssertEqual(PlayerMath.centeredPercentOffset(percent: -25 + 50, available: 600), -150)
        XCTAssertEqual(PlayerMath.centeredPercentOffset(percent: 50 + 50, available: 600), 300)
        XCTAssertEqual(PlayerMath.centeredPercentOffset(percent: 50, available: 0), 0)  // degenerate
    }

    // MARK: Output picture rect (DeckLink fit)

    func testOutputPictureRectExactMatchFillsFrame() {
        let r = PlayerMath.outputPictureRect(sourceNatural: CGSize(width: 1920, height: 1080),
                                             outputSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testOutputPictureRectScopeSourceLetterboxes() {
        // 2.39:1 scope (1920×804) into a 16:9 1080 frame → full width, centred
        // band with equal top/bottom bars.
        let r = PlayerMath.outputPictureRect(sourceNatural: CGSize(width: 1920, height: 804),
                                             outputSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(r.width, 1920)
        XCTAssertEqual(r.height, 804)
        XCTAssertEqual(r.minX, 0)
        XCTAssertEqual(r.minY, (1080 - 804) / 2)   // 138 — centred bars
    }

    func testOutputPictureRectPillarboxes() {
        // 4:3 (1440×1080) into a 16:9 1920×1080 frame → full height, pillarbars.
        let r = PlayerMath.outputPictureRect(sourceNatural: CGSize(width: 1440, height: 1080),
                                             outputSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(r.height, 1080)
        XCTAssertEqual(r.width, 1440)
        XCTAssertEqual(r.minY, 0)
        XCTAssertEqual(r.minX, (1920 - 1440) / 2)  // 240
    }

    func testOutputPictureRectUpscalesSDToHD() {
        // SD 720×576 into 1920×1080: scaled to fit by the smaller ratio (height).
        let r = PlayerMath.outputPictureRect(sourceNatural: CGSize(width: 720, height: 576),
                                             outputSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(r.height, 1080)
        XCTAssertEqual(r.width, (720.0 * (1080.0 / 576.0)).rounded()) // 1350
        XCTAssertLessThan(r.width, 1920)
    }

    func testOutputPictureRectDegenerateReturnsFullFrame() {
        let r = PlayerMath.outputPictureRect(sourceNatural: .zero,
                                             outputSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    // The fit must be driven by the source's DISPLAY size, not its coded size.
    // An anamorphic master (2376×1080 stored, shown 16:9) must FILL a 1080 frame:
    // feeding the coded size would wrongly letterbox it to a 2.2:1 band, pushing
    // subtitles up off the picture bottom. The bridge and overlay both feed the
    // PAR-corrected display size, so they fill and stay aligned.
    func testOutputPictureRectAnamorphicDisplaySizeFillsFrame() {
        // Display size (PAR-corrected) → full 16:9 frame, no bars.
        let display = PlayerMath.outputPictureRect(sourceNatural: CGSize(width: 1920, height: 1080),
                                                   outputSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(display, CGRect(x: 0, y: 0, width: 1920, height: 1080))

        // Coded size (the bug) → a centred 2.2:1 band with top/bottom bars.
        let coded = PlayerMath.outputPictureRect(sourceNatural: CGSize(width: 2376, height: 1080),
                                                 outputSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(coded.width, 1920)
        XCTAssertLessThan(coded.height, 1080)      // letterboxed — the defect we fixed
        XCTAssertGreaterThan(coded.minY, 0)
    }
}
