import Foundation

// MARK: - Video Container Format

public enum VideoContainer: String, Codable, CaseIterable {
    case mov  = "mov"
    case mp4  = "mp4"
    case mxf  = "mxf"

    public var displayName: String {
        switch self {
        case .mov: return "QuickTime (.mov)"
        case .mp4: return "MPEG-4 (.mp4)"
        case .mxf: return "MXF (.mxf)"
        }
    }

    public var typicalExtensions: [String] {
        switch self {
        case .mov: return ["mov", "qt"]
        case .mp4: return ["mp4", "m4v"]
        case .mxf: return ["mxf"]
        }
    }

    public var isBroadcastContainer: Bool {
        self == .mxf
    }

    public static func from(fileExtension ext: String) -> VideoContainer? {
        let lower = ext.lowercased()
        for container in VideoContainer.allCases {
            if container.typicalExtensions.contains(lower) { return container }
        }
        return nil
    }
}

// MARK: - Video Codec

public enum VideoCodec: String, Codable, CaseIterable {
    // Apple ProRes family
    case proRes4444XQ  = "prores_4444_xq"
    case proRes4444    = "prores_4444"
    case proRes422HQ   = "prores_422_hq"
    case proRes422     = "prores_422"
    case proRes422LT   = "prores_422_lt"
    case proRes422Proxy = "prores_422_proxy"

    // H.264 / AVC
    case h264          = "h264"

    // H.265 / HEVC
    case h265           = "h265"

    // Avid DNxHD family
    case dnxHD          = "dnxhd"
    case dnxHR          = "dnxhr"

    public var displayName: String {
        switch self {
        case .proRes4444XQ:  return "Apple ProRes 4444 XQ"
        case .proRes4444:    return "Apple ProRes 4444"
        case .proRes422HQ:   return "Apple ProRes 422 HQ"
        case .proRes422:     return "Apple ProRes 422"
        case .proRes422LT:   return "Apple ProRes 422 LT"
        case .proRes422Proxy: return "Apple ProRes 422 Proxy"
        case .h264:          return "H.264 / AVC"
        case .h265:           return "H.265 / HEVC"
        case .dnxHD:          return "Avid DNxHD"
        case .dnxHR:          return "Avid DNxHR"
        }
    }

    public var shortName: String {
        switch self {
        case .proRes4444XQ:  return "ProRes 4444 XQ"
        case .proRes4444:    return "ProRes 4444"
        case .proRes422HQ:   return "ProRes 422 HQ"
        case .proRes422:     return "ProRes 422"
        case .proRes422LT:   return "ProRes 422 LT"
        case .proRes422Proxy: return "ProRes 422 Proxy"
        case .h264:          return "H.264"
        case .h265:           return "H.265"
        case .dnxHD:          return "DNxHD"
        case .dnxHR:          return "DNxHR"
        }
    }

    public var family: CodecFamily {
        switch self {
        case .proRes4444XQ, .proRes4444, .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy:
            return .proRes
        case .h264:
            return .avc
        case .h265:
            return .hevc
        case .dnxHD, .dnxHR:
            return .dnx
        }
    }

    public var isProRes: Bool { family == .proRes }
    public var isDNxHD: Bool { self == .dnxHD }
    public var isDNxHR: Bool { self == .dnxHR }
    public var isDNxFamily: Bool { family == .dnx }
    public var isLongGOP: Bool { family == .avc || family == .hevc }
    public var isIntraFrame: Bool { family == .proRes || family == .dnx }

    public var supportedContainers: [VideoContainer] {
        switch self {
        case .proRes4444XQ, .proRes4444, .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy:
            return [.mov, .mp4, .mxf]
        case .h264:
            return [.mov, .mp4, .mxf]
        case .h265:
            return [.mov, .mp4, .mxf]
        case .dnxHD:
            return [.mov, .mxf]
        case .dnxHR:
            return [.mov, .mxf]
        }
    }

    public var fourCC: String {
        switch self {
        case .proRes4444XQ:  return "ap4x"
        case .proRes4444:    return "ap4h"
        case .proRes422HQ:   return "apch"
        case .proRes422:     return "apcn"
        case .proRes422LT:   return "apcs"
        case .proRes422Proxy: return "apco"
        case .h264:          return "avc1"
        case .h265:           return "hvc1"
        case .dnxHD:          return "AVdh"
        case .dnxHR:          return "AVdh"
        }
    }

    public var avMediaType: UInt32 {
        switch self {
        case .proRes4444XQ:   return 0x61703478 // ap4x
        case .proRes4444:      return 0x61703468 // ap4h
        case .proRes422HQ:     return 0x61706368 // apch
        case .proRes422:       return 0x6170636E // apcn
        case .proRes422LT:     return 0x61706373 // apcs
        case .proRes422Proxy:  return 0x6170636F // apco
        case .h264:            return 0x61766331 // avc1
        case .h265:            return 0x68766331 // hvc1
        case .dnxHD, .dnxHR:  return 0x41566468 // AVdh
        }
    }
}

