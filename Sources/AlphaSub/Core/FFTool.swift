import Foundation

// MARK: - ffmpeg / ffprobe discovery

/// Locates ffmpeg/ffprobe for the modules that shell out to them (MKV import,
/// audio extraction, video export/muxing). Lives in Core so App, Transcription
/// and Render share one copy.
public enum FFTool {
    private static let searchDirs = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin", "/bin"
    ]

    /// Subdirectory inside the app bundle (or SPM resource bundle) where an
    /// optional bundled ffmpeg/ffprobe lives. See
    /// `Sources/AlphaSubToolBinaries/Resources/ffmpeg/README.md`.
    private static let bundledSubdir = "ffmpeg"

    /// Returns the absolute path of a bundled `name` (e.g. "ffmpeg") if one
    /// is present in the app bundle's Resources, otherwise `nil`.
    ///
    /// When AlphaSub is run via `swift build`, resources live next to the
    /// executable or inside the SPM-generated resource bundle; when packaged
    /// they live under `Contents/Resources`. We probe all of those.
    private static func bundledPath(_ name: String) -> String? {
        let fm = FileManager.default
        let rel = "\(bundledSubdir)/\(name)"
        for root in AppPaths.bundledToolRoots {
            let p = root.appendingPathComponent(rel)
            if fm.isExecutableFile(atPath: p.path) { return p.path }
        }
        return nil
    }

    /// Resolves `name` (e.g. "ffmpeg", "ffprobe") to an absolute path.
    ///
    /// Resolution order:
    ///   1. Bundled copy in the app bundle's Resources (see
    ///      `Resources/ffmpeg/`), so AlphaSub works without a Homebrew ffmpeg.
    ///   2. A user-downloaded copy in Application Support (FFmpegInstaller).
    ///   3. Well-known Homebrew/system directories.
    ///   4. `which` (honours the user's PATH).
    public static func path(_ name: String) -> String? {
        if let bundled = bundledPath(name) { return bundled }
        let downloaded = AppPaths.ffmpegDirectory.appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: downloaded) { return downloaded }
        for dir in searchDirs {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Fall back to `which` (honours the user's PATH).
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        if which.terminationStatus == 0,
           let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !out.isEmpty {
            return out
        }
        return nil
    }

    public static var ffmpeg: String? { path("ffmpeg") }
    public static var ffprobe: String? { path("ffprobe") }
}
