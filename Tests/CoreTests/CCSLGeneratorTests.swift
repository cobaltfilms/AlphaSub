import XCTest
@testable import AlphaSubCore

final class CCSLGeneratorTests: XCTestCase {

    // MARK: Fixture

    private let fr = FrameRate.fps25

    private func tc(_ seconds: Double) -> Timecode {
        Timecode.fromSeconds(seconds, frameRate: fr)
    }

    private func cue(_ start: Double, _ end: Double, _ text: String,
                     speaker: String = "",
                     isMusic: Bool = false, isForced: Bool = false,
                     isOffSpeech: Bool = false, isNewScene: Bool = false) -> Subtitle {
        Subtitle(startTime: tc(start), endTime: tc(end),
                 textBlocks: text.components(separatedBy: "\n").map { TextBlock(plainText: $0) },
                 isForced: isForced, isMusic: isMusic, isOffSpeech: isOffSpeech,
                 isNewScene: isNewScene, speaker: speaker)
    }

    /// Primary (dialogue) track: 4 cues with speakers and flags.
    /// A 10 s silence separates cue 2 and cue 3 (10–20 s).
    private var primary: Track {
        Track(name: "EN", language: "en", subtitles: [
            cue(1, 3, "Hello, there.", speaker: "ANNA"),
            cue(4, 6, "Hi!\nCome in.", speaker: "BEN"),
            cue(20, 23, "Much later.", speaker: "ANNA", isOffSpeech: true),
            cue(24, 26, "The end.", speaker: "BEN", isMusic: true),
        ])
    }

    /// Translation track: overlaps cues 1 and 2; nothing for cues 3 and 4.
    private var secondary: Track {
        Track(name: "FR", language: "fr", subtitles: [
            cue(1.2, 3.2, "Bonjour."),
            cue(4, 6, "Salut !\nEntre."),
            cue(40, 42, "Sans rapport."),
        ])
    }

    private func cues(_ rows: [CCSLGenerator.Row]) -> [CCSLGenerator.Cue] {
        rows.compactMap { if case .cue(let c) = $0 { return c } else { return nil } }
    }

    private func headers(_ rows: [CCSLGenerator.Row]) -> [String] {
        rows.compactMap { if case .sceneHeader(let t) = $0 { return t } else { return nil } }
    }

    // MARK: Translation pairing

    func testOverlapPairingFillsTranslationColumn() {
        let rows = CCSLGenerator.rows(primary: primary, secondary: secondary)
        let c = cues(rows)
        XCTAssertEqual(c.count, 4)
        // Cue 1 overlaps the FR cue by 1.8 s of 2 s (≥50% of the shorter cue).
        XCTAssertEqual(c[0].translation, "Bonjour.")
        // Exact-overlap pair; multi-line translation joined with " / ".
        XCTAssertEqual(c[1].translation, "Salut ! / Entre.")
    }

    func testUnmatchedCuesGetEmptyTranslationCells() {
        let rows = CCSLGenerator.rows(primary: primary, secondary: secondary)
        let c = cues(rows)
        // No FR cue overlaps 20–23 or 24–26 (the 40–42 cue is elsewhere).
        XCTAssertEqual(c[2].translation, "")
        XCTAssertEqual(c[3].translation, "")
    }

    func testBelowThresholdOverlapIsNotPaired() {
        // Overlap 0.4 s of a 2 s cue = 20% < 50% → no pairing.
        let far = Track(name: "FR", language: "fr",
                        subtitles: [cue(2.6, 4.6, "Trop tard.")])
        let one = Track(name: "EN", language: "en",
                        subtitles: [cue(1, 3, "Hello.")])
        let c = cues(CCSLGenerator.rows(primary: one, secondary: far))
        XCTAssertEqual(c[0].translation, "")
    }

    // MARK: Cue fields

