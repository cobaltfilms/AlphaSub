import XCTest
@testable import AlphaSubCore

final class TextColorTests: XCTestCase {

    // MARK: Hex parsing

    func testParseSixDigitHex() {
        let c = TextColor(hex: "#ffff00")
        XCTAssertEqual(c, .yellow)
        XCTAssertEqual(TextColor(hex: "FF0000"), .red)   // leading # optional
    }

    func testParseThreeDigitHex() {
        XCTAssertEqual(TextColor(hex: "#ff0"), .yellow)
        XCTAssertEqual(TextColor(hex: "#0ff"), .cyan)
    }

    func testParseEightDigitHexIgnoresAlpha() {
        XCTAssertEqual(TextColor(hex: "#00ff00cc"), .green)
    }

    func testParseInvalidHex() {
        XCTAssertNil(TextColor(hex: ""))
        XCTAssertNil(TextColor(hex: "#ff"))
        XCTAssertNil(TextColor(hex: "#ggg"))
        XCTAssertNil(TextColor(hex: "#12345"))
        XCTAssertNil(TextColor(hex: "yellow"))
    }

    func testHexString() {
        XCTAssertEqual(TextColor.yellow.hexString, "#ffff00")
        XCTAssertEqual(TextColor(r: 1, g: 2, b: 3).hexString, "#010203")
    }

    func testNamedColors() {
        XCTAssertEqual(TextColor(named: "Yellow"), .yellow)
        XCTAssertEqual(TextColor(named: "aqua"), .cyan)
        XCTAssertEqual(TextColor(named: "lime"), .green)
        XCTAssertNil(TextColor(named: "notacolor"))
    }

    func testClosestTeletextColor() {
        // Slightly off-yellow snaps to yellow.
        XCTAssertEqual(TextColor(r: 0xF0, g: 0xE8, b: 0x10).closestTeletextColor, .yellow)
        // Dark grey snaps to black, light grey to white.
        XCTAssertEqual(TextColor(r: 0x20, g: 0x20, b: 0x20).closestTeletextColor, .black)
        XCTAssertEqual(TextColor(r: 0xE0, g: 0xE0, b: 0xE0).closestTeletextColor, .white)
        // Exact teletext colours map to themselves.
        for c in TextColor.teletextColors {
            XCTAssertEqual(c.closestTeletextColor, c)
        }
    }

    // MARK: Codable compatibility

    func testSegmentWithColorRoundTrips() throws {
        let seg = TextSegment(text: "hi", style: .italic, color: .cyan)
        let data = try JSONEncoder().encode(seg)
        let back = try JSONDecoder().decode(TextSegment.self, from: data)
        XCTAssertEqual(back, seg)
        XCTAssertEqual(back.color, .cyan)
    }

    func testOldJSONWithoutColorDecodes() throws {
        // A segment written by an app version that predates `color`.
        let json = #"{"text":"legacy","style":1}"#
        let seg = try JSONDecoder().decode(TextSegment.self, from: Data(json.utf8))
        XCTAssertEqual(seg.text, "legacy")
        XCTAssertTrue(seg.style.contains(.italic))
        XCTAssertNil(seg.color)
    }

    func testColorlessSegmentEncodesWithoutColorKey() throws {
        let seg = TextSegment(text: "plain", style: [])
        let data = try JSONEncoder().encode(seg)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["color"], "colorless segments must stay byte-compatible with older versions")
        XCTAssertEqual(obj["text"] as? String, "plain")
    }

    func testSubtitleHasColor() {
        let start = Timecode(h: 0, m: 0, s: 0, f: 0, frameRate: .fps25)
        let end = Timecode(h: 0, m: 0, s: 2, f: 0, frameRate: .fps25)
        var sub = Subtitle(startTime: start, endTime: end,
                           textBlocks: [TextBlock(plainText: "hello")])
        XCTAssertFalse(sub.hasColor)
        sub.textBlocks = [TextBlock(segments: [
            TextSegment(text: "he"),
            TextSegment(text: "llo", color: .red),
        ])]
        XCTAssertTrue(sub.hasColor)
    }
}
