import Foundation

/// How many JPEG 2000 frames may be decoded at once, and how many to keep.
///
/// Playback and export want different answers, and the difference is not a
/// tuning accident:
///
///   * **Export** uses every performance core. Nothing is waiting on the UI,
///     and the job finishes when the last frame is written.
///   * **Playback** deliberately caps lower. Each decode is a single-threaded
///     `grk_decompress` process; saturating the machine starves the main
///     thread, and the symptom is a timecode that judders while the decoder
///     reports itself busy — the picture gets faster and the app gets worse.
///
/// Which is why this is a policy with a name rather than a number typed into
/// two places. The operator can override the playback figure — a Mac Studio
/// driving a 4K reel has headroom a laptop does not — but the automatic value
/// stays the default, and the UI says which of the two it is talking about.
public enum DCPDecodePolicy {

    /// Stored as an Int in UserDefaults; 0 (or absent) means automatic.
    public static let automatic = 0

    /// Resolves the stored preference against the machine.
    ///
    /// - Parameters:
    ///   - stored: the user's choice, `automatic` (or nil) for the default.
    ///   - cores: `activeProcessorCount`.
    ///   - automaticValue: what the frame source picks on its own.
    public static func playbackConcurrency(stored: Int?,
                                           cores: Int,
                                           automaticValue: Int) -> Int {
        guard let stored, stored != automatic else { return max(1, automaticValue) }
        // Never zero (nothing would decode) and never more than the machine
        // has: an oversubscribed cap only adds context switching.
        return max(1, min(stored, max(1, cores)))
    }

    /// Frames to keep decoded. Scaled to the concurrency because the cache
    /// exists to absorb a burst of in-flight decodes; a cap of 8 with a cache
    /// of 8 spends its whole life evicting frames it is about to need.
    public static func cacheCapacity(forConcurrency concurrency: Int) -> Int {
        max(16, concurrency * 8)
    }

    /// The choices to offer: automatic, then every value up to the core count.
    ///
    /// Above eight the list stops being a list, and the interesting decisions
    /// (fewer threads to keep the UI smooth, more to survive a 4K reel) are all
    /// at the low end anyway.
    public static func choices(cores: Int) -> [Int] {
        Array(1...max(1, min(cores, 8)))
    }
}
