import Foundation

/// Infers the frame rate a millisecond-timed subtitle file was authored at.
///
/// Formats like SRT and WebVTT stamp cues in milliseconds and never state their
/// rate, but the numbers still betray it: every stamp is a frame boundary
/// written to the nearest millisecond, so a 25 fps file only ever lands on
/// …,000 / …,040 / …,080 / …,120 and a 24 fps file on …,000 / …,042 / …,083 /
/// …,125. Scoring the stamps against each candidate grid recovers the rate,
/// which is a far better default for the import prompt than a blanket 25 fps.
///
/// Fractional (1000/1001) rates are handled by scoring against the *absolute*
/// time rather than the sub-second remainder — 23.976 drifts off any fixed
/// millisecond pattern, but over a whole programme it still hugs its own grid
/// much more closely than 24 fps does.
public enum FrameRateSignature {

    /// Candidate rates, coarsest grid first. Order matters: a 25 fps file also
    /// sits perfectly on the 50 fps grid (and 24 on 48), so the first rate that
    /// fits — the one that explains the data with the fewest frames — wins.
    /// Drop-frame variants are omitted because they share their NDF sibling's
    /// wall-clock grid; only the on-screen labels differ.
    private static let candidates: [FrameRate] = [
        .fps23_976, .fps24, .fps25, .fps29_97_ndf, .fps30,
        .fps47_952, .fps48, .fps50, .fps59_94_ndf, .fps60,
    ]

    /// Largest error, in milliseconds, still attributable to the writer rounding
    /// a frame boundary to whole milliseconds. Half a millisecond is the
    /// theoretical bound; real writers (Resolve among them) truncate instead of
    /// rounding, costing a further whole millisecond.
    private static let toleranceMilliseconds = 2.0

    /// Fewest stamps that make a verdict meaningful. Below this, coincidence is
    /// as likely an explanation as a real signature.
    private static let minimumSamples = 8

    /// The rate whose frame grid the given millisecond stamps sit on, or nil
    /// when they are too few, too coarse, or don't fit any candidate.
    ///
    /// - Parameter milliseconds: absolute cue times, in milliseconds from
    ///   00:00:00.000. Both in- and out-points should be included.
    public static func detect(milliseconds: [Int]) -> FrameRate? {
        let samples = Array(Set(milliseconds.filter { $0 >= 0 })).sorted()
        guard samples.count >= minimumSamples else { return nil }

        // Stamps that are all whole seconds (or whole tenths) fit every grid and
        // say nothing. Demand a decent spread of sub-second remainders before
        // trusting any verdict.
        let remainders = Set(samples.map { $0 % 1000 })
        guard remainders.subtracting([0]).count >= 4 else { return nil }

        for rate in candidates where fits(samples, rate: rate) {
            return rate
        }
        return nil
    }

    /// Scan raw subtitle text for `HH:MM:SS,mmm` / `HH:MM:SS.mmm` stamps and
    /// infer the rate from them. Format-agnostic on purpose: it works on SRT,
    /// WebVTT and plain-text spotting lists alike, and runs on the bytes before
    /// any importer has quantised them onto a guessed grid.
    public static func detect(inText text: String) -> FrameRate? {
        detect(milliseconds: millisecondStamps(inText: text))
    }

    /// Same, straight from file bytes. Returns nil for data that isn't text.
    public static func detect(inData data: Data) -> FrameRate? {
        // A signature needs only the first few thousand cues; cap the decode so
        // a huge file doesn't cost more than the prompt it feeds.
        let slice = data.count > 512_000 ? data.prefix(512_000) : data[...]
        guard let text = String(data: Data(slice), encoding: .utf8)
                ?? String(data: Data(slice), encoding: .isoLatin1)
        else { return nil }
        return detect(inText: text)
    }

    /// Every `HH:MM:SS,mmm` stamp in `text`, as absolute milliseconds.
    public static func millisecondStamps(inText text: String) -> [Int] {
        let pattern = #/(\d{1,3}):([0-5]\d):([0-5]\d)[,.](\d{3})\b/#
        var stamps: [Int] = []
        for match in text.matches(of: pattern) {
            guard let h = Int(match.1), let m = Int(match.2),
                  let s = Int(match.3), let ms = Int(match.4)
            else { continue }
            stamps.append(((h * 60 + m) * 60 + s) * 1000 + ms)
        }
        return stamps
    }

    /// True when every stamp lands within tolerance of a frame boundary at
    /// `rate`. A single outlier disqualifies the rate — one genuine off-grid
    /// stamp means the file wasn't authored on that grid at all, and being
    /// wrong here silently shifts the user's cues.
    private static func fits(_ milliseconds: [Int], rate: FrameRate) -> Bool {
        let frameMillis = 1000.0 / rate.value
        for ms in milliseconds {
            let frames = Double(ms) / frameMillis
            let error = abs(frames - frames.rounded()) * frameMillis
            if error > toleranceMilliseconds { return false }
        }
        return true
    }
}
