import Foundation
import CryptoKit

// MARK: - AuditLog

/// Hash-chained, append-only JSONL audit log for Secure Mode sessions.
///
/// While Secure Mode is enabled, one JSON object per line is appended to a
/// per-session file under `Application Support/AlphaSub/AuditLog/`:
///
///     {"ts":"…","event":"…","detail":"…","prevHash":"…","hash":"…"}
///
/// Each entry's `hash` is `SHA256(prevHash | ts | event | detail)`, and
/// `prevHash` is the previous entry's `hash` (the first entry chains from a
/// 64-zero genesis hash). Any edit, removal, or reordering of a line breaks
/// the chain, which ``verifyChain(fileURL:)`` detects.
///
/// Lines are written with a fixed key order and manual escaping so the hash
/// input is byte-stable and independent of `JSONEncoder` behavior.
public final class AuditLog: @unchecked Sendable {

    /// Process-wide log writing into ``defaultDirectory``.
    public static let shared = AuditLog(directory: AuditLog.defaultDirectory)

    /// `~/Library/Application Support/AlphaSub/AuditLog/`
    public static var defaultDirectory: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("AuditLog", isDirectory: true)
    }

    /// prevHash of the first entry in every session file.
    public static let genesisHash = String(repeating: "0", count: 64)

    /// Auditable event kinds.
    public enum Event: String, Sendable, CaseIterable {
        case secureModeEnabled  = "secure_mode_enabled"
        case secureModeDisabled = "secure_mode_disabled"
        case projectOpen        = "project_open"
        case projectSave        = "project_save"
        case mediaLoad          = "media_load"
        case subtitleImport     = "subtitle_import"
        case subtitleExport     = "subtitle_export"
        case networkBlocked     = "network_blocked"
    }

    public let directory: URL

    private let queue = DispatchQueue(label: "com.alphasub.auditlog")
    private var sessionFileURL: URL?
    private var lastHash = AuditLog.genesisHash

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Recording

    /// Append an entry to this session's chain. No-op while Secure Mode is
    /// off (except the disable event itself, which is written while the mode
    /// is still nominally transitioning off). Safe to call from any thread.
    public func record(_ event: Event, detail: String) {
        guard SecureMode.isEnabled || event == .secureModeDisabled else { return }
        let ts = Self.timestamp()
        queue.async { [self] in
            appendLocked(ts: ts, event: event, detail: detail)
        }
    }

    /// Block until every queued entry has been written to disk.
    public func flush() {
        queue.sync {}
    }

    private func appendLocked(ts: String, event: Event, detail: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = try sessionFileLocked()
            let hash = Self.entryHash(prevHash: lastHash, ts: ts,
                                      event: event.rawValue, detail: detail)
            let line = """
            {"ts":"\(Self.jsonEscape(ts))","event":"\(Self.jsonEscape(event.rawValue))","detail":"\(Self.jsonEscape(detail))","prevHash":"\(lastHash)","hash":"\(hash)"}\n
            """
            guard let data = line.data(using: .utf8) else { return }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            lastHash = hash
        } catch {
            // Auditing must never crash or block the app; a write failure
            // (full disk, sandbox) simply drops the entry.
        }
    }

    private func sessionFileLocked() throws -> URL {
        if let url = sessionFileURL { return url }
        let stamp = Self.fileStampFormatter.string(from: Date())
        let pid = ProcessInfo.processInfo.processIdentifier
        let url = directory.appendingPathComponent(
            "AlphaSub-Audit-\(stamp)-p\(pid).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        sessionFileURL = url
        return url
    }

    // MARK: Verification

    /// Recompute the whole chain of `fileURL` and check every link.
    /// Comment lines starting with `#` (export headers) are skipped, so an
    /// exported log can be re-verified. Returns true for an empty chain.
    public static func verifyChain(fileURL: URL) -> Bool {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return verifyChain(text: text)
    }

    /// Chain verification over in-memory text (one JSON object per line).
    /// A concatenated export restarts the chain at each genesis `prevHash`.
    public static func verifyChain(text: String) -> Bool {
        var prev = genesisHash
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ts = obj["ts"] as? String,
                  let event = obj["event"] as? String,
                  let detail = obj["detail"] as? String,
                  let prevHash = obj["prevHash"] as? String,
                  let hash = obj["hash"] as? String
            else { return false }
            // A fresh session file (concatenated export) restarts the chain.
            if prevHash == genesisHash {
                prev = genesisHash
            }
            guard prevHash == prev,
                  entryHash(prevHash: prevHash, ts: ts, event: event, detail: detail) == hash
            else { return false }
            prev = hash
        }
        return true
    }

    // MARK: Export

    /// All session files in ``directory``, sorted by name (i.e. by date).
    public func sessionFileURLs() -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Concatenate every session file, verifying each chain, and prefix a
    /// header line stating the overall verification result. The output is
    /// itself re-verifiable with ``verifyChain(fileURL:)``.
    public func exportText() -> (text: String, allVerified: Bool, fileCount: Int) {
        flush()
        let files = sessionFileURLs()
        var allVerified = true
        var body = ""
        for file in files {
            let verified = Self.verifyChain(fileURL: file)
            allVerified = allVerified && verified
            body += "# session file: \(file.lastPathComponent) — chain: \(verified ? "PASSED" : "FAILED")\n"
            body += ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            if !body.hasSuffix("\n") { body += "\n" }
        }
        let header = "# AlphaSub Audit Log export — \(Self.timestamp()) — "
            + "\(files.count) session file(s) — chain verification: "
            + "\(allVerified && !files.isEmpty ? "PASSED" : (files.isEmpty ? "EMPTY" : "FAILED"))\n"
        return (header + body, allVerified, files.count)
    }

    // MARK: Hashing / formatting

    /// `SHA256(prevHash | ts | event | detail)`, lowercase hex.
    public static func entryHash(prevHash: String, ts: String,
                                 event: String, detail: String) -> String {
        let payload = [prevHash, ts, event, detail].joined(separator: "|")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    /// Minimal JSON string escaping (quotes, backslashes, control characters).
    static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
