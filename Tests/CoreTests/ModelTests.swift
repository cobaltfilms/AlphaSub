import XCTest
@testable import AlphaSubCore

final class TimecodeTests: XCTestCase {

    func testTimecodeCreation() {
        let tc = Timecode(h: 1, m: 23, s: 45, f: 12, frameRate: .fps25)
        XCTAssertEqual(tc.smpteString, "01:23:45:12")
        let (h, m, s, f) = tc.components
        XCTAssertEqual(h, 1)
        XCTAssertEqual(s, 45)
        XCTAssertEqual(f, 12)
    }

    func testTimecodeFromSeconds() {
        let tc = Timecode.fromSeconds(90.5, frameRate: .fps25)
        XCTAssertEqual(tc.smpteString, "00:01:30:12") // 90.5 * 25 = 2262.5 → 2263 frames → 1m30s12f
    }

    func testTimecodeFromMilliseconds() {
        let tc = Timecode.fromSeconds(120.320, frameRate: .fps25)
        XCTAssertEqual(tc.milliseconds, 120320)
    }

    func testTimecodeSMPTEParse() {
        let tc = try? Timecode.parse("01:23:45:12", frameRate: .fps25)
        XCTAssertEqual(tc?.smpteString, "01:23:45:12")
    }

    func testTimecodeDropFrame() {
        let tc = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps29_97_df)
        XCTAssertEqual(tc.smpteString, "01:00:00;00")
    }

    func testTimecodeComparison() {
        let a = Timecode(h: 0, m: 0, s: 1, f: 0, frameRate: .fps25)
        let b = Timecode(h: 0, m: 0, s: 3, f: 0, frameRate: .fps25)
        XCTAssertLessThan(a, b)
    }

    func testFrameRates() {
        XCTAssertEqual(FrameRate.fps25.value, 25.0)
        XCTAssertEqual(FrameRate.fps23_976.value, 24000.0 / 1001.0, accuracy: 0.001)
        XCTAssertTrue(FrameRate.fps29_97_df.isDropFrame)
        XCTAssertFalse(FrameRate.fps29_97_ndf.isDropFrame)
    }
}

final class ModelTests: XCTestCase {

    func testSubtitleCPS() {
        let start = Timecode(h: 0, m: 0, s: 0, f: 0, frameRate: .fps25)
        let end = Timecode(h: 0, m: 0, s: 4, f: 0, frameRate: .fps25)
        let sub = Subtitle(
            startTime: start,
            endTime: end,
            textBlocks: [TextBlock(plainText: "0123456789012345678901234567890123456789")]
        )
        XCTAssertEqual(sub.cps, 10.0, accuracy: 0.1)
    }

    func testSubtitlePlainText() {
        let blocks: [TextBlock] = [
            TextBlock(segments: [
                TextSegment(text: "Italic line", style: .italic)
            ]),
            TextBlock(plainText: "Regular line")
        ]
        let sub = Subtitle(
            startTime: .zero,
            endTime: .zero,
            textBlocks: blocks
        )
        XCTAssertEqual(sub.plainText, "Italic line\nRegular line")
    }

    func testDocumentCodable() {
        let doc = SubtitleDocument(
            metadata: DocumentMetadata(title: "Test Project", originator: "Cobalt Films"),
            tracks: []
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try! encoder.encode(doc)

        let decoder = JSONDecoder()
        let restored = try! decoder.decode(SubtitleDocument.self, from: data)
        XCTAssertEqual(restored.metadata.title, "Test Project")
        XCTAssertEqual(restored.metadata.originator, "Cobalt Films")
    }

    // MARK: - Offset Tests

    func testTimecodeAddition() {
        let a = Timecode(h: 0, m: 1, s: 30, f: 0, frameRate: .fps25)
        let b = Timecode(h: 0, m: 0, s: 10, f: 0, frameRate: .fps25)
        let result = a + b
        XCTAssertEqual(result.smpteString, "00:01:40:00")
    }

    func testTimecodeSubtraction() {
        let a = Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps25)
        let b = Timecode(h: 0, m: 0, s: 30, f: 0, frameRate: .fps25)
        let result = a - b
        XCTAssertEqual(result.smpteString, "00:00:30:00")
    }

