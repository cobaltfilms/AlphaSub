import Foundation

public struct VideoFormatCompatibility {
    public static func isValid(codec: VideoCodec, container: VideoContainer) -> Bool {
        codec.supportedContainers.contains(container)
    }

    public static func validate(profile: VideoProfile) -> [VideoFormatIssue] {
        var issues: [VideoFormatIssue] = []

        if !profile.codec.supportedContainers.contains(profile.container) {
            issues.append(.unsupportedContainer(
                codec: profile.codec,
                container: profile.container
            ))
        }

        if profile.codec.isDNxHD {
            if let dnxProfile = profile.dnxHDProfile {
                let (pw, ph) = dnxProfile.resolution
                if profile.resolution.width != pw || profile.resolution.height != ph {
                    issues.append(.resolutionMismatch(
                        expected: VideoResolution(width: pw, height: ph),
                        actual: profile.resolution
                    ))
                }
            } else {
                issues.append(.missingProfile(codec: profile.codec))
            }
        }

        if profile.codec.isProRes, profile.container == .mxf {
            // ProRes in MXF is valid for some broadcast workflows but uncommon
        }

        if profile.codec == .h265, profile.bitDepth > 10 {
            issues.append(.unsupportedBitDepth(codec: profile.codec, bitDepth: profile.bitDepth))
        }

        return issues
    }

    public static let supportedProfiles: [VideoProfile] = [
        // ProRes in MOV
        .presetProRes422HQ1080p25,
        .presetProRes422HQ1080p24000,
        .presetProRes422HQ4K25,
        .presetProRes44441080p25,
        // ProRes 422 Standard
        VideoProfile(codec: .proRes422, container: .mov, resolution: .hd1080, frameRate: .fps25, proResProfile: .standard),
        VideoProfile(codec: .proRes422, container: .mov, resolution: .hd1080, frameRate: .fps23_976, proResProfile: .standard),
        VideoProfile(codec: .proRes422, container: .mov, resolution: .hd1080, frameRate: .fps29_97_ndf, proResProfile: .standard),
        // ProRes 422 LT
        VideoProfile(codec: .proRes422LT, container: .mov, resolution: .hd1080, frameRate: .fps25, proResProfile: .lt),
        // ProRes 422 Proxy
        VideoProfile(codec: .proRes422Proxy, container: .mov, resolution: .hd1080, frameRate: .fps25, proResProfile: .proxy),
        // ProRes 4444 XQ
        VideoProfile(codec: .proRes4444XQ, container: .mov, resolution: .hd1080, frameRate: .fps25, proResProfile: .xq),
        // ProRes in MXF (broadcast)
        VideoProfile(codec: .proRes422HQ, container: .mxf, resolution: .hd1080, frameRate: .fps25, proResProfile: .hq),
        VideoProfile(codec: .proRes422HQ, container: .mxf, resolution: .hd1080, frameRate: .fps29_97_ndf, proResProfile: .hq),
        // H.264
        .presetH2641080p25MP4,
        VideoProfile(codec: .h264, container: .mov, resolution: .hd1080, frameRate: .fps25),
        VideoProfile(codec: .h264, container: .mp4, resolution: .hd1080, frameRate: .fps23_976),
        VideoProfile(codec: .h264, container: .mp4, resolution: .hd1080, frameRate: .fps29_97_ndf),
        // H.265
        .presetH2654K25MP4,
        VideoProfile(codec: .h265, container: .mov, resolution: .uhd4K, frameRate: .fps25),
        VideoProfile(codec: .h265, container: .mp4, resolution: .hd1080, frameRate: .fps25),
        // DNxHR
        .presetDNxHRHQ1080p25MXF,
        .presetDNxHRSQ1080p25MOV,
        VideoProfile(codec: .dnxHR, container: .mxf, resolution: .uhd4K, frameRate: .fps25, dnxHRProfile: .dnxhr_hq),
        VideoProfile(codec: .dnxHR, container: .mov, resolution: .hd1080, frameRate: .fps23_976, dnxHRProfile: .dnxhr_hq),
        // DNxHD
        .presetDNxHD1080i50120MXF,
        VideoProfile(codec: .dnxHD, container: .mov, resolution: .hd1080, frameRate: .fps25, dnxHDProfile: .dnxhd_1080i_50_120),
    ]
}

public enum VideoFormatIssue {
    case unsupportedContainer(codec: VideoCodec, container: VideoContainer)
    case resolutionMismatch(expected: VideoResolution, actual: VideoResolution)
    case missingProfile(codec: VideoCodec)
    case unsupportedBitDepth(codec: VideoCodec, bitDepth: Int)
}

// MARK: - Export Presets

public enum VideoExportPreset: String, CaseIterable {
    case proRes422HQ1080p25MOV     = "prores422hq_1080p25_mov"
    case proRes4221080p25MOV       = "prores422_1080p25_mov"
    case proRes44441080p25MOV      = "prores4444_1080p25_mov"
    case proRes422HQ4K25MOV        = "prores422hq_4k25_mov"
    case h2641080p25MP4            = "h264_1080p25_mp4"
    case h2641080p24MP4             = "h264_1080p24_mp4"
    case h2654K25MP4               = "h265_4k25_mp4"
    case dnxHRHQ1080p25MXF         = "dnxhr_hq_1080p25_mxf"
    case dnxHRSQ1080p25MOV         = "dnxhr_sq_1080p25_mov"
    case dnxHD1080i50120MXF        = "dnxhd_1080i50_120_mxf"

    public var profile: VideoProfile {
        switch self {
        case .proRes422HQ1080p25MOV:  return .presetProRes422HQ1080p25
        case .proRes4221080p25MOV:    return VideoProfile(codec: .proRes422, container: .mov, resolution: .hd1080, frameRate: .fps25, proResProfile: .standard)
        case .proRes44441080p25MOV:   return .presetProRes44441080p25
        case .proRes422HQ4K25MOV:     return .presetProRes422HQ4K25
        case .h2641080p25MP4:         return .presetH2641080p25MP4
        case .h2641080p24MP4:         return VideoProfile(codec: .h264, container: .mp4, resolution: .hd1080, frameRate: .fps24)
        case .h2654K25MP4:            return .presetH2654K25MP4
        case .dnxHRHQ1080p25MXF:      return .presetDNxHRHQ1080p25MXF
        case .dnxHRSQ1080p25MOV:      return .presetDNxHRSQ1080p25MOV
        case .dnxHD1080i50120MXF:     return .presetDNxHD1080i50120MXF
        }
    }

    public var displayName: String {
        let p = profile
        var codecPart = p.codec.shortName
        if let prProfile = p.proResProfile { codecPart = prProfile.displayName }
        if let hrProfile = p.dnxHRProfile { codecPart = "DNxHR \(hrProfile.shortName)" }
        if let hdProfile = p.dnxHDProfile { codecPart = hdProfile.displayName }

        return "\(codecPart) — \(p.resolution.label) @ \(p.frameRate.label) — .\(p.container.rawValue)"
    }
}