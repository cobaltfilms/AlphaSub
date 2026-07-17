import XCTest
import AlphaSubCore
@testable import AlphaSubFormats

final class FCPXMLFormatTests: XCTestCase {

    // MARK: - Fixtures

    /// A minimal FCPXML 1.11 document with two titles on a 25 fps sequence.
    /// The sequence uses a 1/25s frameDuration so the importer can detect
    /// the frame rate; offsets are rational seconds on a 2400 timebase.
    private let sampleFCPXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <fcpxml version="1.11">
      <resources>
        <format id="r1" frameDuration="100/2500s" name="FFVideoFormat1080p25" width="1920" height="1080"/>
      </resources>
      <library>
        <event name="Subtitles">
          <project name="Test Project">
            <sequence format="r1" frameDuration="100/2500s" tcStart="0s">
              <spine>
                <title offset="100/2500s" duration="100/2500s" name="Title 1" ref="r1">
                  <param name="Alignment" value="2"/>
                  <text>
                    <text-style>Hello world</text-style>
                  </text>
                </title>
                <title offset="300/2500s" duration="100/2500s" name="Title 2" ref="r1">
                  <param name="Alignment" value="2"/>
                  <text>
                    <text-style>Second subtitle</text-style>
                  </text>
                </title>
              </spine>
            </sequence>
          </project>
        </event>
      </library>
    </fcpxml>
    """

    /// FCPXML with a multi-line title (newline inside the text-style run)
    /// and an italic-styled run, to exercise the text-block splitter and
    /// style mapping.
    private let multilineFCPXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <fcpxml version="1.11">
      <library>
        <event name="Subtitles">
          <project name="Multi Project">
            <sequence frameDuration="100/2500s" tcStart="0s">
              <spine>
                <title offset="100/2500s" duration="200/2500s" name="Multi" ref="r1">
                  <param name="Alignment" value="2"/>
                  <text>
                    <text-style>Line one\(FCPXMLFormatTests.newline)Line two</text-style>
                  </text>
                </title>
                <title offset="500/2500s" duration="100/2500s" name="Italic" ref="r1">
                  <param name="Alignment" value="2"/>
                  <text>
                    <text-style fontStyle="italic">Italic text</text-style>
                  </text>
                </title>
              </spine>
            </sequence>
          </project>
        </event>
      </library>
    </fcpxml>
    """

    /// Newline constant used to embed literal line breaks inside a Swift
    /// multi-line string literal without breaking the literal's indentation.
    private static let newline = "\n"

    // MARK: - canImport

    func testCanImportValidFCPXML() {
        let data = sampleFCPXML.data(using: .utf8)!
        XCTAssertTrue(FCPXMLImporter.canImport(data))
    }

    func testCannotImportSRT() {
        let srt = "1\n00:00:01,000 --> 00:00:04,000\nHello\n".data(using: .utf8)!
        XCTAssertFalse(FCPXMLImporter.canImport(srt))
    }

    func testCannotImportTTML() {
        let ttml = "<?xml version=\"1.0\"?><tt xmlns=\"http://www.w3.org/ns/ttml\"></tt>"
        XCTAssertFalse(FCPXMLImporter.canImport(ttml.data(using: .utf8)!))
    }

    // MARK: - Import

    func testImportSampleFCPXML() throws {
        let data = sampleFCPXML.data(using: .utf8)!
        let tracks = try FCPXMLImporter.import(data, options: ImportOptions(targetFrameRate: .fps25))

        XCTAssertEqual(tracks.count, 1)
        let track = tracks[0]
        XCTAssertEqual(track.name, "Test Project")
        XCTAssertEqual(track.formatOrigin, "fcpxml")
        XCTAssertEqual(track.subtitles.count, 2)

        let sub1 = track.subtitles[0]
        XCTAssertEqual(sub1.plainText, "Hello world")
        // offset 100/2500s = 0.04s = 1 frame at 25 fps
        XCTAssertEqual(sub1.startTime.totalFrames, 1)
        // duration 100/2500s = 1 frame; end = start + 1 = 2
        XCTAssertEqual(sub1.endTime.totalFrames, 2)

        let sub2 = track.subtitles[1]
        XCTAssertEqual(sub2.plainText, "Second subtitle")
        // offset 300/2500s = 0.12s = 3 frames at 25 fps
        XCTAssertEqual(sub2.startTime.totalFrames, 3)
        XCTAssertEqual(sub2.endTime.totalFrames, 4)
    }

    func testImportDetectsFrameRateFromSequence() throws {
        // 100/2400s frameDuration => 24 fps
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.11">
          <library>
            <event name="E">
              <project name="P">
                <sequence frameDuration="100/2400s" tcStart="0s">
                  <spine>
                    <title offset="2400/2400s" duration="2400/2400s" name="T">
                      <text><text-style>One second</text-style></text>
                    </title>
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>
        """
        let tracks = try FCPXMLImporter.import(xml.data(using: .utf8)!)
        XCTAssertEqual(tracks.count, 1)
        let sub = tracks[0].subtitles[0]
        XCTAssertEqual(sub.startTime.frameRate, .fps24)
        // 2400/2400s = 1 second = 24 frames at 24 fps
        XCTAssertEqual(sub.startTime.totalFrames, 24)
        XCTAssertEqual(sub.endTime.totalFrames, 48)
    }

    func testImportMultilineTitle() throws {
        let data = multilineFCPXML.data(using: .utf8)!
        let tracks = try FCPXMLImporter.import(data, options: ImportOptions(targetFrameRate: .fps25))
        XCTAssertEqual(tracks.count, 1)
        let subs = tracks[0].subtitles
        XCTAssertEqual(subs.count, 2)

        // The first title contains a newline -> two TextBlocks.
        XCTAssertEqual(subs[0].plainText, "Line one\nLine two")
        XCTAssertEqual(subs[0].textBlocks.count, 2, "Multiline title should split into two TextBlocks")
        XCTAssertEqual(subs[0].textBlocks[0].plainText, "Line one")
        XCTAssertEqual(subs[0].textBlocks[1].plainText, "Line two")

        // The second title is italic-styled.
        XCTAssertEqual(subs[1].plainText, "Italic text")
        XCTAssertTrue(subs[1].textBlocks[0].segments.contains { $0.style.contains(.italic) },
                      "Italic text-style should map to TextStyle.italic")
    }

    func testImportEmptyFCPXMLReturnsNoTracks() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.11">
          <library>
            <event name="Empty"/>
          </library>
        </fcpxml>
        """
        let tracks = try FCPXMLImporter.import(xml.data(using: .utf8)!)
        // The old stub returned a phantom empty track; the real importer
        // must return an empty array when there are no titles.
        XCTAssertTrue(tracks.isEmpty)
    }

