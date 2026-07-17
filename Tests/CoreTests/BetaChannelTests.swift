import XCTest
@testable import AlphaSubCore

final class VersionComparisonTests: XCTestCase {

    func testStableNewerThanOlderStable() {
        XCTAssertTrue(VersionComparator.isNewer("1.0.0", than: "0.9.9"))
    }

    func testStableNewerThanPrerelease() {
        XCTAssertTrue(VersionComparator.isNewer("1.0.0", than: "1.0.0b1"))
    }

    func testPrereleaseNewerThanOlderPrerelease() {
        XCTAssertTrue(VersionComparator.isNewer("1.0.0b2", than: "1.0.0b1"))
    }

    func testHigherBasePrereleaseNewerThanLowerBasePrerelease() {
        XCTAssertTrue(VersionComparator.isNewer("1.0.1b1", than: "1.0.0b2"))
    }

    func testEqualVersionsNotNewer() {
        XCTAssertFalse(VersionComparator.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(VersionComparator.isNewer("1.0.0b1", than: "1.0.0b1"))
    }

    func testPrereleaseNotNewerThanStableSameBase() {
        XCTAssertFalse(VersionComparator.isNewer("1.0.0b3", than: "1.0.0"))
    }

    func testOlderStableNotNewer() {
        XCTAssertFalse(VersionComparator.isNewer("0.9.9", than: "1.0.0"))
    }

    // MARK: shouldOfferUpdate (channel-switch behaviour)

    /// The regression this fixes: a stable 1.0.1 user switching to the beta
    /// channel must be offered the beta build even though 1.0.1b1 is not
    /// "newer" than 1.0.1. A routine check must NOT offer it.
    func testChannelSwitchOffersSameBasePrerelease() {
        XCTAssertTrue(VersionComparator.shouldOfferUpdate(
            candidate: "1.0.1b1", current: "1.0.1", crossChannel: true))
        XCTAssertFalse(VersionComparator.shouldOfferUpdate(
            candidate: "1.0.1b1", current: "1.0.1", crossChannel: false))
    }

    /// Switching back to stable from a beta offers the stable build too.
    func testChannelSwitchOffersStableFromBeta() {
        XCTAssertTrue(VersionComparator.shouldOfferUpdate(
            candidate: "1.0.1", current: "1.0.1b1", crossChannel: true))
    }

    /// Switching to a channel you are already on (same build) offers nothing.
    func testChannelSwitchToSameBuildOffersNothing() {
        XCTAssertFalse(VersionComparator.shouldOfferUpdate(
            candidate: "1.0.1b1", current: "1.0.1b1", crossChannel: true))
    }

    /// A routine check still offers a genuinely newer build on either path.
    func testRoutineCheckStillOffersNewer() {
        XCTAssertTrue(VersionComparator.shouldOfferUpdate(
            candidate: "1.0.2", current: "1.0.1", crossChannel: false))
        XCTAssertTrue(VersionComparator.shouldOfferUpdate(
            candidate: "1.0.2b1", current: "1.0.1b1", crossChannel: true))
    }
}

final class DocumentCompatibilityTests: XCTestCase {

    func testBaseDocumentVersionIsOne() {
        let doc = SubtitleDocument()
        XCTAssertEqual(doc.version, 1)
        XCTAssertEqual(doc.requiredVersion, 1)
        XCTAssertTrue(doc.isOpenableByCurrentBuild)
    }

    func testRequiredVersionNeverRaisesForCurrentFeatures() {
        var doc = SubtitleDocument(tracks: [
            Track(name: "Test", subtitles: [
                Subtitle(startTime: .zero, endTime: .zero, textBlocks: [TextBlock(plainText: "Hello")])
            ])
        ])
        doc.version = doc.requiredVersion
        XCTAssertEqual(doc.version, 1)
    }

    func testFeatureMetadataRoundTrip() throws {
        var doc = SubtitleDocument()
        doc.featureMetadata = ["ai": Data("{\"revisions\":[]}".utf8)]

        let data = try JSONEncoder().encode(doc)
        let restored = try JSONDecoder().decode(SubtitleDocument.self, from: data)
        XCTAssertEqual(restored.featureMetadata?["ai"], doc.featureMetadata?["ai"])
    }

