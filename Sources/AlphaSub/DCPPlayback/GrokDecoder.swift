import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Grok JPEG2000 subprocess decoder (open-core)
//
// Decodes a single DCP picture frame (JPEG2000 Part-1 / HTJ2K codestream) to
// pixels by shelling out to Grok's `grk_decompress` CLI. Grok is AGPL-3.0, so
// it is used STRICTLY as a bundled subprocess binary — never linked into the
// AlphaSub app — the same aggregation boundary AlphaSub uses for ffmpeg. The
// Apache-licensed Swift here only `exec`s it.
//
// GOTCHA baked into the design: Grok 20.3.7's intra-frame multithreaded T1
// decode SEGFAULTS on DCI (Rsiz=3) cinema streams. We always pass `-H 1`
// (single thread) — verified rock-solid — and get parallelism instead by
// running several decoders concurrently across frames (a decode-ahead ring
// buffer in the player). One frame = one short-lived, single-threaded process.

public struct GrokDecoder: Sendable {

    public enum DecodeError: LocalizedError {
        case grokMissing
        case decodeFailed(String)
        case badOutput

        public var errorDescription: String? {
            switch self {
            case .grokMissing:
                return String(localized: "The Grok JPEG2000 decoder (grk_decompress) wasn't found. It ships with AlphaSub; reinstall the latest release, or install it with `brew install grokj2k`.")
            case .decodeFailed(let m):
                return String(localized: "JPEG2000 decode failed: \(m)")
            case .badOutput:
                return String(localized: "The JPEG2000 decoder produced an unreadable image.")
            }
        }
    }

    /// Test/override hook: an explicit path to `grk_decompress`.
    public var binaryOverride: String?
    /// Process QoS for the `grk_decompress` subprocess. Playback uses
    /// `.utility` so decode never starves the UI thread; offline export
    /// uses `.userInitiated` for maximum throughput.
    public var qualityOfService: QualityOfService

    public init(binaryOverride: String? = nil,
                qualityOfService: QualityOfService = .utility) {
        self.binaryOverride = binaryOverride
        self.qualityOfService = qualityOfService
    }

    /// Resolved path to `grk_decompress`: an explicit override, then a bundled
    /// copy in the app's Resources (`grok/grk_decompress`), then Homebrew /
    /// system locations for development builds.
    public var resolvedBinary: String? {
        if let binaryOverride { return binaryOverride }
        if let bundled = Self.bundledPath() { return bundled }
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin"]
        for dir in dirs {
            let p = "\(dir)/grk_decompress"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    public var isAvailable: Bool { resolvedBinary != nil }

    private static func bundledPath() -> String? {
        let fm = FileManager.default
        let rel = "grok/grk_decompress"
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }
        roots.append(Bundle.main.bundleURL)
        roots.append(Bundle.main.bundleURL.appendingPathComponent("AlphaSub_AlphaSubApp.bundle"))
        if let r = Bundle.main.resourceURL {
            roots.append(r.appendingPathComponent("AlphaSub_AlphaSubApp.bundle"))
        }
        for root in roots {
            let p = root.appendingPathComponent(rel)
            if fm.isExecutableFile(atPath: p.path) { return p.path }
        }
        return nil
    }

    /// A raw decoded frame: planar, component-major, native-endian 16-bit (or
    /// 8-bit) samples straight from Grok. For DCI content this is X'Y'Z' at
    /// 12-bit stored in 16 — colour conversion to display RGB happens
    /// downstream (deliberately, on the GPU).
    public struct DecodedFrame: Sendable {
        public let info: J2KCodestreamInfo
        /// `componentCount` planes, each `width*height` samples, in order.
        /// 16-bit samples are little-endian (Grok `rawl`).
        public let planarData: Data
    }

    /// FAST PATH (~10 ms for a 2K frame): decode a J2K codestream to planar
    /// raw samples via `--out-fmt rawl` on stdout — no TIFF/PNG encode, no
    /// temp output file. The geometry comes from the codestream's own SIZ, so
    /// the returned buffer is fully described. Single-threaded (`-H 1`).
    public func decodeToPlanar(_ codestream: Data, reduce: Int = 0) throws -> DecodedFrame {
        guard let grok = resolvedBinary else { throw DecodeError.grokMissing }
        let fullInfo = try J2KCodestreamInfo(codestream: codestream)
        let info = fullInfo.reduced(by: reduce)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alphasub-dcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let inURL = tmp.appendingPathComponent("\(UUID().uuidString).j2k")
        defer { try? FileManager.default.removeItem(at: inURL) }
        try codestream.write(to: inURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: grok)
        proc.qualityOfService = qualityOfService
        // rawl = little-endian planar; stdout requires NO -o. `-r` decodes at a
        // reduced resolution (each level halves the canvas) for fast preview.
        var args = ["-i", inURL.path, "--out-fmt", "rawl", "-H", "1"]
        if reduce > 0 { args += ["-r", String(reduce)] }
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Drain stdout on a background thread so a large frame can't deadlock
        // the pipe while the process is still writing.
        var outData = Data()
        let outHandle = outPipe.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outHandle.readDataToEndOfFile()
            group.leave()
        }
        do { try proc.run() } catch {
            throw DecodeError.decodeFailed(error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        group.wait()

        guard proc.terminationStatus == 0 else {
            let tail = String(data: errData, encoding: .utf8)?
                .split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
            throw DecodeError.decodeFailed(tail.isEmpty
                ? "grk_decompress exited \(proc.terminationStatus)" : tail)
        }
        guard outData.count == info.planarByteCount else {
            throw DecodeError.decodeFailed(
                "raw output \(outData.count) B ≠ expected \(info.planarByteCount) B "
                + "(\(info.width)×\(info.height)×\(info.componentCount)@\(info.precision)b)")
        }
        return DecodedFrame(info: info, planarData: outData)
    }

    /// Decodes a J2K codestream to a CGImage. The returned image carries the
    /// raw decoded samples (X'Y'Z' for DCI content) — colour management to
    /// display RGB is applied downstream, deliberately, so the player can do
    /// it accurately on the GPU. Runs one single-threaded `grk_decompress`.
    public func decodeToCGImage(_ codestream: Data) throws -> CGImage {
        guard let grok = resolvedBinary else { throw DecodeError.grokMissing }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alphasub-dcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let stem = UUID().uuidString
        let inURL = tmp.appendingPathComponent("\(stem).j2k")
        let outURL = tmp.appendingPathComponent("\(stem).tif")
        defer {
            try? FileManager.default.removeItem(at: inURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        try codestream.write(to: inURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: grok)
        // -H 1: single thread — avoids the 20.3.7 multithread T1 segfault on
        // DCI streams. TIFF preserves the 12/16-bit precision.
        proc.arguments = ["-i", inURL.path, "-o", outURL.path, "-H", "1"]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw DecodeError.decodeFailed(error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outURL.path) else {
            let tail = String(data: errData, encoding: .utf8)?
                .split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
            throw DecodeError.decodeFailed(tail.isEmpty
                ? "grk_decompress exited \(proc.terminationStatus)" : tail)
        }

        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw DecodeError.badOutput
        }
        return image
    }
}