    func testTimecodeOffset() {
        let tc = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25)
        let offset = Timecode(h: 0, m: 5, s: 0, f: 0, frameRate: .fps25)
        let result = tc.offset(by: offset)
        XCTAssertEqual(result.smpteString, "01:05:00:00")
    }

    func testTimecodeConversion() {
        let tc = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25)
        let converted = tc.converted(to: .fps30)
        XCTAssertEqual(converted.frameRate, .fps30)
        XCTAssertEqual(converted.smpteString, "01:00:00:00")
    }

    func testTrackOffsetAll() {
        let track = Track(
            name: "Test",
            subtitles: [
                Subtitle(startTime: Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps25),
                         endTime: Timecode(h: 0, m: 1, s: 5, f: 0, frameRate: .fps25),
                         textBlocks: [TextBlock(plainText: "Hello")]),
                Subtitle(startTime: Timecode(h: 0, m: 2, s: 0, f: 0, frameRate: .fps25),
                         endTime: Timecode(h: 0, m: 2, s: 5, f: 0, frameRate: .fps25),
                         textBlocks: [TextBlock(plainText: "World")])
            ]
        )
        let offset = Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps25)
        let result = track.offsetAll(by: offset)
        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "00:02:00:00")
        XCTAssertEqual(result.subtitles[0].endTime.smpteString, "00:02:05:00")
        XCTAssertEqual(result.subtitles[1].startTime.smpteString, "00:03:00:00")
        XCTAssertEqual(result.subtitles[1].endTime.smpteString, "00:03:05:00")
    }

    /// A backward offset that stays within the timeline shifts normally.
    func testTrackOffsetAllNegativeWithinBounds() {
        let track = Track(
            name: "Test",
            subtitles: [
                Subtitle(startTime: Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps25),
                         endTime: Timecode(h: 0, m: 1, s: 5, f: 0, frameRate: .fps25),
                         textBlocks: [TextBlock(plainText: "Hello")]),
                Subtitle(startTime: Timecode(h: 0, m: 2, s: 0, f: 0, frameRate: .fps25),
                         endTime: Timecode(h: 0, m: 2, s: 5, f: 0, frameRate: .fps25),
                         textBlocks: [TextBlock(plainText: "World")])
            ]
        )
        let back = Timecode(totalFrames: -Timecode(h: 0, m: 0, s: 30, f: 0, frameRate: .fps25).totalFrames, frameRate: .fps25)
        let result = track.offsetAll(by: back)
        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "00:00:30:00")
        XCTAssertEqual(result.subtitles[1].startTime.smpteString, "00:01:30:00")
    }

    /// A backward offset larger than the earliest cue must NOT produce a
    /// negative timecode: it is capped so the earliest cue lands at 00:00:00:00
    /// while the inter-cue gap (1 min) is preserved.
    func testTrackOffsetAllNegativeClampsToZero() {
        let track = Track(
            name: "Test",
            subtitles: [
                Subtitle(startTime: Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps25),
                         endTime: Timecode(h: 0, m: 1, s: 5, f: 0, frameRate: .fps25),
                         textBlocks: [TextBlock(plainText: "Hello")]),
                Subtitle(startTime: Timecode(h: 0, m: 2, s: 0, f: 0, frameRate: .fps25),
                         endTime: Timecode(h: 0, m: 2, s: 5, f: 0, frameRate: .fps25),
                         textBlocks: [TextBlock(plainText: "World")])
            ]
        )
        // Ask to shift back 10 minutes — far past the first cue at 00:01:00.
        let back = Timecode(totalFrames: -Timecode(h: 0, m: 10, s: 0, f: 0, frameRate: .fps25).totalFrames, frameRate: .fps25)
        let result = track.offsetAll(by: back)
        XCTAssertGreaterThanOrEqual(result.subtitles[0].startTime.totalFrames, 0)
        XCTAssertGreaterThanOrEqual(result.subtitles[1].startTime.totalFrames, 0)
        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "00:00:00:00")
        XCTAssertEqual(result.subtitles[1].startTime.smpteString, "00:01:00:00")  // gap preserved
        XCTAssertFalse(result.subtitles[0].startTime.smpteString.contains("-"))
    }

    /// Negative clamp also applies to a scoped (selected-cues-only) offset,
    /// using only the affected cues to compute the floor.
    func testTrackOffsetByIdsNegativeClampsToZero() {
        let sub1 = Subtitle(startTime: Timecode(h: 0, m: 0, s: 30, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 0, s: 35, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Hello")])
        let sub2 = Subtitle(startTime: Timecode(h: 0, m: 5, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 5, s: 5, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "World")])
        let track = Track(name: "Test", subtitles: [sub1, sub2])
        let back = Timecode(totalFrames: -Timecode(h: 0, m: 2, s: 0, f: 0, frameRate: .fps25).totalFrames, frameRate: .fps25)
        // Only sub1 selected — its 00:00:30 start bounds the shift.
        let result = track.offset(ids: [sub1.id], by: back)
        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "00:00:00:00")
        XCTAssertGreaterThanOrEqual(result.subtitles[0].startTime.totalFrames, 0)
        XCTAssertEqual(result.subtitles[1].startTime.smpteString, "00:05:00:00")  // untouched
    }

    func testTrackOffsetAllTo() {
        let track = Track(
            name: "Test",
            subtitles: [
                Subtitle(startTime: Timecode(h: 0, m: 5, s: 0, f: 0, frameRate: .fps25),
                         endTime: Timecode(h: 0, m: 5, s: 5, f: 0, frameRate: .fps25),
                         textBlocks: [TextBlock(plainText: "Hello")]),
                Subtitle(startTime: Timecode(h: 0, m: 10, s: 0, f: 0, frameRate: .fps25),
                         endTime: Timecode(h: 0, m: 10, s: 5, f: 0, frameRate: .fps25),
                         textBlocks: [TextBlock(plainText: "World")])
            ]
        )
        let target = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25)
        let result = track.offsetAll(to: target)
        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "01:00:00:00")
        XCTAssertEqual(result.subtitles[1].startTime.smpteString, "01:05:00:00")
    }

    func testTrackConvertFrameRate() {
        let track = Track(
            name: "Test",
            subtitles: [
                Subtitle(startTime: Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps25),
                         endTime: Timecode(h: 0, m: 1, s: 5, f: 12, frameRate: .fps25),
                         textBlocks: [TextBlock(plainText: "Test")])
            ]
        )
        let result = track.convertFrameRate(to: .fps30)
        XCTAssertEqual(result.subtitles[0].startTime.frameRate, .fps30)
        XCTAssertEqual(result.subtitles[0].endTime.frameRate, .fps30)
        XCTAssertEqual(result.subtitles[0].startTime.seconds, 60.0, accuracy: 0.001)
        XCTAssertEqual(result.subtitles[0].endTime.seconds, 65.5, accuracy: 0.05)
    }

    func testTrackConvertFrameRateHoldingBase() {
        // The reported case: 24→25 with a 10:00:00:00 programme-start base.
        // Frame-for-frame: the +20:16 portion (frame 496) keeps its frame count
        // and is re-stamped at 25fps → 00:00:19:21, while the 10h base stays put.
        let track = Track(
            name: "Test",
            subtitles: [
                Subtitle(startTime: Timecode(h: 10, m: 0, s: 20, f: 16, frameRate: .fps24),
                         endTime: Timecode(h: 10, m: 0, s: 22, f: 0, frameRate: .fps24),
                         textBlocks: [TextBlock(plainText: "Test")])
            ]
        )
        let base = Timecode(h: 10, m: 0, s: 0, f: 0, frameRate: .fps24)
        let result = track.convertFrameRateHoldingBase(to: .fps25, base: base)
        XCTAssertEqual(result.subtitles[0].startTime.frameRate, .fps25)
        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "10:00:19:21")
        // The base prefix is preserved, not scaled into a huge offset.
        XCTAssertEqual(result.subtitles[0].startTime.components.h, 10)
    }

    func testRelabeledKeepsComponents() {
        let tc = Timecode(h: 10, m: 0, s: 0, f: 0, frameRate: .fps24)
        let relabeled = tc.relabeled(to: .fps25)
        XCTAssertEqual(relabeled.frameRate, .fps25)
        XCTAssertEqual(relabeled.smpteString, "10:00:00:00")
        XCTAssertEqual(relabeled.totalFrames, Int64(10 * 3600 * 25))
    }

    func testDocumentOffsetAll() {
        var doc = SubtitleDocument(
            tracks: [
                Track(name: "Test", subtitles: [
                    Subtitle(startTime: Timecode(h: 0, m: 0, s: 10, f: 0, frameRate: .fps25),
                             endTime: Timecode(h: 0, m: 0, s: 15, f: 0, frameRate: .fps25),
                             textBlocks: [TextBlock(plainText: "Hi")])
                ])
            ]
        )
        let offset = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25)
        doc.offsetAll(by: offset)
        XCTAssertEqual(doc.tracks[0].subtitles[0].startTime.smpteString, "01:00:10:00")
    }

    func testDocumentConvertFrameRate() {
        var doc = SubtitleDocument(
            tracks: [
                Track(name: "Test", subtitles: [
                    Subtitle(startTime: Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps25),
                             endTime: Timecode(h: 0, m: 2, s: 0, f: 0, frameRate: .fps25),
                             textBlocks: [TextBlock(plainText: "Convert me")])
                ])
            ]
        )
        doc.convertFrameRate(to: .fps24)
        XCTAssertEqual(doc.tracks[0].frameRate, .fps24)
        XCTAssertEqual(doc.tracks[0].subtitles[0].startTime.frameRate, .fps24)
        XCTAssertEqual(doc.tracks[0].subtitles[0].startTime.seconds, 60.0, accuracy: 0.001)
    }

    // MARK: - Scoped Offset Tests

    func testTrackOffsetByIds() {
        let sub1 = Subtitle(startTime: Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 1, s: 5, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "First")])
        let sub2 = Subtitle(startTime: Timecode(h: 0, m: 2, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 2, s: 5, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Second")])
        let sub3 = Subtitle(startTime: Timecode(h: 0, m: 3, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 3, s: 5, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Third")])
        let track = Track(name: "Test", subtitles: [sub1, sub2, sub3])

        let offset = Timecode(h: 0, m: 0, s: 10, f: 0, frameRate: .fps25)
        let scopedIDs: Set<UUID> = [sub1.id, sub3.id]
        let result = track.offset(ids: scopedIDs, by: offset)

        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "00:01:10:00")
        XCTAssertEqual(result.subtitles[1].startTime.smpteString, "00:02:00:00")
        XCTAssertEqual(result.subtitles[2].startTime.smpteString, "00:03:10:00")
    }

    func testTrackOffsetByIdsTo() {
        let sub1 = Subtitle(startTime: Timecode(h: 0, m: 5, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 5, s: 5, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "First")])
        let sub2 = Subtitle(startTime: Timecode(h: 0, m: 10, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 10, s: 5, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Second")])
        let track = Track(name: "Test", subtitles: [sub1, sub2])

        let target = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25)
        let scopedIDs: Set<UUID> = [sub2.id]
        let result = track.offset(ids: scopedIDs, to: target)

        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "00:05:00:00")
        XCTAssertEqual(result.subtitles[1].startTime.smpteString, "01:00:00:00")
    }

    func testDocumentOffsetByIds() {
        let sub1 = Subtitle(startTime: Timecode(h: 0, m: 0, s: 10, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 0, s: 15, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Hi")])
        let sub2 = Subtitle(startTime: Timecode(h: 0, m: 0, s: 20, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 0, s: 25, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Bye")])
        var doc = SubtitleDocument(
            tracks: [Track(name: "Test", subtitles: [sub1, sub2])]
        )
        let offset = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25)
        doc.offset(ids: [sub1.id], by: offset)
        XCTAssertEqual(doc.tracks[0].subtitles[0].startTime.smpteString, "01:00:10:00")
        XCTAssertEqual(doc.tracks[0].subtitles[1].startTime.smpteString, "00:00:20:00")
    }

    // MARK: - Baby Sync Tests

    func testTrackBabySync() {
        let sub1 = Subtitle(startTime: Timecode(h: 0, m: 0, s: 10, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 0, s: 15, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "First")])
        let sub2 = Subtitle(startTime: Timecode(h: 0, m: 0, s: 30, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 0, s: 35, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Second")])
        let sub3 = Subtitle(startTime: Timecode(h: 0, m: 1, s: 10, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 1, s: 20, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Third")])
        let track = Track(name: "Test", subtitles: [sub1, sub2, sub3])

        let firstTarget = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25)
        let lastTarget  = Timecode(h: 2, m: 0, s: 0, f: 0, frameRate: .fps25)
        let result = track.babySync(firstTarget: firstTarget, lastTarget: lastTarget)

        // first: 00:00:10:00 → 01:00:00:00, last: 00:01:10:00 → 02:00:00:00
        // ratio = 90000/1500 = 60
        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "01:00:00:00")
        // sub1 end: (375-250)*60 + 90000 = 7500+90000 = 97500 → 65 min
        XCTAssertEqual(result.subtitles[0].endTime.smpteString, "01:05:00:00")
        XCTAssertEqual(result.subtitles[2].startTime.smpteString, "02:00:00:00")
        // sub3 end: (2000-250)*60 + 90000 = 105000+90000 = 195000 → 130 min
        XCTAssertEqual(result.subtitles[2].endTime.smpteString, "02:10:00:00")

        // middle sub2 start: (750-250)*60 + 90000 = 30000+90000 = 120000
        XCTAssertEqual(result.subtitles[1].startTime.totalFrames, 120000)
    }

    func testTrackBabySyncShrink() {
        let sub1 = Subtitle(startTime: Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 1, m: 0, s: 5, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "First")])
        let sub2 = Subtitle(startTime: Timecode(h: 2, m: 0, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 2, m: 0, s: 5, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Second")])
        let track = Track(name: "Test", subtitles: [sub1, sub2])

        // Shrink 1-hour span to 30-second span
        let firstTarget = Timecode(h: 0, m: 0, s: 30, f: 0, frameRate: .fps25)
        let lastTarget  = Timecode(h: 0, m: 1, s: 0, f: 0, frameRate: .fps25)
        let result = track.babySync(firstTarget: firstTarget, lastTarget: lastTarget)

        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "00:00:30:00")
        // sub1 end: 750 + Int64((90125-90000) * 0.00833...) = 750 + 1 = 751
        XCTAssertEqual(result.subtitles[0].endTime.totalFrames, 751)
        XCTAssertEqual(result.subtitles[1].startTime.smpteString, "00:01:00:00")
        // sub2 end: 750 + Int64((180125-90000) * 0.00833...) = 750 + 751 = 1501
        XCTAssertEqual(result.subtitles[1].endTime.totalFrames, 1501)
    }

    func testTrackBabySyncSingleSubtitle() {
        let sub1 = Subtitle(startTime: Timecode(h: 0, m: 5, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 5, s: 5, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Only")])
        let track = Track(name: "Test", subtitles: [sub1])

        let firstTarget = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25)
        let lastTarget  = Timecode(h: 2, m: 0, s: 0, f: 0, frameRate: .fps25)
        let result = track.babySync(firstTarget: firstTarget, lastTarget: lastTarget)

        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "01:00:00:00")
        XCTAssertEqual(result.subtitles[0].endTime.smpteString, "01:00:05:00")
    }

    func testTrackBabySyncZeroRange() {
        let sub1 = Subtitle(startTime: Timecode(h: 0, m: 5, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 5, s: 5, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "First")])
        let sub2 = Subtitle(startTime: Timecode(h: 0, m: 5, s: 0, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 5, s: 3, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Same time")])
        let track = Track(name: "Test", subtitles: [sub1, sub2])

        let firstTarget = Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: .fps25)
        let lastTarget  = Timecode(h: 2, m: 0, s: 0, f: 0, frameRate: .fps25)
        let result = track.babySync(firstTarget: firstTarget, lastTarget: lastTarget)

        XCTAssertEqual(result.subtitles[0].startTime.smpteString, "01:00:00:00")
        XCTAssertEqual(result.subtitles[1].startTime.smpteString, "01:00:00:00")
    }

    func testDocumentFindReplaceAll() {
        let sub1 = Subtitle(startTime: Timecode(h: 0, m: 0, s: 10, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 0, s: 15, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Hello world")])
        let sub2 = Subtitle(startTime: Timecode(h: 0, m: 0, s: 20, f: 0, frameRate: .fps25),
                            endTime: Timecode(h: 0, m: 0, s: 25, f: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: "Goodbye world")])
        var doc = SubtitleDocument(
            tracks: [Track(name: "Test", subtitles: [sub1, sub2])]
        )

        let count = doc.findReplaceAll(search: "world", replacement: "universe", matchCase: true)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(doc.tracks[0].subtitles[0].textBlocks[0].plainText, "Hello universe")
        XCTAssertEqual(doc.tracks[0].subtitles[1].textBlocks[0].plainText, "Goodbye universe")
    }

    func testDocumentFindReplaceAllCaseInsensitive() {
        let sub = Subtitle(startTime: .zero,
                           endTime: .zero,
                           textBlocks: [TextBlock(plainText: "Hello HELLO hello")])
        var doc = SubtitleDocument(
            tracks: [Track(name: "Test", subtitles: [sub])]
        )

        let count = doc.findReplaceAll(search: "hello", replacement: "hi", matchCase: false)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(doc.tracks[0].subtitles[0].textBlocks[0].plainText, "hi hi hi")
    }

    func testDocumentFindReplaceAllNoMatch() {
        let sub = Subtitle(startTime: .zero,
                           endTime: .zero,
                           textBlocks: [TextBlock(plainText: "Nothing here")])
        var doc = SubtitleDocument(
            tracks: [Track(name: "Test", subtitles: [sub])]
        )

        let count = doc.findReplaceAll(search: "xyz", replacement: "abc", matchCase: true)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(doc.tracks[0].subtitles[0].textBlocks[0].plainText, "Nothing here")
    }

    func testDocumentFindReplaceAllMultipleBlocks() {
        let sub = Subtitle(startTime: .zero,
                           endTime: .zero,
                           textBlocks: [TextBlock(plainText: "First block"), TextBlock(plainText: "Second block")])
        var doc = SubtitleDocument(
            tracks: [Track(name: "Test", subtitles: [sub])]
        )

        let count = doc.findReplaceAll(search: "block", replacement: "line", matchCase: true)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(doc.tracks[0].subtitles[0].textBlocks[0].plainText, "First line")
        XCTAssertEqual(doc.tracks[0].subtitles[0].textBlocks[1].plainText, "Second line")
    }
}

final class TextBlockNormalizationTests: XCTestCase {

    func testSplitOnNewlinesPreservesStyleAndLines() {
        let block = TextBlock(segments: [
            TextSegment(text: "Bonjour\nle ", style: .italic),
            TextSegment(text: "monde", style: []),
        ])
        let lines = block.splitOnNewlines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].plainText, "Bonjour")
        XCTAssertEqual(lines[0].segments.first?.style, .italic)
        XCTAssertEqual(lines[1].plainText, "le monde")
        XCTAssertEqual(lines[1].segments.first?.style, .italic, "the italic carries onto the second line")
    }

    func testSplitOnNewlinesNoOpWithoutNewline() {
        let block = TextBlock(plainText: "Single line")
        XCTAssertEqual(block.splitOnNewlines(), [block])
    }

    func testNormalizeDocumentRepairsEmbeddedNewlineCue() {
        let fr = FrameRate.fps25
        let embedded = Subtitle(
            startTime: Timecode(h: 1, m: 0, s: 0, f: 0, frameRate: fr),
            endTime:   Timecode(h: 1, m: 0, s: 2, f: 0, frameRate: fr),
            textBlocks: [TextBlock(plainText: "Line 1\nLine 2")])     // edited-cue shape
        let clean = Subtitle(
            startTime: Timecode(h: 1, m: 0, s: 3, f: 0, frameRate: fr),
            endTime:   Timecode(h: 1, m: 0, s: 5, f: 0, frameRate: fr),
            textBlocks: [TextBlock(plainText: "A"), TextBlock(plainText: "B")])  // imported shape
        var doc = SubtitleDocument(
            tracks: [Track(name: "T", language: LanguageCode("fr"), subtitles: [embedded, clean])])
        let repaired = doc.normalizeTextBlockLineBreaks()
        XCTAssertEqual(repaired, 1, "only the embedded-newline cue is changed")
        XCTAssertEqual(doc.tracks[0].subtitles[0].textBlocks.count, 2)
        XCTAssertEqual(doc.tracks[0].subtitles[0].plainText, "Line 1\nLine 2", "plainText is unchanged")
        XCTAssertEqual(doc.tracks[0].subtitles[1].textBlocks.count, 2, "already-clean cue untouched")
        XCTAssertEqual(doc.normalizeTextBlockLineBreaks(), 0, "idempotent — second pass is a no-op")
    }
}
