/// ITU-R BS.775 stereo fold-down coefficients. Pure math — unit-tested,
/// consumed by the MTAudioProcessingTap in AlphaSubVideo.
public enum DownmixMatrix {
    public static let minus3dB = 0.70710678118654752

    /// Per-input-channel gains for (left, right) output, for a source with
    /// `channelCount` channels in SMPTE order L R C LFE Ls Rs.
    /// Channel counts other than 6 (and 5 = no LFE) get a defensive
    /// equal-split fallback; 1–2 channels return identity (no downmix needed).
    public static func coefficients(channelCount: Int) -> [(left: Double, right: Double)] {
        switch channelCount {
        case ..<1: return []
        case 1:    return [(1, 1)]
        case 2:    return [(1, 0), (0, 1)]
        case 5: // L R C Ls Rs (no LFE)
            let n = normalization()
            return [(n, 0), (0, n), (minus3dB * n, minus3dB * n),
                    (minus3dB * n, 0), (0, minus3dB * n)]
        case 6: // L R C LFE Ls Rs
            let n = normalization()
            return [(n, 0), (0, n), (minus3dB * n, minus3dB * n), (0, 0),
                    (minus3dB * n, 0), (0, minus3dB * n)]
        default: // unknown layout: average everything into both, -3 dB
            let g = minus3dB / Double(channelCount)
            return Array(repeating: (g, g), count: channelCount)
        }
    }

    /// 1 / (1 + 0.7071 + 0.7071) — keeps a full-scale all-channel signal ≤ 1.0.
    public static func normalization() -> Double {
        1.0 / (1.0 + minus3dB + minus3dB)
    }
}
