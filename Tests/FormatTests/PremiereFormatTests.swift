import XCTest
import AlphaSubCore
@testable import AlphaSubFormats

/// Regression coverage for the FCP7 / Premiere `xmeml` importer + exporter.
/// The original importer read `<start>`/`<end>` as attributes (they're child
/// elements), ignored the sequence `<timebase>` (assuming 25 fps), and lost
/// `&#xd;` line breaks — so real FCP7 files imported as nothing.
final class PremiereFormatTests: XCTestCase {

    /// A minimal FCP7 Text-generator sequence at 50 fps, mirroring the real file:
    /// timing in `<start>`/`<end>` child elements, text in the `str` parameter,
    /// a `&#xd;` line break, and an italic cue via `fontstyle=3`.
    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE xmeml>
    <xmeml version="5">
        <sequence>
            <name>Majapahit Subs</name>
            <rate><timebase>50</timebase><ntsc>FALSE</ntsc></rate>
            <media><video><track>
                <generatoritem id="Text 0">
                    <start>5866</start>
                    <end>5984</end>
                    <effect>
                        <effectid>Text</effectid>
                        <effecttype>generator</effecttype>
                        <parameter><parameterid>str</parameterid><name>Text</name><value>For years, we tried to understand.</value></parameter>
                        <parameter><parameterid>fontalign</parameterid><name>Alignment</name><value>2</value></parameter>
                    </effect>
                </generatoritem>
                <generatoritem id="Text 1">
                    <start>5992</start>
                    <end>6142</end>
                    <effect>
                        <effectid>Text</effectid>
                        <effecttype>generator</effecttype>
                        <parameter><parameterid>str</parameterid><name>Text</name><value>We replayed the days&#xd;leading up to it.</value></parameter>
                        <parameter><parameterid>fontstyle</parameterid><name>Style</name><value>3</value></parameter>
                    </effect>
                </generatoritem>
            </track></video></media>
        </sequence>
    </xmeml>
    """

    func testImportsFCP7TextGenerators() throws {
        let data = sample.data(using: .utf8)!
        XCTAssertTrue(PremiereImporter.canImport(data))

        let tracks = try PremiereImporter.import(data)
        XCTAssertEqual(tracks.count, 1)
        let subs = tracks[0].subtitles
        XCTAssertEqual(subs.count, 2)

        // Timing uses the sequence's 50 fps timebase: 5866/50 = 117.32s.
        XCTAssertEqual(subs[0].startTime.seconds, 117.32, accuracy: 0.02)
        XCTAssertEqual(subs[0].endTime.seconds, 5984.0 / 50.0, accuracy: 0.02)
        XCTAssertEqual(tracks[0].frameRate, .fps50)

        XCTAssertEqual(subs[0].plainText, "For years, we tried to understand.")

        // &#xd; line break splits into two text blocks; fontstyle=3 → italic.
        XCTAssertEqual(subs[1].textBlocks.count, 2)
        XCTAssertEqual(subs[1].plainText, "We replayed the days\nleading up to it.")
        XCTAssertTrue(subs[1].textBlocks.allSatisfy { $0.segments.allSatisfy { $0.style.contains(.italic) } })
    }

    func testRoundTripPreservesTimingTextAndStyle() throws {
        let tracks = try PremiereImporter.import(sample.data(using: .utf8)!)
        let out = try PremiereExporter.export(tracks, options: ExportOptions(sourceFrameRate: .fps50))

        // Exporter emits real Text generators with child-element timing + entity break.
        let str = String(data: out, encoding: .utf8)!
        XCTAssertTrue(str.contains("<effectid>Text</effectid>"))
        XCTAssertTrue(str.contains("<parameterid>str</parameterid>"))
        XCTAssertTrue(str.contains("&#xd;"))
        XCTAssertTrue(str.contains("<start>"))

        let back = try PremiereImporter.import(out)[0].subtitles
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].startTime.seconds, tracks[0].subtitles[0].startTime.seconds, accuracy: 0.02)
        XCTAssertEqual(back[1].plainText, "We replayed the days\nleading up to it.")
        XCTAssertTrue(back[1].textBlocks[0].segments[0].style.contains(.italic))
    }
}