    func testIsAIFlagRoundTrip() throws {
        let sub = Subtitle(startTime: .zero, endTime: .zero, textBlocks: [TextBlock(plainText: "AI")], isAI: true)
        let track = Track(name: "Test", subtitles: [sub])
        let doc = SubtitleDocument(tracks: [track])

        let data = try JSONEncoder().encode(doc)
        let restored = try JSONDecoder().decode(SubtitleDocument.self, from: data)
        XCTAssertTrue(restored.tracks[0].subtitles[0].isAI)
    }

    func testIsAIFlagOnSubtitle() {
        let aiSub = Subtitle(startTime: .zero, endTime: .zero, textBlocks: [TextBlock(plainText: "AI")], isAI: true)
        XCTAssertTrue(aiSub.isAI)
    }

    /// Reproduces the 0.9.9 → 1.0.0 break: a project saved before `isAI` existed
    /// has no `"isAI"` key, which the synthesized decoder rejected. We encode a
    /// real cue, strip the key (simulating an old file), and confirm the
    /// tolerant decoder defaults it to `false` instead of throwing `keyNotFound`.
    func testDecodesSubtitleMissingIsAIKey() throws {
        let sub = Subtitle(startTime: .zero, endTime: Timecode(totalFrames: 25, frameRate: .fps25),
                           textBlocks: [TextBlock(plainText: "Legacy")])
        let stripped = try encodeStrippingKeys(sub, keys: ["isAI"])
        let decoded = try JSONDecoder().decode(Subtitle.self, from: stripped)
        XCTAssertFalse(decoded.isAI)
        XCTAssertEqual(decoded.startTime, .zero)
        XCTAssertEqual(decoded.plainText, "Legacy")
    }

    /// Every flag absent — only the genuinely required timing remains — must
    /// still decode, falling back to model defaults.
    func testDecodesSubtitleWithOnlyRequiredFields() throws {
        let sub = Subtitle(startTime: .zero, endTime: Timecode(totalFrames: 50, frameRate: .fps25))
        let stripped = try encodeStrippingKeys(sub, keys: [
            "id", "textBlocks", "verticalPosition", "horizontalPosition", "alignment",
            "useCustomPosition", "isForced", "isMusic", "isOffSpeech", "isNewScene",
            "hasRevision", "isAI", "speaker",
        ])
        let decoded = try JSONDecoder().decode(Subtitle.self, from: stripped)
        XCTAssertFalse(decoded.isAI)
        XCTAssertFalse(decoded.isForced)
        XCTAssertEqual(decoded.alignment, .center)
        XCTAssertTrue(decoded.textBlocks.isEmpty)
    }

    /// AlphaSub's native project format encodes the whole `SubtitleDocument`.
    /// A document written before `isAI` existed must still open as a whole.
    func testDecodesLegacyDocumentWithoutIsAI() throws {
        let doc = SubtitleDocument(tracks: [
            Track(name: "Legacy", subtitles: [
                Subtitle(startTime: .zero, endTime: Timecode(totalFrames: 25, frameRate: .fps25))
            ])
        ])
        // Encode, then delete every subtitle's "isAI" key to mimic an old file.
        let data = try JSONEncoder().encode(doc)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var tracks = obj["tracks"] as! [[String: Any]]
        var subs = tracks[0]["subtitles"] as! [[String: Any]]
        subs[0].removeValue(forKey: "isAI")
        tracks[0]["subtitles"] = subs
        obj["tracks"] = tracks
        let stripped = try JSONSerialization.data(withJSONObject: obj)

        let restored = try JSONDecoder().decode(SubtitleDocument.self, from: stripped)
        XCTAssertEqual(restored.tracks.count, 1)
        XCTAssertFalse(restored.tracks[0].subtitles[0].isAI)
    }

    /// Encodes `value`, removes the given top-level keys from the JSON object,
    /// and returns the re-serialized data — a shape-agnostic way to simulate a
    /// file written by a build that predates those keys.
    private func encodeStrippingKeys<T: Encodable>(_ value: T, keys: [String]) throws -> Data {
        let data = try JSONEncoder().encode(value)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in keys { obj.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: obj)
    }
}