    func testImportRejectsNonFCPXMLRoot() {
        let xml = "<?xml version=\"1.0\"?><tt xmlns=\"http://www.w3.org/ns/ttml\"></tt>"
        XCTAssertThrowsError(try FCPXMLImporter.import(xml.data(using: .utf8)!)) { error in
            guard case FormatError.invalidData = error else {
                XCTFail("Expected FormatError.invalidData, got \(error)")
                return
            }
        }
    }

    // MARK: - Export

    func testExportProducesValidFCPXML() throws {
        let track = Track(
            name: "Export Test",
            language: "en",
            subtitles: [
                Subtitle(
                    startTime: Timecode(totalFrames: 25, frameRate: .fps25),
                    endTime: Timecode(totalFrames: 50, frameRate: .fps25),
                    textBlocks: [TextBlock(plainText: "Exported cue")]
                )
            ],
            formatOrigin: "fcpxml"
        )
        let data = try FCPXMLExporter.export([track], options: ExportOptions(sourceFrameRate: .fps25))
        let str = String(data: data, encoding: .utf8)!
        XCTAssertTrue(str.contains("<fcpxml version=\"1.11\">"))
        // Subtitles export as <title> clips (the structure Resolve accepts), each
        // pushed into the lower third via <adjust-transform> so they aren't centred.
        XCTAssertTrue(str.contains("<title "))
        XCTAssertTrue(str.contains("<adjust-transform position=\"0 -400\"/>"))
        XCTAssertTrue(str.contains("Exported cue"))
        // Should be parseable as XML.
        let doc = try XMLDocument(xmlString: str, options: [])
        XCTAssertEqual(doc.rootElement()?.name, "fcpxml")
    }

    func testExportRoundTripsThroughImporter() throws {
        let original = Track(
            name: "Round Trip",
            language: "en",
            subtitles: [
                Subtitle(
                    startTime: Timecode(totalFrames: 25, frameRate: .fps25),
                    endTime: Timecode(totalFrames: 75, frameRate: .fps25),
                    textBlocks: [TextBlock(plainText: "First cue")]
                ),
                Subtitle(
                    startTime: Timecode(totalFrames: 100, frameRate: .fps25),
                    endTime: Timecode(totalFrames: 150, frameRate: .fps25),
                    textBlocks: [TextBlock(plainText: "Second cue")]
                ),
            ],
            formatOrigin: "fcpxml"
        )

        let data = try FCPXMLExporter.export([original], options: ExportOptions(sourceFrameRate: .fps25))
        let importedTracks = try FCPXMLImporter.import(data, options: ImportOptions(targetFrameRate: .fps25))

        XCTAssertEqual(importedTracks.count, 1)
        let imported = importedTracks[0]
        XCTAssertEqual(imported.subtitles.count, 2)

        // Text must round-trip exactly.
        XCTAssertEqual(imported.subtitles[0].plainText, "First cue")
        XCTAssertEqual(imported.subtitles[1].plainText, "Second cue")

        // Timing round-trips within one frame of precision (the 2400
        // timebase is an exact multiple of 25, so we expect exactness).
        XCTAssertEqual(imported.subtitles[0].startTime.totalFrames, 25)
        XCTAssertEqual(imported.subtitles[0].endTime.totalFrames, 75)
        XCTAssertEqual(imported.subtitles[1].startTime.totalFrames, 100)
        XCTAssertEqual(imported.subtitles[1].endTime.totalFrames, 150)
    }

    // MARK: - Rational time parsing

    func testParseRationalSeconds() {
        let value = FCPXMLImporter.parseRationalSecondsValue("3201/2400s")
        XCTAssertEqual(value ?? -1, 3201.0 / 2400.0, accuracy: 1e-9)
    }

    func testParsePlainSeconds() {
        let value = FCPXMLImporter.parseRationalSecondsValue("1.5s")
        XCTAssertEqual(value ?? -1, 1.5, accuracy: 1e-9)
    }

    func testParseInvalidRationalReturnsNil() {
        XCTAssertNil(FCPXMLImporter.parseRationalSecondsValue("abc"))
        XCTAssertNil(FCPXMLImporter.parseRationalSecondsValue("1/0s"))
        XCTAssertNil(FCPXMLImporter.parseRationalSecondsValue("1/2")) // missing 's'
    }

    // MARK: - Registration

    func testFCPXMLFormatIsRegistered() {
        // registerAllFormats() is called at app launch; in tests the
        // registry may already be populated. Verify the importer/exporter
        // are wired up.
        registerAllFormats()
        let registry = FormatRegistry.shared
        XCTAssertNotNil(registry.importer(for: .fcpxml))
        XCTAssertNotNil(registry.exporter(for: .fcpxml))
    }
}