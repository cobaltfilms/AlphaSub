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

    /// Posted on the default `NotificationCenter` after the mode changes.
    public static let didChangeNotification = Notification.Name("AlphaSubSecureModeDidChange")

    /// True while Secure Mode (air-gap operation) is active.
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Flip the mode. Records the transition in the audit log (the disable
    /// event is written while the mode is still on, so it is the last entry
    /// of the session's chain) and posts ``didChangeNotification``.
    public static func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            UserDefaults.standard.set(true, forKey: defaultsKey)
            AuditLog.shared.record(.secureModeEnabled, detail: "Secure Mode turned on")
        } else {
            AuditLog.shared.record(.secureModeDisabled, detail: "Secure Mode turned off")
            UserDefaults.standard.set(false, forKey: defaultsKey)
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
