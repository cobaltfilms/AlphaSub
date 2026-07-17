import Foundation

extension SubtitleDocument {
    /// Computes the minimum document version that supports the features
    /// actually used in this document.
    public var requiredVersion: Int {
        DocumentFeatureRegistry.requiredVersion(for: self)
    }

    /// True when the current build can open this document.
    public var isOpenableByCurrentBuild: Bool {
        DocumentFeatureRegistry.canOpen(version: version)
    }

    /// Validates that the document can be opened by the current build, throwing
    /// a clear error otherwise.
    public func validateOpenable() throws {
        guard isOpenableByCurrentBuild else {
            throw DocumentCompatibilityError.versionTooNew(
                version: version,
                supported: DocumentFeatureRegistry.supportedReadVersion
            )
        }
    }
}
