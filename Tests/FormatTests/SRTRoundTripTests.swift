import XCTest
@testable import AlphaSubCore
@testable import AlphaSubFormats

/// A self-contained SRT round-trip: build a document in code, export to SRT,
/// re-import, and assert the cues survive. No sample files required.
final class SRTRoundTripTests: XCTestCase {

    private func track() -> Track {
        Track(
            name: "T",
            language: "en",
            subtitles: [
                Subtitle(
                    startTime: Timecode(h: 0, m: 0, s: 1, f: 0, frameRate: .fps25),
                    endTime: Timecode(h: 0, m: 0, s: 3, f: 0, frameRate: .fps25),
                    textBlocks: [TextBlock(plainText: "Hello, world.")]
                ),
                Subtitle(
                    startTime: Timecode(h: 0, m: 0, s: 4, f: 12, frameRate: .fps25),
                    endTime: Timecode(h: 0, m: 0, s: 6, f: 0, frameRate: .fps25),
                    textBlocks: [TextBlock(plainText: "Second line\nwrapped.")]
                ),
            ]
        )
    }

    func testExportProducesSRT() throws {
        let data = try SRTExporter.export([track()], options: nil)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("Hello, world."))
        XCTAssertTrue(text.contains("-->"), "SRT must contain a timecode arrow")
        XCTAssertTrue(text.contains("00:00:01,000"), "start timecode in ms form")
    }

    func testRoundTripPreservesCueCountAndText() throws {
        let data = try SRTExporter.export([track()], options: nil)
        XCTAssertTrue(SRTImporter.canImport(data), "exported SRT should sniff as SRT")
        let tracks = try SRTImporter.import(data, options: nil)
        let cues = tracks.flatMap { $0.subtitles }
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues.first?.plainText, "Hello, world.")
        XCTAssertTrue(cues.last?.plainText.contains("wrapped.") ?? false)
    }
}
