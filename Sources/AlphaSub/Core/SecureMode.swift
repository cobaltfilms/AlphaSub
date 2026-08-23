import Foundation

// MARK: - SecureMode

/// App-wide switch for verifiable air-gap operation.
///
/// While enabled, AlphaSub performs zero network egress: every feature that
/// would touch the network (update checks, bug reports, AI model and tool
/// downloads) is gated at its call site, and `SecureModeBlockingProtocol`
/// additionally fails any http/https load as defense-in-depth. File activity
/// (project open/save, media load, subtitle import/export) is recorded to a
/// hash-chained audit log (see ``AuditLog``) so the session can be audited
/// after the fact.
///
/// The state persists across launches via `UserDefaults`. Toggling posts
/// ``didChangeNotification`` so UI (menu checkmark, window badge) can update.
public enum SecureMode {

    /// UserDefaults key backing ``isEnabled``.
    public static let defaultsKey = "com.alphasub.secureModeEnabled"

    /// Where the flag is stored. `.standard` in the app.
    ///
    /// Injectable for tests only, and not a nicety: `swift test --parallel`
    /// runs each suite in its own xctest process, and every one of them shares
    /// the `com.apple.dt.xctest.tool` defaults domain. A suite that toggled
    /// this flag was therefore visible to unrelated suites running at the same
    /// time — a DeepL test failed with "wrong error secureMode" because a
    /// Core test happened to have the mode on — and a suite that crashed
    /// mid-run left the flag set for every run afterwards, on disk. A test
    /// points this at its own throwaway suite instead.
    public static var defaults: UserDefaults = .standard

    /// Posted on the default `NotificationCenter` after the mode changes.
    public static let didChangeNotification = Notification.Name("AlphaSubSecureModeDidChange")

    /// True while Secure Mode (air-gap operation) is active.
    public static var isEnabled: Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// Flip the mode. Records the transition in the audit log (the disable
    /// event is written while the mode is still on, so it is the last entry
    /// of the session's chain) and posts ``didChangeNotification``.
    public static func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            defaults.set(true, forKey: defaultsKey)
            AuditLog.shared.record(.secureModeEnabled, detail: "Secure Mode turned on")
        } else {
            AuditLog.shared.record(.secureModeDisabled, detail: "Secure Mode turned off")
            defaults.set(false, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Consistent user-facing message for a feature blocked by Secure Mode,
    /// e.g. `blockedMessage(feature: "Checking for updates")` →
    /// "Checking for updates is disabled in Secure Mode."
    public static func blockedMessage(feature: String) -> String {
        String(localized: "\(feature) is disabled in Secure Mode.")
    }

    /// Adds offline flags to the environment of spawned helper processes
    /// (Python MLX / WhisperX workers) so libraries that would otherwise
    /// fetch models or tokenizers from Hugging Face on first use fail fast
    /// instead of egressing. No-op while Secure Mode is off.
    public static func applyOfflineEnvironment(_ env: inout [String: String]) {
        guard isEnabled else { return }
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
    }
}

// MARK: - SecureModeError

/// Thrown by network-touching entry points (installers, downloaders) when
/// Secure Mode is on. Carries the standard "disabled in Secure Mode" message.
public struct SecureModeError: LocalizedError {
    /// Human-readable feature name, e.g. "Downloading AI models".
    public let feature: String

    public init(feature: String) {
        self.feature = feature
    }

    public var errorDescription: String? {
        SecureMode.blockedMessage(feature: feature)
    }
}
