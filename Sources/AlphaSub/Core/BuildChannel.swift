import Foundation

/// The build-time release identity, baked into the app bundle's `Info.plist`.
///
/// Unlike ``UpdateChannel`` — a *user-selectable* preference that only chooses
/// which appcast the updater follows — the build channel is fixed at package
/// time and cannot be changed at runtime:
///
/// - the `main` branch ships `stable` builds,
/// - the `release/beta` branch ships `beta` builds.
///
/// It is the single source of truth for whether in-development features are
/// available. Because it comes from the bundle rather than `UserDefaults`, a
/// stable build can never unlock beta features by flipping a preference.
///
/// The AI feature set graduated to stable in July 2026, so nothing is gated
/// at the moment: the gate is reserved for genuinely in-development features
/// shipped to beta testers first. To gate a new beta feature, wrap its UI in
/// `BuildChannel.betaFeaturesEnabled`; when it graduates, remove the wrapper —
/// no per-branch code change is required either way.
public enum BuildChannel: String, Sendable {
    case stable
    case beta

    /// `Info.plist` key stamped per branch. See `Resources/Info.plist`.
    static let infoDictionaryKey = "AlphaSubBuildChannel"

    /// The channel this binary was built for, read once from the main bundle.
    ///
    /// Defaults to `.stable` when the key is absent (older bundles, the test
    /// runner, or `swift run` without packaging) so any unstamped build is
    /// conservatively treated as a stable release with beta features off.
    public static let current: BuildChannel = {
        if let raw = Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String,
           let channel = BuildChannel(rawValue: raw.lowercased()) {
            return channel
        }
        return .stable
    }()

    /// True when this build exposes in-development (beta-only) features.
    /// Currently gates nothing — AI graduated to stable in July 2026 — but
    /// stays as the single gate for the next beta-tester-first feature.
    public static var betaFeaturesEnabled: Bool { current == .beta }
}