public enum CodecFamily: String, Codable, CaseIterable {
    case proRes = "prores"
    case avc    = "avc"
    case hevc   = "hevc"
    case dnx    = "dnx"
}

// MARK: - DNxHD/DNxHR Profiles

public enum DNxHDProfile: String, Codable, CaseIterable {
    case dnxhd_1080i_60_145  = "dnxhd_1080i_60_145"
    case dnxhd_1080i_50_120  = "dnxhd_1080i_50_120"
    case dnxhd_1080p_60_220  = "dnxhd_1080p_60_220"
    case dnxhd_1080p_50_185  = "dnxhd_1080p_50_185"
    case dnxhd_1080p_30_145  = "dnxhd_1080p_30_145"
    case dnxhd_1080p_25_120  = "dnxhd_1080p_25_120"
    case dnxhd_720p_60_220   = "dnxhd_720p_60_220"
    case dnxhd_720p_50_185   = "dnxhd_720p_50_185"
    case dnxhd_720p_30_110   = "dnxhd_720p_30_110"
    case dnxhd_720p_25_90    = "dnxhd_720p_25_90"

    public var displayName: String {
        switch self {
        case .dnxhd_1080i_60_145:  return "DNxHD 1080i/60 145 Mbit/s"
        case .dnxhd_1080i_50_120:  return "DNxHD 1080i/50 120 Mbit/s"
        case .dnxhd_1080p_60_220:  return "DNxHD 1080p/60 220 Mbit/s"
        case .dnxhd_1080p_50_185:  return "DNxHD 1080p/50 185 Mbit/s"
        case .dnxhd_1080p_30_145:  return "DNxHD 1080p/30 145 Mbit/s"
        case .dnxhd_1080p_25_120:  return "DNxHD 1080p/25 120 Mbit/s"
        case .dnxhd_720p_60_220:   return "DNxHD 720p/60 220 Mbit/s"
        case .dnxhd_720p_50_185:   return "DNxHD 720p/50 185 Mbit/s"
        case .dnxhd_720p_30_110:   return "DNxHD 720p/30 110 Mbit/s"
        case .dnxhd_720p_25_90:    return "DNxHD 720p/25 90 Mbit/s"
        }
    }

    public var resolution: (width: Int, height: Int) {
        switch self {
        case .dnxhd_1080i_60_145, .dnxhd_1080i_50_120,
             .dnxhd_1080p_60_220, .dnxhd_1080p_50_185,
             .dnxhd_1080p_30_145, .dnxhd_1080p_25_120:
            return (1920, 1080)
        case .dnxhd_720p_60_220, .dnxhd_720p_50_185,
             .dnxhd_720p_30_110, .dnxhd_720p_25_90:
            return (1280, 720)
        }
    }

    public var targetBitrateMbps: Int {
        switch self {
        case .dnxhd_1080i_60_145:  return 145
        case .dnxhd_1080i_50_120:  return 120
        case .dnxhd_1080p_60_220:  return 220
        case .dnxhd_1080p_50_185:  return 185
        case .dnxhd_1080p_30_145:  return 145
        case .dnxhd_1080p_25_120:  return 120
        case .dnxhd_720p_60_220:   return 220
        case .dnxhd_720p_50_185:   return 185
        case .dnxhd_720p_30_110:   return 110
        case .dnxhd_720p_25_90:    return 90
        }
    }

    public var vid: String {
        switch self {
        case .dnxhd_1080i_60_145:  return "VA3N"
        case .dnxhd_1080i_50_120:  return "VA3A"
        case .dnxhd_1080p_60_220:  return "VANQ" // approx
        case .dnxhd_1080p_50_185:  return "VANP" // approx
        case .dnxhd_1080p_30_145:  return "VA3P"
        case .dnxhd_1080p_25_120:  return "VA3A" // reused
        case .dnxhd_720p_60_220:   return "VANQ"
        case .dnxhd_720p_50_185:   return "VANP"
        case .dnxhd_720p_30_110:   return "VA5N"
        case .dnxhd_720p_25_90:    return "VA5A"
        }
    }
}

public enum DNxHRProfile: String, Codable, CaseIterable {
    case dnxhr_lb  = "dnxhr_lb"
    case dnxhr_sq  = "dnxhr_sq"
    case dnxhr_hq  = "dnxhr_hq"
    case dnxhr_hqx = "dnxhr_hqx"
    case dnxhr_444 = "dnxhr_444"

