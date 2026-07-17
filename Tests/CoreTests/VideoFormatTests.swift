import XCTest
import AlphaSubCore

final class VideoFormatTests: XCTestCase {

    // MARK: - VideoContainer

    func testVideoContainerFromExtension() {
        XCTAssertEqual(VideoContainer.from(fileExtension: "mov"), .mov)
        XCTAssertEqual(VideoContainer.from(fileExtension: "mp4"), .mp4)
        XCTAssertEqual(VideoContainer.from(fileExtension: "mxf"), .mxf)
        XCTAssertEqual(VideoContainer.from(fileExtension: "qt"), .mov)
        XCTAssertEqual(VideoContainer.from(fileExtension: "m4v"), .mp4)
        XCTAssertNil(VideoContainer.from(fileExtension: "avi"))
    }

    func testVideoContainerDisplayNames() {
        XCTAssertEqual(VideoContainer.mov.displayName, "QuickTime (.mov)")
        XCTAssertEqual(VideoContainer.mp4.displayName, "MPEG-4 (.mp4)")
        XCTAssertEqual(VideoContainer.mxf.displayName, "MXF (.mxf)")
    }

    func testMXFIsBroadcastContainer() {
        XCTAssertTrue(VideoContainer.mxf.isBroadcastContainer)
        XCTAssertFalse(VideoContainer.mov.isBroadcastContainer)
        XCTAssertFalse(VideoContainer.mp4.isBroadcastContainer)
    }

    // MARK: - VideoCodec

    func testProResCodecs() {
        XCTAssertTrue(VideoCodec.proRes422HQ.isProRes)
        XCTAssertTrue(VideoCodec.proRes4444.isProRes)
        XCTAssertTrue(VideoCodec.proRes422Proxy.isProRes)
        XCTAssertFalse(VideoCodec.h264.isProRes)
    }

    func testDNxCodecs() {
        XCTAssertTrue(VideoCodec.dnxHD.isDNxHD)
        XCTAssertTrue(VideoCodec.dnxHR.isDNxHR)
        XCTAssertTrue(VideoCodec.dnxHD.isDNxFamily)
        XCTAssertTrue(VideoCodec.dnxHR.isDNxFamily)
        XCTAssertFalse(VideoCodec.h264.isDNxFamily)
    }

    func testCodecFamilies() {
        XCTAssertEqual(VideoCodec.proRes422.family, .proRes)
        XCTAssertEqual(VideoCodec.h264.family, .avc)
        XCTAssertEqual(VideoCodec.h265.family, .hevc)
        XCTAssertEqual(VideoCodec.dnxHD.family, .dnx)
        XCTAssertEqual(VideoCodec.dnxHR.family, .dnx)
    }

    func testCodecCompressionType() {
        XCTAssertTrue(VideoCodec.proRes422.isIntraFrame)
        XCTAssertTrue(VideoCodec.dnxHD.isIntraFrame)
        XCTAssertFalse(VideoCodec.h264.isIntraFrame)
        XCTAssertFalse(VideoCodec.h265.isIntraFrame)
        XCTAssertTrue(VideoCodec.h264.isLongGOP)
        XCTAssertTrue(VideoCodec.h265.isLongGOP)
    }

    func testCodecSupportedContainers() {
        XCTAssertTrue(VideoCodec.proRes422.supportedContainers.contains(.mov))
        XCTAssertTrue(VideoCodec.proRes422.supportedContainers.contains(.mp4))
        XCTAssertTrue(VideoCodec.proRes422.supportedContainers.contains(.mxf))
        XCTAssertTrue(VideoCodec.dnxHD.supportedContainers.contains(.mov))
        XCTAssertTrue(VideoCodec.dnxHD.supportedContainers.contains(.mxf))
        XCTAssertFalse(VideoCodec.dnxHD.supportedContainers.contains(.mp4))
        XCTAssertTrue(VideoCodec.h264.supportedContainers.contains(.mov))
        XCTAssertTrue(VideoCodec.h264.supportedContainers.contains(.mp4))
        XCTAssertTrue(VideoCodec.h264.supportedContainers.contains(.mxf))
    }

    func testFourCCs() {
        XCTAssertEqual(VideoCodec.proRes422HQ.fourCC, "apch")
        XCTAssertEqual(VideoCodec.proRes4444.fourCC, "ap4h")
        XCTAssertEqual(VideoCodec.proRes4444XQ.fourCC, "ap4x")
        XCTAssertEqual(VideoCodec.h264.fourCC, "avc1")
        XCTAssertEqual(VideoCodec.h265.fourCC, "hvc1")
        XCTAssertEqual(VideoCodec.dnxHD.fourCC, "AVdh")
    }

    func testCodecDisplayNames() {
        XCTAssertEqual(VideoCodec.proRes422HQ.displayName, "Apple ProRes 422 HQ")
        XCTAssertEqual(VideoCodec.h264.displayName, "H.264 / AVC")
        XCTAssertEqual(VideoCodec.h265.displayName, "H.265 / HEVC")
        XCTAssertEqual(VideoCodec.dnxHR.displayName, "Avid DNxHR")
    }

