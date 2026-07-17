import XCTest
@testable import AlphaSubCore

/// Backward/forward compatibility of `MediaReference.shotChanges`:
/// old projects (no key) must decode, and `nil` must not be encoded so
/// older app versions can still open newer projects.
final class MediaReferenceShotChangesTests: XCTestCase {

    func testDecodesLegacyJSONWithoutShotChanges() throws {
        let legacy = """
        {"url":"file:///Users/someone/Movies/film.mp4","durationSeconds":5400.0}
        """.data(using: .utf8)!
        let ref = try JSONDecoder().decode(MediaReference.self, from: legacy)
        XCTAssertNil(ref.shotChanges)
        XCTAssertEqual(ref.durationSeconds, 5400.0)
    }

    func testNilShotChangesIsNotEncoded() throws {
        let ref = MediaReference(url: URL(fileURLWithPath: "/tmp/film.mp4"))
        let data = try JSONEncoder().encode(ref)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("shotChanges"),
                       "nil shotChanges must be omitted for forward compatibility")
    }

    func testShotChangesRoundTrip() throws {
        var ref = MediaReference(url: URL(fileURLWithPath: "/tmp/film.mp4"))
        ref.shotChanges = [1.0, 2.48, 120.96]
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(MediaReference.self, from: data)
        XCTAssertEqual(decoded.shotChanges, [1.0, 2.48, 120.96])
    }
}