    public var displayName: String {
        switch self {
        case .dnxhr_lb:  return "DNxHR LB (Low Bandwidth)"
        case .dnxhr_sq:  return "DNxHR SQ (Standard Quality)"
        case .dnxhr_hq:  return "DNxHR HQ (High Quality)"
        case .dnxhr_hqx: return "DNxHR HQX (High Quality 10-bit)"
        case .dnxhr_444: return "DNxHR 444 (444 10/12-bit)"
        }
    }

    public var shortName: String {
        switch self {
        case .dnxhr_lb:  return "LB"
        case .dnxhr_sq:  return "SQ"
        case .dnxhr_hq:  return "HQ"
        case .dnxhr_hqx: return "HQX"
        case .dnxhr_444: return "444"
        }
    }

    public var bitDepth: Int {
        switch self {
        case .dnxhr_lb, .dnxhr_sq, .dnxhr_hq: return 8
        case .dnxhr_hqx: return 10
        case .dnxhr_444: return 10
        }
    }

    public var chromaSubsampling: String {
        switch self {
        case .dnxhr_lb, .dnxhr_sq, .dnxhr_hq: return "4:2:2"
        case .dnxhr_hqx: return "4:2:2"
        case .dnxhr_444: return "4:4:4"
        }
    }

    public var vid: String {
        switch self {
        case .dnxhr_lb:  return "AVdh"
        case .dnxhr_sq:  return "AVdh"
        case .dnxhr_hq:  return "AVdh"
        case .dnxhr_hqx: return "AVdh"
        case .dnxhr_444: return "AVdh"
        }
    }
}

// MARK: - ProRes Profiles

public enum ProResProfile: String, Codable, CaseIterable {
    case proxy    = "422_proxy"
    case lt       = "422_lt"
    case standard = "422"
    case hq       = "422_hq"
    case `4444`   = "4444"
    case xq       = "4444_xq"

    public var displayName: String {
        switch self {
        case .proxy:    return "ProRes 422 Proxy"
        case .lt:       return "ProRes 422 LT"
        case .standard: return "ProRes 422"
        case .hq:       return "ProRes 422 HQ"
        case .`4444`:   return "ProRes 4444"
        case .xq:       return "ProRes 4444 XQ"
        }
    }

    public var codec: VideoCodec {
        switch self {
        case .proxy:    return .proRes422Proxy
        case .lt:       return .proRes422LT
        case .standard: return .proRes422
        case .hq:       return .proRes422HQ
        case .`4444`:   return .proRes4444
        case .xq:       return .proRes4444XQ
        }
    }

    public var bitDepth: Int {
        switch self {
        case .proxy, .lt, .standard, .hq: return 10
        case .`4444`, .xq: return 12
        }
    }

    public var chromaSubsampling: String {
        switch self {
        case .proxy, .lt, .standard, .hq: return "4:2:2"
        case .`4444`, .xq: return "4:4:4:4"
        }
    }

    public var supportsAlpha: Bool {
        self == .`4444` || self == .xq
    }

    public var approximateBitrateMbps: Int {
        switch self {
        case .proxy:    return 45
        case .lt:       return 102
        case .standard: return 147
        case .hq:       return 220
        case .`4444`:   return 330
        case .xq:       return 500
        }
    }

    public var fourCC: String {
        codec.fourCC
    }
}

// MARK: - Video Resolution

public struct VideoResolution: Codable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let hd720   = VideoResolution(width: 1280, height: 720)
    public static let hd1080  = VideoResolution(width: 1920, height: 1080)
    public static let uhd4K   = VideoResolution(width: 3840, height: 2160)
    public static let dci4K   = VideoResolution(width: 4096, height: 2160)
    public static let sd576i  = VideoResolution(width: 720, height: 576)
    public static let sd480i  = VideoResolution(width: 720, height: 480)

    public var isSD: Bool  { height < 720 }
    public var isHD: Bool  { height >= 720 && height < 2160 }
    public var isUHD: Bool { height >= 2160 }

    public var label: String {
        switch (width, height) {
        case (3840, 2160): return "4K UHD"
        case (4096, 2160): return "4K DCI"
        case (1920, 1080): return "1080p HD"
        case (1440, 1080): return "1080p HD (4:3)"
        case (1280, 720):  return "720p HD"
        case (720, 576):   return "576i SD (PAL)"
        case (720, 480):   return "480i SD (NTSC)"
        default:           return "\(width)x\(height)"
        }
    }
}

// MARK: - Video Profile

public struct VideoProfile: Codable, Equatable {
    public var codec: VideoCodec
    public var container: VideoContainer
    public var resolution: VideoResolution
    public var frameRate: FrameRate
    public var bitDepth: Int
    public var chromaSubsampling: String

    public var dnxHDProfile: DNxHDProfile?
    public var dnxHRProfile: DNxHRProfile?
    public var proResProfile: ProResProfile?