    // MARK: - ProRes Profiles

    func testProResProfiles() {
        XCTAssertEqual(ProResProfile.hq.codec, .proRes422HQ)
        XCTAssertEqual(ProResProfile.proxy.codec, .proRes422Proxy)
        XCTAssertEqual(ProResProfile.`4444`.codec, .proRes4444)
        XCTAssertEqual(ProResProfile.xq.codec, .proRes4444XQ)
    }

    func testProResBitDepth() {
        XCTAssertEqual(ProResProfile.proxy.bitDepth, 10)
        XCTAssertEqual(ProResProfile.standard.bitDepth, 10)
        XCTAssertEqual(ProResProfile.hq.bitDepth, 10)
        XCTAssertEqual(ProResProfile.`4444`.bitDepth, 12)
        XCTAssertEqual(ProResProfile.xq.bitDepth, 12)
    }

    func testProResAlpha() {
        XCTAssertTrue(ProResProfile.`4444`.supportsAlpha)
        XCTAssertTrue(ProResProfile.xq.supportsAlpha)
        XCTAssertFalse(ProResProfile.hq.supportsAlpha)
        XCTAssertFalse(ProResProfile.standard.supportsAlpha)
    }

    func testProResChroma() {
        XCTAssertEqual(ProResProfile.hq.chromaSubsampling, "4:2:2")
        XCTAssertEqual(ProResProfile.`4444`.chromaSubsampling, "4:4:4:4")
    }

    // MARK: - DNxHD Profiles

    func testDNxHDProfileResolutions() {
        let res1080 = DNxHDProfile.dnxhd_1080i_60_145.resolution
        XCTAssertEqual(res1080.width, 1920)
        XCTAssertEqual(res1080.height, 1080)
        let res720 = DNxHDProfile.dnxhd_720p_60_220.resolution
        XCTAssertEqual(res720.width, 1280)
        XCTAssertEqual(res720.height, 720)
    }

    func testDNxHDProfileBitrates() {
        XCTAssertEqual(DNxHDProfile.dnxhd_1080i_60_145.targetBitrateMbps, 145)
        XCTAssertEqual(DNxHDProfile.dnxhd_720p_25_90.targetBitrateMbps, 90)
    }

    // MARK: - DNxHR Profiles

    func testDNxHRProfiles() {
        XCTAssertEqual(DNxHRProfile.dnxhr_lb.bitDepth, 8)
        XCTAssertEqual(DNxHRProfile.dnxhr_hqx.bitDepth, 10)
        XCTAssertEqual(DNxHRProfile.dnxhr_444.bitDepth, 10)
        XCTAssertEqual(DNxHRProfile.dnxhr_lb.chromaSubsampling, "4:2:2")
        XCTAssertEqual(DNxHRProfile.dnxhr_444.chromaSubsampling, "4:4:4")
    }

    // MARK: - Video Resolution

    func testVideoResolutionPresets() {
        XCTAssertEqual(VideoResolution.hd720, VideoResolution(width: 1280, height: 720))
        XCTAssertEqual(VideoResolution.hd1080, VideoResolution(width: 1920, height: 1080))
        XCTAssertEqual(VideoResolution.uhd4K, VideoResolution(width: 3840, height: 2160))
        XCTAssertEqual(VideoResolution.dci4K, VideoResolution(width: 4096, height: 2160))
    }

    func testVideoResolutionClassification() {
        XCTAssertTrue(VideoResolution.sd480i.isSD)
        XCTAssertTrue(VideoResolution.sd576i.isSD)
        XCTAssertFalse(VideoResolution.hd720.isSD)
        XCTAssertTrue(VideoResolution.hd720.isHD)
        XCTAssertTrue(VideoResolution.hd1080.isHD)
        XCTAssertTrue(VideoResolution.uhd4K.isUHD)
    }

    func testVideoResolutionLabels() {
        XCTAssertEqual(VideoResolution.hd1080.label, "1080p HD")
        XCTAssertEqual(VideoResolution.uhd4K.label, "4K UHD")
        XCTAssertEqual(VideoResolution.dci4K.label, "4K DCI")
        XCTAssertEqual(VideoResolution(width: 2048, height: 858).label, "2048x858")
    }

    // MARK: - VideoProfile

    func testVideoProfilePresets() {
        let p = VideoProfile.presetProRes422HQ1080p25
        XCTAssertEqual(p.codec, .proRes422HQ)
        XCTAssertEqual(p.container, .mov)
        XCTAssertEqual(p.resolution, .hd1080)
        XCTAssertEqual(p.frameRate, .fps25)
        XCTAssertEqual(p.proResProfile, .hq)
    }

    func testVideoProfileDNxHR() {
        let p = VideoProfile.presetDNxHRHQ1080p25MXF
        XCTAssertEqual(p.codec, .dnxHR)
        XCTAssertEqual(p.container, .mxf)
        XCTAssertEqual(p.dnxHRProfile, .dnxhr_hq)
        XCTAssertEqual(p.chromaSubsampling, "4:2:2")
    }

