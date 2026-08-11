import Foundation

/// Centralised on-disk locations under `~/Library/Application Support/AlphaSub/`.
/// Previously each installer recomputed this; share it so paths can't diverge.
public enum AppPaths {
    /// `~/Library/Application Support/AlphaSub/`
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AlphaSub", isDirectory: true)
    }

    /// Where a downloaded `ffmpeg`/`ffprobe` pair lives when the user opts to
    /// install the video tools rather than bundling them (the static binaries
    /// are ~25 MB per arch — too large to ship in the auto-update ZIP).
    public static var ffmpegDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("ffmpeg", isDirectory: true)
    }

    /// Candidate roots to search for bundled command-line tools (asdcp, grok,
    /// ffmpeg). They ship in the AlphaSubToolBinaries resource bundle; the
    /// legacy AlphaSubApp bundle name is kept as a fallback so a build staged by
    /// an older packaging run still resolves.
    public static var bundledToolRoots: [URL] {
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }
        roots.append(Bundle.main.bundleURL)
        for name in ["AlphaSub_AlphaSubToolBinaries.bundle", "AlphaSub_AlphaSubApp.bundle"] {
            roots.append(Bundle.main.bundleURL.appendingPathComponent(name))
            if let r = Bundle.main.resourceURL {
                roots.append(r.appendingPathComponent(name))
            }
        }
        return roots
    }
}
