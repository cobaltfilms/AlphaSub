import Foundation

// MARK: - ContextWindow
//
// Computes the media window around a subtitle cue for multimodal
// context improvement. The window is padded symmetrically around the
// cue and then clamped to the model's hard limits:
//   - Audio: Gemma 4 / 3n accept at most 30 s of audio per request.
//   - Video: at 1 fps, at most 60 frames per request (60 s of video).
//
// The same window is used for both audio and frame extraction so the
// model sees time-aligned media. In `audioOnly` mode the frame range
// is unused.
//
// Lives in AlphaSubCore because it's a pure value type with no
// dependencies on AI or transcription machinery; the actual extraction
// (`MediaClipExtractor`) lives in AlphaSubTranscription where the
// ffmpeg infrastructure is.

public struct ContextWindow: Sendable, Equatable {
    public let audioStart: Double
    public let audioEnd: Double
    public let frameStart: Double
    public let frameEnd: Double
    public let mode: ContextMode

    public enum ContextMode: String, Sendable, CaseIterable {
        case audioOnly
        case audioAndVideo

        public var localizedName: String {
            switch self {
            case .audioOnly:      return String(localized: "Audio only")
            case .audioAndVideo:  return String(localized: "Audio + Video")
            }
        }
    }

    public init(audioStart: Double, audioEnd: Double,
                frameStart: Double, frameEnd: Double,
                mode: ContextMode) {
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.frameStart = frameStart
        self.frameEnd = frameEnd
        self.mode = mode
    }

    /// Default padding around the cue (seconds on each side).
    public static let paddingSeconds: Double = 6.0
    /// Gemma 4 / 3n hard limit for audio input.
    public static let maxAudioSeconds: Double = 30.0
    /// At 1 fps, Gemma accepts at most 60 frames.
    public static let maxFrames: Int = 60
    public static let framesPerSecond: Double = 1.0

    /// Compute the context window for a cue.
    ///
    /// - Parameters:
    ///   - cueStart: cue start time in seconds (absolute, from media start).
    ///   - cueEnd: cue end time in seconds.
    ///   - mediaDuration: total media duration in seconds (to clamp the
    ///     end). Pass `.infinity` if unknown.
    ///   - mode: audio only, or audio + video.
    public static func window(
        cueStart: Double,
        cueEnd: Double,
        mediaDuration: Double,
        mode: ContextMode
    ) -> ContextWindow {
        let pad = paddingSeconds
        let maxAudio = maxAudioSeconds

        // Audio: pad ±6 s, clamp to [0, duration], clamp to 30 s.
        var aStart = max(0, cueStart - pad)
        var aEnd = min(mediaDuration, cueEnd + pad)
        // If the padded window exceeds the audio cap, center it on the
        // cue midpoint and truncate.
        let cueMid = (cueStart + cueEnd) / 2
        if aEnd - aStart > maxAudio {
            aStart = max(0, cueMid - maxAudio / 2)
            aEnd = aStart + maxAudio
            if aEnd > mediaDuration {
                aEnd = mediaDuration
                aStart = max(0, aEnd - maxAudio)
            }
        }

        // Frames: same window as audio (so frames are time-aligned with
        // the audio clip), capped at maxFrames by limiting the duration
        // to maxFrames / fps. In `audioOnly` mode the frame range is
        // zero-length and unused.
        let fStart: Double
        let fEnd: Double
        if mode == .audioAndVideo {
            let maxFrameWindow = Double(maxFrames) / framesPerSecond
            var fS = aStart
            var fE = aEnd
            if fE - fS > maxFrameWindow {
                fS = max(0, cueMid - maxFrameWindow / 2)
                fE = fS + maxFrameWindow
                if fE > mediaDuration {
                    fE = mediaDuration
                    fS = max(0, fE - maxFrameWindow)
                }
            }
            fStart = fS
            fEnd = fE
        } else {
            fStart = cueStart
            fEnd = cueEnd
        }

        return ContextWindow(
            audioStart: aStart, audioEnd: aEnd,
            frameStart: fStart, frameEnd: fEnd,
            mode: mode
        )
    }

    public var audioDuration: Double { max(0, audioEnd - audioStart) }
    public var frameDuration: Double { max(0, frameEnd - frameStart) }
    public var expectedFrameCount: Int {
        mode == .audioAndVideo
            ? min(ContextWindow.maxFrames,
                  Int((frameDuration * ContextWindow.framesPerSecond).rounded(.up)))
            : 0
    }
}