    func testVideoProfileH264() {
        let p = VideoProfile.presetH2641080p25MP4
        XCTAssertEqual(p.codec, .h264)
        XCTAssertEqual(p.container, .mp4)
        XCTAssertEqual(p.resolution, .hd1080)
        XCTAssertNil(p.proResProfile)
        XCTAssertNil(p.dnxHRProfile)
        XCTAssertEqual(p.bitDepth, 8)
        XCTAssertEqual(p.chromaSubsampling, "4:2:0")
    }

    func testVideoProfileDisplayName() {
        let p = VideoProfile.presetProRes422HQ1080p25
        let name = p.displayName
        XCTAssertTrue(name.contains("ProRes"))
        XCTAssertTrue(name.contains("1080p"))
    }

    func testVideoProfileAlphaSupport() {
        let profile4444 = VideoProfile.presetProRes44441080p25
        XCTAssertTrue(profile4444.supportsAlphaChannel)

        let profile422HQ = VideoProfile.presetProRes422HQ1080p25
        XCTAssertFalse(profile422HQ.supportsAlphaChannel)
    }

    func testVideoProfileBroadcastSafety() {
        let proresMXF = VideoProfile(codec: .proRes422HQ, container: .mxf, resolution: .hd1080, frameRate: .fps25, proResProfile: .hq)
        XCTAssertTrue(proresMXF.isBroadcastSafe)

        let h264MP4 = VideoProfile.presetH2641080p25MP4
        XCTAssertFalse(h264MP4.isBroadcastSafe)
    }

    // MARK: - Format Compatibility

    func testValidCodecContainerCombinations() {
        XCTAssertTrue(VideoFormatCompatibility.isValid(codec: .proRes422HQ, container: .mov))
        XCTAssertTrue(VideoFormatCompatibility.isValid(codec: .proRes422HQ, container: .mxf))
        XCTAssertTrue(VideoFormatCompatibility.isValid(codec: .h264, container: .mp4))
        XCTAssertTrue(VideoFormatCompatibility.isValid(codec: .h265, container: .mov))
        XCTAssertTrue(VideoFormatCompatibility.isValid(codec: .dnxHD, container: .mxf))
        XCTAssertTrue(VideoFormatCompatibility.isValid(codec: .dnxHR, container: .mov))
    }

    func testInvalidCodecContainerCombinations() {
        XCTAssertFalse(VideoFormatCompatibility.isValid(codec: .dnxHD, container: .mp4))
    }

    func testProfileValidationValidProfile() {
        let profile = VideoProfile.presetProRes422HQ1080p25
        let issues = VideoFormatCompatibility.validate(profile: profile)
        XCTAssertTrue(issues.isEmpty)
    }

    func testProfileValidationInvalidContainer() {
        let profile = VideoProfile(codec: .dnxHD, container: .mp4, resolution: .hd1080, frameRate: .fps25, dnxHDProfile: .dnxhd_1080i_50_120)
        let issues = VideoFormatCompatibility.validate(profile: profile)
        XCTAssertEqual(issues.count, 1)
    }

    // MARK: - MediaReference Integration

    func testMediaReferenceVideoFields() {
        let url = URL(fileURLWithPath: "/tmp/test.mov")
        let ref = MediaReference(
            url: url,
            videoCodec: .proRes422HQ,
            container: .mov
        )
        XCTAssertEqual(ref.videoCodec, .proRes422HQ)
        XCTAssertEqual(ref.container, .mov)
        XCTAssertEqual(ref.detectedContainer, .mov)
        XCTAssertEqual(ref.displayCodecName, "ProRes 422 HQ")
    }

    func testMediaReferenceFileExtensionDetection() {
        let movURL = URL(fileURLWithPath: "/tmp/test.mov")
        let ref = MediaReference(url: movURL)
        XCTAssertEqual(ref.detectedContainer, .mov)

        let mp4URL = URL(fileURLWithPath: "/tmp/test.mp4")
        let ref2 = MediaReference(url: mp4URL)
        XCTAssertEqual(ref2.detectedContainer, .mp4)

        let mxfURL = URL(fileURLWithPath: "/tmp/test.mxf")
        let ref3 = MediaReference(url: mxfURL)
        XCTAssertEqual(ref3.detectedContainer, .mxf)
    }

    // MARK: - FormatID Video Extensions

    func testVideoFormatIDs() {
        XCTAssertEqual(FormatID.mov.rawValue, "mov")
        XCTAssertEqual(FormatID.mp4.rawValue, "mp4")
        XCTAssertEqual(FormatID.mxf.rawValue, "mxf")
        XCTAssertEqual(FormatID.proRes422HQ.rawValue, "prores_422_hq")
        XCTAssertEqual(FormatID.h264.rawValue, "h264")
        XCTAssertEqual(FormatID.h265.rawValue, "h265")
        XCTAssertEqual(FormatID.dnxHD.rawValue, "dnxhd")
        XCTAssertEqual(FormatID.dnxHR.rawValue, "dnxhr")
    }
}