    func testCueFieldsAndFlagAnnotations() {
        let rows = CCSLGenerator.rows(primary: primary)
        let c = cues(rows)
        XCTAssertEqual(c[0].index, 1)
        XCTAssertEqual(c[0].timecodeIn, "00:00:01:00")
        XCTAssertEqual(c[0].timecodeOut, "00:00:03:00")
        XCTAssertEqual(c[0].duration, "00:00:02:00")
        XCTAssertEqual(c[0].speaker, "ANNA")
        // Lines joined with " / ".
        XCTAssertEqual(c[1].dialogue, "Hi! / Come in.")
        // Conventional annotations from flags.
        XCTAssertEqual(c[2].dialogue, "Much later. (V.O.)")
        XCTAssertEqual(c[3].dialogue, "The end. [MUSIC]")
    }

    func testFlagAnnotationsCanBeDisabled() {
        let options = CCSLGenerator.Options(includeFlagAnnotations: false)
        let c = cues(CCSLGenerator.rows(primary: primary, options: options))
        XCTAssertEqual(c[2].dialogue, "Much later.")
        XCTAssertEqual(c[3].dialogue, "The end.")
    }

    func testForcedFlagAnnotation() {
        let track = Track(name: "EN", language: "en",
                          subtitles: [cue(1, 3, "Sign text", isForced: true)])
        let c = cues(CCSLGenerator.rows(primary: track))
        XCTAssertEqual(c[0].dialogue, "Sign text [FN]")
    }

    // MARK: Scene grouping

    func testNoSignalsMeansSingleGroupWithoutHeaders() {
        // No shot changes, no isNewScene flags → no scene headers at all.
        let rows = CCSLGenerator.rows(primary: primary, shotChanges: nil)
        XCTAssertTrue(headers(rows).isEmpty)
        XCTAssertEqual(cues(rows).count, 4)
    }

    func testShotChangeInLongGapBreaksScene() {
        // Shot change at 15 s falls in the 10 s gap (6–20 s) → two scenes.
        let rows = CCSLGenerator.rows(primary: primary, shotChanges: [15.0])
        let h = headers(rows)
        XCTAssertEqual(h.count, 2)
        XCTAssertTrue(h[0].contains("1"))
        XCTAssertTrue(h[0].contains("00:00:01:00"))
        XCTAssertTrue(h[0].contains("00:00:06:00"))
        XCTAssertTrue(h[1].contains("2"))
        XCTAssertTrue(h[1].contains("00:00:20:00"))
        XCTAssertTrue(h[1].contains("00:00:26:00"))
        // Header, 2 cues, header, 2 cues.
        XCTAssertEqual(rows.count, 6)
        if case .sceneHeader = rows[0] {} else { XCTFail("Expected leading scene header") }
        if case .sceneHeader = rows[3] {} else { XCTFail("Expected second scene header") }
    }

    func testShotChangeInShortGapDoesNotBreakScene() {
        // Shot change at 3.5 s: the 1 s gap (3–4 s) is below the 5 s minimum.
        let rows = CCSLGenerator.rows(primary: primary, shotChanges: [3.5])
        XCTAssertTrue(headers(rows).isEmpty)
    }

    func testIsNewSceneFlagBreaksSceneWithoutShotChanges() {
        var track = primary
        track.subtitles[1].isNewScene = true
        let rows = CCSLGenerator.rows(primary: track)
        let h = headers(rows)
        XCTAssertEqual(h.count, 2)
        // Scene 2 starts at the flagged cue (4 s).
        XCTAssertTrue(h[1].contains("00:00:04:00"))
    }

    func testBothSignalsAreORed() {
        // isNewScene on cue 2 + shot change in the 10 s gap → three scenes.
        var track = primary
        track.subtitles[1].isNewScene = true
        let rows = CCSLGenerator.rows(primary: track, shotChanges: [15.0])
        XCTAssertEqual(headers(rows).count, 3)
    }

    func testGroupingDisabledByOption() {
        let options = CCSLGenerator.Options(groupScenes: false)
        let rows = CCSLGenerator.rows(primary: primary, shotChanges: [15.0], options: options)
        XCTAssertTrue(headers(rows).isEmpty)
    }

    // MARK: CSV

