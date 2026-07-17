import XCTest
@testable import AlphaSubCore

final class SecureModeTests: XCTestCase {

    private var originalValue = false
    private var tmpDir: URL!

    override func setUpWithError() throws {
        originalValue = SecureMode.isEnabled
        UserDefaults.standard.removeObject(forKey: SecureMode.defaultsKey)
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(originalValue, forKey: SecureMode.defaultsKey)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Enable Secure Mode via the raw defaults key (avoids the shared
    /// audit-log side effects of `setEnabled`).
    private func setSecureMode(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: SecureMode.defaultsKey)
    }

    // MARK: - Toggle persistence

    func testTogglePersistsToUserDefaults() {
        XCTAssertFalse(SecureMode.isEnabled)

        SecureMode.setEnabled(true)
        XCTAssertTrue(SecureMode.isEnabled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SecureMode.defaultsKey))

        SecureMode.setEnabled(false)
        XCTAssertFalse(SecureMode.isEnabled)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: SecureMode.defaultsKey))
    }

    func testTogglePostsNotification() {
        let expectation = expectation(
            forNotification: SecureMode.didChangeNotification, object: nil)
        SecureMode.setEnabled(true)
        wait(for: [expectation], timeout: 2)
        SecureMode.setEnabled(false)
    }

    func testBlockedMessageIsConsistent() {
        XCTAssertEqual(SecureMode.blockedMessage(feature: "Checking for updates"),
                       "Checking for updates is disabled in Secure Mode.")
    }

    // MARK: - Audit log chain

    private func makeLogWithEntries() throws -> URL {
        setSecureMode(true)
        let log = AuditLog(directory: tmpDir)
        log.record(.secureModeEnabled, detail: "Secure Mode turned on")
        log.record(.projectOpen, detail: "/Volumes/Media/feature.alphasub")
        log.record(.mediaLoad, detail: "/Volumes/Media/feature.mov")
        log.record(.subtitleImport, detail: "/Volumes/Media/feature_FR.srt")
        log.record(.subtitleExport, detail: "/Volumes/Media/out/feature.stl")
        log.record(.networkBlocked, detail: "https://example.com/appcast.json")
        log.flush()
        let files = log.sessionFileURLs()
        XCTAssertEqual(files.count, 1)
        return try XCTUnwrap(files.first)
    }

    func testAuditChainBuildsAndVerifies() throws {
        let file = try makeLogWithEntries()
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 6)
        // First entry chains from the genesis hash.
        XCTAssertTrue(lines[0].contains("\"prevHash\":\"\(AuditLog.genesisHash)\""))
        XCTAssertTrue(AuditLog.verifyChain(fileURL: file))
    }

    func testAuditLogRecordsNothingWhileDisabled() throws {
        setSecureMode(false)
        let log = AuditLog(directory: tmpDir)
        log.record(.projectOpen, detail: "/tmp/should-not-appear.alphasub")
        log.record(.networkBlocked, detail: "https://example.com")
        log.flush()
        XCTAssertTrue(log.sessionFileURLs().isEmpty)
    }

    func testTamperedEntryFailsVerification() throws {
        let file = try makeLogWithEntries()
        var lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        // Mutate a middle entry's payload (the file path of the media load).
        XCTAssertTrue(lines[2].contains("feature.mov"))
        lines[2] = lines[2].replacingOccurrences(of: "feature.mov", with: "tampered.mov")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(AuditLog.verifyChain(fileURL: file))
    }

    func testRemovedEntryFailsVerification() throws {
        let file = try makeLogWithEntries()
        var lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        lines.remove(at: 2)   // break the prevHash linkage
        try (lines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(AuditLog.verifyChain(fileURL: file))
    }

    func testExportHeaderReportsVerification() throws {
        _ = try makeLogWithEntries()
        let log = AuditLog(directory: tmpDir)
        let export = log.exportText()
        XCTAssertEqual(export.fileCount, 1)
        XCTAssertTrue(export.allVerified)
        XCTAssertTrue(export.text.hasPrefix("# AlphaSub Audit Log export"))
        XCTAssertTrue(export.text.contains("chain verification: PASSED"))
        // The exported text (headers + entries) is itself re-verifiable.
        XCTAssertTrue(AuditLog.verifyChain(text: export.text))
    }

    // MARK: - Blocking URLProtocol

    func testBlockingProtocolClaimsHTTPOnlyWhileEnabled() {
        let https = URLRequest(url: URL(string: "https://example.com/x")!)
        let http  = URLRequest(url: URL(string: "http://example.com/x")!)
        let file  = URLRequest(url: URL(fileURLWithPath: "/tmp/x"))

        setSecureMode(false)
        XCTAssertFalse(SecureModeBlockingProtocol.canInit(with: https))
        XCTAssertFalse(SecureModeBlockingProtocol.canInit(with: http))
        XCTAssertFalse(SecureModeBlockingProtocol.canInit(with: file))

        setSecureMode(true)
        XCTAssertTrue(SecureModeBlockingProtocol.canInit(with: https))
        XCTAssertTrue(SecureModeBlockingProtocol.canInit(with: http))
        XCTAssertFalse(SecureModeBlockingProtocol.canInit(with: file))
    }

    func testHardenInjectsProtocolFirst() {
        let config = SecureModeBlockingProtocol.harden(URLSessionConfiguration.ephemeral)
        let classes = config.protocolClasses ?? []
        XCTAssertTrue(classes.first == SecureModeBlockingProtocol.self)
        // Idempotent: hardening twice doesn't duplicate the entry.
        let again = SecureModeBlockingProtocol.harden(config)
        let count = (again.protocolClasses ?? [])
            .filter { $0 == SecureModeBlockingProtocol.self }.count
        XCTAssertEqual(count, 1)
    }
}
