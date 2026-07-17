import XCTest
@testable import AlphaSubCore

final class SeasonBibleTests: XCTestCase {

    // MARK: - Helpers

    private func cue(_ text: String) -> Subtitle {
        Subtitle(
            startTime: Timecode(totalFrames: 0, frameRate: .fps25),
            endTime: Timecode(totalFrames: 50, frameRate: .fps25),
            textBlocks: [TextBlock(plainText: text)])
    }

    private func track(_ texts: [String], language: String = "fr") -> Track {
        Track(name: "Test", language: LanguageCode(language),
              subtitles: texts.map(cue))
    }

    private func sargeBible(entries: [BibleEntry]? = nil) -> SeasonBible {
        SeasonBible(
            name: "Brooklyn 99",
            sourceLanguage: LanguageCode("en"),
            targetLanguage: LanguageCode("fr"),
            entries: entries ?? [
                BibleEntry(kind: .character, source: "Sarge", target: "Chef",
                           note: "established ep 1x01",
                           variants: ["Sergent", "le Sarge"])
            ],
            // Whole-second date: ISO8601 storage has second precision.
            modifiedAt: Date(timeIntervalSince1970: 1_750_000_000))
    }

    // MARK: - JSON round-trip

    func testJSONRoundTrip() throws {
        let bible = sargeBible()
        let data = try bible.encoded()
        let decoded = try SeasonBible.decode(from: data)
        XCTAssertEqual(decoded, bible)
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries[0].variants, ["Sergent", "le Sarge"])
        XCTAssertEqual(decoded.entries[0].note, "established ep 1x01")
        XCTAssertFalse(decoded.entries[0].caseSensitive)
    }

    func testDecodeToleratesMissingOptionalFields() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Minimal","entries":
        [{"source":"Sarge"}],"modifiedAt":"2026-01-01T00:00:00Z"}
        """
        let bible = try SeasonBible.decode(from: Data(json.utf8))
        XCTAssertEqual(bible.entries.count, 1)
        XCTAssertEqual(bible.entries[0].kind, .term)
        XCTAssertEqual(bible.entries[0].target, "")
        XCTAssertEqual(bible.entries[0].variants, [])
    }

    // MARK: - Variant matching

    func testVariantMatchProducesFinding() {
        let findings = sargeBible().check(track: track(["Le Sergent arrive."]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].matchedText, "Sergent")
        XCTAssertEqual(findings[0].expected, "Chef")
        XCTAssertEqual(findings[0].cueNumber, 1)
    }

    func testWordBoundaryRejectsSubstring() {
        // "Chefs" must NOT match an entry/variant "Chef" — and plural
        // "Sergents" must not match the variant "Sergent".
        let findings = sargeBible().check(track: track(["Les Sergents arrivent."]))
        XCTAssertTrue(findings.isEmpty)
    }

    func testWordBoundaryAcceptsPunctuationNeighbours() {
        let findings = sargeBible().check(track: track(["\u{2014} Sergent, viens ici !"]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].matchedText, "Sergent")
    }

    func testDiacriticInsensitiveMatch() {
        // Cue writes "Sérgent" (stray accent); variant is "Sergent".
        let findings = sargeBible().check(track: track(["Le Sérgent arrive."]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].matchedText, "Sérgent")
        XCTAssertEqual(findings[0].expected, "Chef")
    }

    func testCaseInsensitiveByDefault() {
        let findings = sargeBible().check(track: track(["LE SERGENT ARRIVE."]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].matchedText, "SERGENT")
    }

    func testCaseSensitiveEntryRespectsCase() {
        let entry = BibleEntry(kind: .term, source: "Sarge", target: "Chef",
                               variants: ["Sergent"], caseSensitive: true)
        let bible = sargeBible(entries: [entry])
        XCTAssertTrue(bible.check(track: track(["LE SERGENT ARRIVE."])).isEmpty)
        XCTAssertEqual(bible.check(track: track(["Le Sergent arrive."])).count, 1)
    }

    func testVariantEqualToTargetIsNeverFlagged() {
        // A (mis-entered) variant that folds to the target must not flag
        // correct text.
        let entry = BibleEntry(source: "Sarge", target: "Chef", variants: ["chef"])
        let findings = sargeBible(entries: [entry])
            .check(track: track(["Le Chef arrive."]))
        XCTAssertTrue(findings.isEmpty)
    }

    // MARK: - Untranslated-source rule

    func testUntranslatedSourceFlaggedOnTargetLanguageTrack() {
        let findings = sargeBible().check(track: track(["Sarge est là."], language: "fr"))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].matchedText, "Sarge")
        XCTAssertEqual(findings[0].expected, "Chef")
        XCTAssertTrue(findings[0].message.contains("untranslated"))
    }

    func testUntranslatedRuleInactiveOnSourceLanguageTrack() {
        // On an English (source-language) track, "Sarge" is correct.
        let findings = sargeBible().check(track: track(["Sarge is here."], language: "en"))
        XCTAssertTrue(findings.isEmpty)
    }

    func testUntranslatedRuleMatchesRegionalSubtag() {
        // fr-FR track matches the bible's target language "fr".
        let findings = sargeBible().check(track: track(["Sarge est là."], language: "fr-FR"))
        XCTAssertEqual(findings.count, 1)
    }

    func testUntranslatedRuleSkippedWhenTargetKeepsSourceTerm() {
        // Names that stay unchanged in translation must not be flagged.
        let entry = BibleEntry(kind: .character, source: "Sarge", target: "Sarge le Chef")
        let findings = sargeBible(entries: [entry])
            .check(track: track(["Sarge le Chef est là."], language: "fr"))
        XCTAssertTrue(findings.isEmpty)
    }

    func testSameLanguageBibleNeverRunsUntranslatedRule() {
        var bible = sargeBible()
        bible.sourceLanguage = LanguageCode("fr")
        bible.targetLanguage = LanguageCode("fr")
        let findings = bible.check(track: track(["Sarge est là."], language: "fr"))
        XCTAssertTrue(findings.isEmpty)
    }

    // MARK: - Multiple findings

    func testMultipleFindingsInOneCue() {
        // "Sergent" (wrong variant) + "Sarge" (untranslated) in one cue.
        let findings = sargeBible()
            .check(track: track(["Le Sergent parle à Sarge."], language: "fr"))
        XCTAssertEqual(findings.count, 2)
        XCTAssertEqual(Set(findings.map(\.matchedText)), ["Sergent", "Sarge"])
        // Both findings point at the same cue.
        XCTAssertEqual(Set(findings.map(\.cueID)).count, 1)
    }

    func testRepeatedVariantYieldsOneFindingPerOccurrence() {
        let findings = sargeBible()
            .check(track: track(["Sergent ! Sergent !"], language: "fr"))
        XCTAssertEqual(findings.count, 2)
        XCTAssertNotEqual(findings[0].range, findings[1].range)
    }

    // MARK: - Ranges and auto-fix

    func testFindingRangeLocatesMatchInPlainText() {
        let text = "Le Sergent arrive."
        let findings = sargeBible().check(track: track([text]))
        XCTAssertEqual(findings.count, 1)
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: findings[0].range), "Sergent")
    }

    func testFixedTextReplacesDrift() {
        let bible = sargeBible()
        XCTAssertEqual(
            bible.fixedText(for: "Le Sergent parle à Sarge.",
                            trackLanguage: LanguageCode("fr")),
            "Le Chef parle à Chef.")
        // Nothing to fix → unchanged.
        XCTAssertEqual(
            bible.fixedText(for: "Le Chef arrive.", trackLanguage: LanguageCode("fr")),
            "Le Chef arrive.")
    }

    // MARK: - Occurrence counting / merge

    func testOccurrenceCountIsWordBoundaryAware() {
        let t = track(["Sarge est là.", "Les Sarges.", "Oui, Sarge !"])
        XCTAssertEqual(SeasonBible.occurrenceCount(of: "Sarge", in: t), 2)
    }

    func testMergeSkipsKnownSourcesAndReportsAdded() {
        var bible = sargeBible()
        let added = bible.merge([
            BibleEntry(source: "sarge", target: "Chef"),         // dup (folded)
            BibleEntry(source: "Nine-Nine", target: "99e district"),
        ])
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0].source, "Nine-Nine")
        XCTAssertEqual(bible.entries.count, 2)
    }
}
