import XCTest
import AlphaSubCore

/// Registry mechanics, tested with fixtures this target owns.
///
/// These used to assert that the *app's* formats were registered — which
/// AlphaSubCoreTests cannot establish, because `registerAllFormats()` lives in
/// AlphaSubFormats and this target only sees AlphaSubCore. The assertion could
/// therefore only pass by accident, when some other test class happened to run
/// first in the same process and populate the shared singleton; run this class
/// alone and it failed. That coverage now lives where it belongs, in
/// `FormatRegistryCompletenessTests` (AlphaSubAppTests), which calls both
/// registration halves itself.
final class FormatRegistryTests: XCTestCase {

    func testRegisteringAnImporterMakesItRetrievable() {
        let registry = FormatRegistry.shared
        registry.registerImporter(MockImporter.self)
        let found = registry.importer(for: .mockTestFormat)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.formatID, .mockTestFormat)
    }

    func testRegisteringAnExporterMakesItRetrievable() {
        let registry = FormatRegistry.shared
        registry.registerExporter(MockExporter.self)
        XCTAssertEqual(registry.exporter(for: .mockTestFormat)?.formatID, .mockTestFormat)
    }

    func testDetectFormatSniffsContent() {
        let registry = FormatRegistry.shared
        registry.registerImporter(MockImporter.self)
        let data = Data("MOCKFORMAT\nanything\n".utf8)
        XCTAssertEqual(registry.detectFormat(from: data)?.formatID, .mockTestFormat)
    }

    func testImporterLookupByExtension() {
        let registry = FormatRegistry.shared
        registry.registerImporter(MockImporter.self)
        XCTAssertEqual(registry.importer(forFileExtension: "mockfmt")?.formatID, .mockTestFormat)
        XCTAssertEqual(registry.importer(forFileExtension: "MOCKFMT")?.formatID, .mockTestFormat,
                       "extension matching is case-insensitive")
    }
}

// MARK: - Test fixtures

private extension FormatID {
    /// A format ID owned by this test file.
    ///
    /// It deliberately does NOT reuse `.srt`. `FormatRegistry` is a
    /// process-wide singleton with no reset, so registering a mock under a real
    /// format's ID replaced the genuine SRT importer for every test that ran
    /// afterwards in the same process — a fixture from one file quietly
    /// changing another file's subject under test.
    static let mockTestFormat = FormatID(rawValue: "mock_test_format")
}

private struct MockImporter: FormatImporter {
    static let formatID = FormatID.mockTestFormat
    static let formatName = "Mock Format"
    static let fileExtensions = ["mockfmt"]

    static func canImport(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8) else { return false }
        return str.hasPrefix("MOCKFORMAT")
    }

    static func `import`(_ data: Data, options: ImportOptions?) throws -> [Track] {
        [Track(name: "Mock", language: "en", subtitles: [])]
    }
}

private struct MockExporter: FormatExporter {
    static let formatID = FormatID.mockTestFormat
    static let formatName = "Mock Format"
    static let fileExtension = "mockfmt"

    static func export(_ tracks: [Track], options: ExportOptions?) throws -> Data {
        Data("MOCKFORMAT\n".utf8)
    }
}
