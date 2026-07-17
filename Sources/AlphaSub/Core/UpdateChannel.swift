import Foundation

/// The release stream the app follows for automatic updates.
public enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case beta

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .stable: return String(localized: "Stable")
        case .beta:   return String(localized: "Beta")
        }
    }

    /// The default channel for fresh installs. A debug override can be set by
    /// passing `-alpha-sub-default-channel-beta` at launch for internal testing.
    ///
    /// A beta build follows beta updates by default so it keeps receiving beta
    /// releases; a stable build follows stable updates. The user can still
    /// override this in Preferences → Updates to opt a stable build into beta
    /// *downloads* (which then enables AI, since the beta bundle ships it).
    private static var defaultChannel: UpdateChannel {
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.first(where: { $0.hasPrefix("-alpha-sub-default-channel-") }) {
            let raw = String(flag.dropFirst("-alpha-sub-default-channel-".count))
            return UpdateChannel(rawValue: raw) ?? .stable
        }
        return BuildChannel.current == .beta ? .beta : .stable
    }

    private static let key = "com.alphasub.updateChannel"

    public static var current: UpdateChannel {
        get {
            if let raw = UserDefaults.standard.string(forKey: key),
               let channel = UpdateChannel(rawValue: raw) {
                return channel
            }
            return defaultChannel
        }
        set {
            UserDefaults.standard.setValue(newValue.rawValue, forKey: key)
        }
    }
}
