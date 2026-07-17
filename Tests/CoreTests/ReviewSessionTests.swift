import XCTest
@testable import AlphaSubCore

final class ReviewSessionTests: XCTestCase {

    // MARK: - Helpers

    private func makeCue(_ startSeconds: Double, _ endSeconds: Double,
                         text: String, fr: FrameRate = .fps25) -> Subtitle {
        Subtitle(startTime: Timecode.fromSeconds(startSeconds, frameRate: fr),
                 endTime: Timecode.fromSeconds(endSeconds, frameRate: fr),
                 textBlocks: [TextBlock(plainText: text)])
    }

    private func makeTrack() -> Track {
        Track(name: "Main", subtitles: [
            makeCue(10, 12, text: "First cue"),
            makeCue(15, 18, text: "Second cue"),
            makeCue(18, 21, text: "Third cue"),
        ])
    }

    private func makeSessions() -> [ReviewSession] {
        let track = makeTrack()
        return [
            ReviewSession(
                startedAt: Date(timeIntervalSince1970: 1_750_000_000),
                name: "Reel 1 pass",
                notes: [
                    ReviewNote(timecodeSeconds: 16.0, kind: .flag,
                               cueID: track.subtitles[1].id),
                    ReviewNote(timecodeSeconds: 11.0, kind: .text,
                               text: "Comma, then \"quote\"",
                               cueID: track.subtitles[0].id, resolved: true),
                    ReviewNote(timecodeSeconds: 30.0, kind: .star),
                ]),
        ]
    }

    // MARK: - featureMetadata round-trip

    func testRoundTripThroughFeatureMetadata() throws {
        var doc = SubtitleDocument(tracks: [makeTrack()])
        let sessions = makeSessions()

        ReviewSessionStore.write(sessions, to: &doc)
        XCTAssertNotNil(doc.featureMetadata?[ReviewSessionStore.featureMetadataKey])

        // Full document encode/decode (the native project format).
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(SubtitleDocument.self, from: data)

        let restored = ReviewSessionStore.sessions(in: decoded)
        XCTAssertEqual(restored, sessions)
        XCTAssertEqual(restored[0].notes.count, 3)
        XCTAssertEqual(restored[0].notes[1].text, "Comma, then \"quote\"")
        XCTAssertTrue(restored[0].notes[1].resolved)
        XCTAssertEqual(restored[0].notes[0].cueID, sessions[0].notes[0].cueID)
    }

    func testWritePreservesUnknownFeatureMetadataKeys() throws {
        var doc = SubtitleDocument()
        let aiPayload = Data("ai-revision-log".utf8)
        doc.featureMetadata = ["ai": aiPayload]

        let sessions = makeSessions()
        ReviewSessionStore.write(sessions, to: &doc)
        XCTAssertEqual(doc.featureMetadata?["ai"], aiPayload,
                       "Writing review sessions must not clobber other feature keys")

        // And survive a document round-trip alongside the sessions.
        let decoded = try JSONDecoder().decode(
            SubtitleDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(decoded.featureMetadata?["ai"], aiPayload)
        XCTAssertEqual(ReviewSessionStore.sessions(in: decoded), sessions)
    }

    func testWritingEmptySessionsRemovesOnlyTheReviewKey() {
        var doc = SubtitleDocument()
        doc.featureMetadata = ["ai": Data([1, 2, 3])]
        ReviewSessionStore.write(makeSessions(), to: &doc)
        ReviewSessionStore.write([], to: &doc)
        XCTAssertNil(doc.featureMetadata?[ReviewSessionStore.featureMetadataKey])
        XCTAssertEqual(doc.featureMetadata?["ai"], Data([1, 2, 3]))

        // A document that never had feature metadata stays without it.
        var fresh = SubtitleDocument()
        ReviewSessionStore.write([], to: &fresh)
        XCTAssertNil(fresh.featureMetadata)
    }

    func testSessionsInDocumentWithoutMetadataIsEmpty() {
        XCTAssertEqual(ReviewSessionStore.sessions(in: SubtitleDocument()), [])
    }

    // MARK: - Cue resolution under the playhead

    func testCueIDResolution() {
        let track = makeTrack()

        // Inside a cue.
        XCTAssertEqual(ReviewSessionStore.cueID(atTimecodeSeconds: 11.0, in: track),
                       track.subtitles[0].id)
        // Exactly on an in-point → that cue.
        XCTAssertEqual(ReviewSessionStore.cueID(atTimecodeSeconds: 15.0, in: track),
                       track.subtitles[1].id)
        // On a shared boundary (cue 2 out == cue 3 in) → the incoming cue,
        // matching what is on screen.
        XCTAssertEqual(ReviewSessionStore.cueID(atTimecodeSeconds: 18.0, in: track),
                       track.subtitles[2].id)
        // In a gap between cues → nil.
        XCTAssertNil(ReviewSessionStore.cueID(atTimecodeSeconds: 13.0, in: track))
        // Before the first / after the last cue → nil.
        XCTAssertNil(ReviewSessionStore.cueID(atTimecodeSeconds: 2.0, in: track))
        XCTAssertNil(ReviewSessionStore.cueID(atTimecodeSeconds: 25.0, in: track))
        // No track at all → nil.
        XCTAssertNil(ReviewSessionStore.cueID(atTimecodeSeconds: 11.0, in: nil))
    }

    // MARK: - CSV change list

    func testCSVExportContent() {
        let track = makeTrack()
        var sessions = makeSessions()
        // Re-point the notes at the actual track cues (makeSessions built its
        // own track instance with different IDs).
        sessions[0].notes[0].cueID = track.subtitles[1].id
        sessions[0].notes[1].cueID = track.subtitles[0].id

        let csv = ReviewNotesReport.csv(sessions: sessions, track: track, frameRate: .fps25)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 4)   // header + 3 notes
        XCTAssertEqual(lines[0], "Session,Timecode,Kind,Cue text,Note,Resolved")

        // Notes are sorted by timecode: 11s (text), 16s (flag), 30s (star).
        XCTAssertEqual(
            lines[1],
            "Reel 1 pass,00:00:11:00,Note,First cue,\"Comma, then \"\"quote\"\"\",yes",
            "Commas and quotes must be RFC-4180 escaped")
        XCTAssertEqual(lines[2], "Reel 1 pass,00:00:16:00,Flag,Second cue,,no")
        // Star note had no cue under the playhead → empty cue cell.
        XCTAssertEqual(lines[3], "Reel 1 pass,00:00:30:00,Star,,,no")
    }

    func testCSVResolvesCueTextFromCurrentTrackState() {
        var track = makeTrack()
        let session = ReviewSession(
            startedAt: Date(), name: "Pass",
            notes: [ReviewNote(timecodeSeconds: 16, kind: .flag,
                               cueID: track.subtitles[1].id)])
        // The cue text is looked up at export time, so edits after capture
        // are reflected.
        track.subtitles[1].textBlocks = [TextBlock(plainText: "Edited\nline")]
        let rows = ReviewNotesReport.rows(sessions: [session], track: track, frameRate: .fps25)
        XCTAssertEqual(rows[0][3], "Edited line", "Newlines flatten to spaces in the cue cell")

        // A deleted cue degrades to an empty cue cell, not a crash.
        track.subtitles.remove(at: 1)
        let rows2 = ReviewNotesReport.rows(sessions: [session], track: track, frameRate: .fps25)
        XCTAssertEqual(rows2[0][3], "")
    }
}
