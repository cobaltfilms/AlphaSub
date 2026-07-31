import Foundation

// MARK: - FFmpegCapabilities

/// What the *resolved* ffmpeg binary can actually do.
///
/// AlphaSub bundles a minimal LGPL ffmpeg built with `--disable-everything`
/// plus a whitelist (see `scripts/build-ffmpeg-lgpl.sh`), and falls back to
/// whatever ffmpeg the user has on PATH. Either binary can be missing a
/// filter our command lines assume: the bundled 7.1 build shipped without
/// `highpass`, which made every audio extraction fail with
/// "No such filter: 'highpass'" — transcription was dead on arrival.
///
/// Rather than assume, we ask the binary once (`ffmpeg -filters`) and let
/// callers degrade gracefully when a *nice-to-have* filter is absent.
public enum FFmpegCapabilities {

    private static let lock = NSLock()
    private static var cachedFilters: Set<String>?
    private static var cachedForPath: String?

    /// Names of every filter the current ffmpeg exposes.
    ///
    /// Returns an empty set if ffmpeg can't be found or the probe fails; a
    /// caller that gets an empty set should build the most conservative
    /// command line it can (no `-af`/`-vf` at all).
    public static func availableFilters() -> Set<String> {
        let path = FFTool.ffmpeg
        lock.lock()
        if let cached = cachedFilters, cachedForPath == path {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let filters = path.map(probeFilters(ffmpeg:)) ?? []

        lock.lock()
        cachedFilters = filters
        cachedForPath = path
        lock.unlock()
        return filters
    }

    /// True if `name` is compiled into the current ffmpeg.
    public static func hasFilter(_ name: String) -> Bool {
        availableFilters().contains(name)
    }

    /// Drop the cached probe — used by tests and after a user installs a
    /// different ffmpeg (`FFmpegInstaller`).
    public static func invalidateCache() {
        lock.lock()
        cachedFilters = nil
        cachedForPath = nil
        lock.unlock()
    }

    // MARK: - Probing

    private static func probeFilters(ffmpeg: String) -> Set<String> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-hide_banner", "-loglevel", "error", "-filters"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return parseFilterList(text)
    }

    /// Parse `ffmpeg -filters` output. Each filter line looks like:
    ///
    ///     ` T.C volume            A->A       Change input volume.`
    ///
    /// i.e. a three-character flag field (`T`/`S`/`C`/`.`), the filter name,
    /// then the signature. Header lines don't match that shape and are
    /// skipped.
    public static func parseFilterList(_ text: String) -> Set<String> {
        var names: Set<String> = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3 else { continue }
            let flags = fields[0]
            guard flags.count == 3,
                  flags.allSatisfy({ "TSC.".contains($0) }),
                  // The signature field ("A->A", "|->V", "N->N") is what
                  // separates a real entry from the legend lines at the top,
                  // which share the flag shape ("T.. = Timeline support").
                  fields[2].contains("->") else { continue }
            names.insert(String(fields[1]))
        }
        return names
    }
}
