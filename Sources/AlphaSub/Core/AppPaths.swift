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
    /// ffmpeg).
    ///
    /// EVERY resource bundle in the app, not a list of names. SwiftPM names a
    /// bundle `<Package>_<Target>`, so the rename of this package to
    /// AlphaShared moved the tools from `AlphaSub_AlphaSubToolBinaries.bundle`
    /// to `AlphaShared_AlphaSubToolBinaries.bundle` — and a hardcoded pair of
    /// `AlphaSub_*` names went on resolving only because a stale bundle under
    /// the old name was still lying in `.build` and being copied in beside the
    /// real one. On a machine that got a package built from a clean tree the
    /// decoder was simply not found, and DCP playback reported it as
    /// unavailable while the binary sat in the app the whole time.
    ///
    /// Directory enumeration cannot go stale the way a name list does. The
    /// explicit roots stay first so the common case is still a direct hit.
    public static var bundledToolRoots: [URL] {
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }
        roots.append(Bundle.main.bundleURL)
        for container in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            let bundles = (try? FileManager.default.contentsOfDirectory(
                at: container, includingPropertiesForKeys: nil)) ?? []
            roots.append(contentsOf: bundles.filter { $0.pathExtension == "bundle" })
        }
        return roots
    }
}