    func testCSVEscapingAndLayout() {
        let track = Track(name: "EN", language: "en", subtitles: [
            cue(1, 3, "Hello, world", speaker: "AN\"NA"),
        ])
        let csv = CCSLGenerator.csv(rows: CCSLGenerator.rows(primary: track),
                                    includeSpeaker: true, includeTranslation: false)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "No.,TC In,TC Out,Duration,Speaker,Dialogue")
        // Comma-carrying field quoted; embedded quote doubled (RFC 4180).
        XCTAssertTrue(lines[1].contains("\"Hello, world\""))
        XCTAssertTrue(lines[1].contains("\"AN\"\"NA\""))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testCSVSceneHeaderKeepsColumnCount() {
        let csv = CCSLGenerator.csv(rows: CCSLGenerator.rows(primary: primary, shotChanges: [15.0]),
                                    includeSpeaker: true, includeTranslation: false)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        // header + 2 scene headers + 4 cues
        XCTAssertEqual(lines.count, 7)
        let sceneLine = lines[1]
        XCTAssertEqual(sceneLine.filter { $0 == "," }.count, 5,
                       "Scene rows must keep the 6-column layout")
    }

    // MARK: HTML

    func testHTMLRowCountAndEscaping() {
        var track = primary
        track.subtitles[0].textBlocks = [TextBlock(plainText: "1 < 2 & so")]
        let html = CCSLGenerator.html(rows: CCSLGenerator.rows(primary: track, shotChanges: [15.0]),
                                      includeSpeaker: true, includeTranslation: false)
        // 1 thead row + 2 scene rows + 4 cue rows.
        XCTAssertEqual(html.components(separatedBy: "<tr").count - 1, 7)
        XCTAssertEqual(html.components(separatedBy: "class=\"scene\"").count - 1, 2)
        XCTAssertTrue(html.contains("1 &lt; 2 &amp; so"))
        XCTAssertTrue(html.contains("<th>Dialogue</th>"))
        XCTAssertFalse(html.contains("<th>Translation</th>"))
    }

    func testHTMLIncludesTranslationColumnWhenPaired() {
        let html = CCSLGenerator.html(rows: CCSLGenerator.rows(primary: primary, secondary: secondary),
                                      includeSpeaker: true, includeTranslation: true)
        XCTAssertTrue(html.contains("<th>Translation</th>"))
        XCTAssertTrue(html.contains("<td>Bonjour.</td>"))
    }

    // MARK: DOCX (inner document.xml)

    func testDOCXDocumentXMLContainsCells() {
        let rows = CCSLGenerator.rows(primary: primary, secondary: secondary, shotChanges: [15.0])
        let xml = CCSLGenerator.documentXML(rows: rows, title: "My Film",
                                            includeSpeaker: true, includeTranslation: true)
        XCTAssertTrue(xml.contains("My Film"))
        XCTAssertTrue(xml.contains("<w:tbl>"))
        XCTAssertTrue(xml.contains(">00:00:01:00</w:t>"))
        XCTAssertTrue(xml.contains(">ANNA</w:t>"))
        XCTAssertTrue(xml.contains(">Hi! / Come in.</w:t>"))
        XCTAssertTrue(xml.contains(">Bonjour.</w:t>"))
        XCTAssertTrue(xml.contains("Much later. (V.O.)"))
        // Scene header spans all 7 columns.
        XCTAssertTrue(xml.contains("<w:gridSpan w:val=\"7\"/>"))
        // XML escaping of cue text.
        var track = primary
        track.subtitles[0].textBlocks = [TextBlock(plainText: "1 < 2 & so")]
        let escaped = CCSLGenerator.documentXML(rows: CCSLGenerator.rows(primary: track),
                                                title: "", includeSpeaker: true,
                                                includeTranslation: false)
        XCTAssertTrue(escaped.contains("1 &lt; 2 &amp; so"))
    }

    func testDOCXArchiveStartsWithZipSignature() throws {
        let rows = CCSLGenerator.rows(primary: primary)
        let data = try CCSLGenerator.docx(rows: rows, title: "T",
                                          includeSpeaker: true, includeTranslation: false)
        XCTAssertGreaterThan(data.count, 4)
        XCTAssertEqual([UInt8](data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
    }

    func testEmptyTrackYieldsNoRows() {
        let empty = Track(name: "EN", language: "en", subtitles: [])
        XCTAssertTrue(CCSLGenerator.rows(primary: empty).isEmpty)
    }
}
