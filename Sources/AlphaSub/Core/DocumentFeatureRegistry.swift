import Foundation

/// Registry of document-format capabilities used to compute the minimum
/// `SubtitleDocument.version` required by the features actually present in a
/// project.
///
/// AlphaSub saves each project at the lowest version that supports its contents,
/// so a project that does not use newer/beta features stays openable in older
/// releases. For 1.0.0 only the base format exists, so every project is version 1.
public enum DocumentFeature: String, Sendable {
    case baseFormat
}

public struct DocumentFeatureRegistry {
    /// The newest document version the current build can read.
    public static let supportedReadVersion = 1

    /// The minimum document version required to represent `document` safely.
    public static func requiredVersion(for document: SubtitleDocument) -> Int {
        // For 1.0.0, the base format is the only feature, so all projects remain
        // version 1. Future beta features will raise this only when they are
        // actually used in the document.
        _ = document
        return 1
    }

    /// True when the current build can open the given document version.
    public static func canOpen(version: Int) -> Bool {
        version <= supportedReadVersion
    }
}

/// Errors thrown when a document cannot be loaded by the current build.
public enum DocumentCompatibilityError: LocalizedError {
    case versionTooNew(version: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .versionTooNew(let version, let supported):
            return String(localized: "This project requires AlphaSub document version \(version), but this build supports up to version \(supported). Please update AlphaSub to open it.")
        }
    }
}
