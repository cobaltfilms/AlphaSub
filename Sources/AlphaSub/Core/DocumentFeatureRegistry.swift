import Foundation

/// Registry of document-format capabilities used to compute the minimum
/// `SubtitleDocument.version` required by the features actually present in a
/// project.
///
/// AlphaSub saves each project at the lowest version that supports its contents,
/// so a project that does not use newer/beta features stays openable in older
/// releases.
public enum DocumentFeature: String, Sendable {
    case baseFormat
    /// Version 2: `VerticalPosition.percentage` is measured UP FROM THE BOTTOM
    /// of the active pixel area (the DCP/SMPTE convention). Version-1 projects
    /// store the complement (down from the top) and are migrated on decode —
    /// a 1.x build would render a bottom-origin percentage mirrored, so a
    /// project that carries explicit percentages must not open there.
    case bottomOriginVerticalPosition
}

public struct DocumentFeatureRegistry {
    /// The newest document version the current build can read.
    public static let supportedReadVersion = 2

    /// The minimum document version required to represent `document` safely.
    public static func requiredVersion(for document: SubtitleDocument) -> Int {
        for track in document.tracks {
            if case .percentage = track.defaultVerticalPosition { return 2 }
            for sub in track.subtitles {
                if case .percentage = sub.verticalPosition { return 2 }
                for block in sub.textBlocks where block.verticalPosition != nil {
                    if case .percentage = block.verticalPosition { return 2 }
                }
            }
        }
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
            return String(localized: "This project requires AlphaSUB document version \(version), but this build supports up to version \(supported). Please update AlphaSUB to open it.")
        }
    }
}