    public init(
        codec: VideoCodec,
        container: VideoContainer,
        resolution: VideoResolution,
        frameRate: FrameRate,
        bitDepth: Int? = nil,
        chromaSubsampling: String? = nil,
        dnxHDProfile: DNxHDProfile? = nil,
        dnxHRProfile: DNxHRProfile? = nil,
        proResProfile: ProResProfile? = nil
    ) {
        self.codec = codec
        self.container = container
        self.resolution = resolution
        self.frameRate = frameRate
        self.dnxHDProfile = dnxHDProfile
        self.dnxHRProfile = dnxHRProfile
        self.proResProfile = proResProfile

        if let bd = bitDepth {
            self.bitDepth = bd
        } else {
            switch codec.family {
            case .proRes: self.bitDepth = proResProfile?.bitDepth ?? 10
            case .avc:    self.bitDepth = 8
            case .hevc:   self.bitDepth = 10
            case .dnx:    self.bitDepth = dnxHRProfile?.bitDepth ?? (dnxHDProfile != nil ? 8 : 8)
            }
        }

        if let cs = chromaSubsampling {
            self.chromaSubsampling = cs
        } else {
            switch codec.family {
            case .proRes: self.chromaSubsampling = proResProfile?.chromaSubsampling ?? "4:2:2"
            case .avc:    self.chromaSubsampling = "4:2:0"
            case .hevc:   self.chromaSubsampling = "4:2:0"
            case .dnx:    self.chromaSubsampling = dnxHRProfile?.chromaSubsampling ?? "4:2:2"
            }
        }
    }

    public var displayName: String {
        var parts: [String] = []
        parts.append(codec.shortName)

        if let prProfile = proResProfile {
            parts = [prProfile.displayName]
        }
        if let hrProfile = dnxHRProfile {
            parts = ["DNxHR \(hrProfile.shortName)"]
        }

        parts.append(resolution.label)
        parts.append("@ \(frameRate.label)")
        parts.append("(\(bitDepth)-bit \(chromaSubsampling))")

        return parts.joined(separator: " ")
    }

    public var isBroadcastSafe: Bool {
        if codec.isProRes || codec.isDNxFamily {
            return container == .mov || container == .mxf
        }
        return false
    }

    public var supportsAlphaChannel: Bool {
        codec == .proRes4444 || codec == .proRes4444XQ || dnxHRProfile == .dnxhr_444
    }
}

// MARK: - Video Format Compatibility

extension VideoProfile {
    public var isValidCombination: Bool {
        guard codec.supportedContainers.contains(container) else { return false }

        switch codec.family {
        case .proRes:
            return true
        case .dnx:
            if codec == .dnxHD {
                if let profile = dnxHDProfile {
                    let (w, h) = profile.resolution
                    return resolution.width == w && resolution.height == h
                }
                return false
            }
            return true
        case .avc, .hevc:
            return true
        }
    }

    public static let presetProRes422HQ1080p25 = VideoProfile(
        codec: .proRes422HQ, container: .mov,
        resolution: .hd1080, frameRate: .fps25,
        proResProfile: .hq
    )

    public static let presetProRes422HQ1080p24000 = VideoProfile(
        codec: .proRes422HQ, container: .mov,
        resolution: .hd1080, frameRate: .fps23_976,
        proResProfile: .hq
    )

    public static let presetProRes422HQ4K25 = VideoProfile(
        codec: .proRes422HQ, container: .mov,
        resolution: .uhd4K, frameRate: .fps25,
        proResProfile: .hq
    )

    public static let presetProRes44441080p25 = VideoProfile(
        codec: .proRes4444, container: .mov,
        resolution: .hd1080, frameRate: .fps25,
        proResProfile: .`4444`
    )

    public static let presetDNxHRHQ1080p25MXF = VideoProfile(
        codec: .dnxHR, container: .mxf,
        resolution: .hd1080, frameRate: .fps25,
        dnxHRProfile: .dnxhr_hq
    )

    public static let presetDNxHRSQ1080p25MOV = VideoProfile(
        codec: .dnxHR, container: .mov,
        resolution: .hd1080, frameRate: .fps25,
        dnxHRProfile: .dnxhr_sq
    )

    public static let presetH2641080p25MP4 = VideoProfile(
        codec: .h264, container: .mp4,
        resolution: .hd1080, frameRate: .fps25
    )

    public static let presetH2654K25MP4 = VideoProfile(
        codec: .h265, container: .mp4,
        resolution: .uhd4K, frameRate: .fps25
    )

    public static let presetDNxHD1080i50120MXF = VideoProfile(
        codec: .dnxHD, container: .mxf,
        resolution: .hd1080, frameRate: .fps25,
        dnxHDProfile: .dnxhd_1080i_50_120
    )
}