import Foundation

/// Detection of a subtitle track that is on a different **timebase** than the
/// loaded video — i.e. its cue timecodes are expressed against a different
/// origin than the video's own start timecode.
///
/// The everyday cases:
/// - a cinema reel / broadcast master authored at `01:00:00:00` (or
///   `10:00:00:00`) imported against a zero-based video → cues land an hour or
///   more past the end of the timeline, so nothing shows;
/// - a zero-based subtitle file imported against a video that itself carries a
///   `01:00:00:00` program-start timecode → cues land before the video's
///   window.
///
/// "The video's timebase" is its program-start timecode (`videoStartSeconds`,
/// 0 for an ordinary zero-based file). A track is on the SAME timebase when its
/// cues fall inside the video's real timeline window
/// `[videoStart, videoStart + duration]`. When they don't, we propose the
/// whole-hour shift that brings them onto the video's timebase — the user is
/// always free to refuse.
///
/// Pure math so it can be unit-tested; the view model wraps it in the
/// warn-and-propose alert and applies the shift with `Track.offsetAll(by:)`.
public enum TimebaseMismatch {
    /// Tolerance (seconds) for "already inside the window" — a cue may sit a
    /// beat before the first frame or after the last without counting as a
    /// timebase mismatch.
    private static let tolerance: Double = 2.0

    /// The signed number of seconds to ADD to every cue so the track lines up
    /// with the video's timebase, or nil when there is nothing to propose:
    /// - no video duration to compare against,
    /// - the cues already fall inside the video's window (same timebase),
    /// - no whole-hour shift lands the cues inside the window (e.g. simply the
    ///   wrong video — don't propose a nonsensical shift).
    ///
    /// - Parameters:
    ///   - firstCueStart: earliest cue start, in absolute cue seconds.
    ///   - lastCueEnd: latest cue end, in absolute cue seconds.
    ///   - videoStartSeconds: the video's program-start timecode in seconds
    ///     (0 for a zero-based video). This is the video timebase.
    ///   - videoDuration: the video's duration in seconds.
    public static func proposedShiftSeconds(firstCueStart: Double,
                                            lastCueEnd: Double,
                                            videoStartSeconds: Double,
                                            videoDuration: Double) -> Double? {
        guard videoDuration > 0, lastCueEnd >= firstCueStart else { return nil }

        let windowStart = videoStartSeconds
        let windowEnd = videoStartSeconds + videoDuration

        // Already within the video's window (allowing a small tolerance)? Then
        // the subtitles are on the video's timebase — nothing to propose.
        if firstCueStart >= windowStart - tolerance,
           lastCueEnd <= windowEnd + tolerance {
            return nil
        }

        // Snap to the whole-hour shift that best moves the first cue onto the
        // video's start — timebase mismatches are always a whole number of
        // hours (00/01/10 program starts).
        let rawDelta = videoStartSeconds - firstCueStart
        let shiftHours = (rawDelta / 3600).rounded()
        let shift = shiftHours * 3600
        guard shift != 0 else { return nil }

        // The shift must actually bring the cues onto the video's timeline:
        // the first cue has to land inside the window, not before it or past
        // the end (which would mean this isn't a clean timebase offset).
        let newFirst = firstCueStart + shift
        guard newFirst >= windowStart - tolerance,
              newFirst <= windowEnd else { return nil }

        return shift
    }
}
