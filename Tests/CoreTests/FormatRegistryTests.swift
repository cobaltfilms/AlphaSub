import XCTest
import AlphaSubCore

final class FormatRegistryTests: XCTestCase {

    func testRegistrySharedIsPopulated() {
        let registry = FormatRegistry.shared
        XCTAssertNotNil(registry.importer(for: .srt),
            "Shared registry should have SRT importer after registerAllFormats()")
        XCTAssertNotNil(registry.exporter(for: .srt),
            "Shared registry should have SRT exporter after registerAllFormats()")
    }

    func testFormatImporterRegistration() {
        let registry = FormatRegistry.shared
        registry.registerImporter(MockImporter.self)
        let found = registry.importer(for: .srt)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.formatID, .srt)
    }

    func testDetectFormat() {
        let registry = FormatRegistry.shared
        registry.registerImporter(MockImporter.self)
        let srtData = "1\n00:00:01,000 --> 00:00:03,000\nHello\n".data(using: .utf8)!
        let detected = registry.detectFormat(from: srtData)
        XCTAssertNotNil(detected)
    }
}

// MARK: - Mock Importer for Testing

struct MockImporter: FormatImporter {
    static let formatID = FormatID.srt
    static let formatName = "Mock SRT"
    static let fileExtensions = ["srt"]

    static func canImport(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8) else { return false }
        return Int(str.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? "") != nil
    }

    static func `import`(_ data: Data, options: ImportOptions?) throws -> [Track] {
        return [Track(name: "Mock", language: "en", subtitles: [])]
    }
}
