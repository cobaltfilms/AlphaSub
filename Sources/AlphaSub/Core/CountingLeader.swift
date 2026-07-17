import Foundation

/// Professional video masters place the first frame of the programme (FFOA) on
/// a round hour — 01:00:00:00 or 10:00:00:00 — preceded by a short counting
/// leader (2-pop / SMPTE universal leader, typically ~8–11 seconds). A file
/// whose very first frame reads e.g. 00:59:50:00 is therefore an **hour-01**
/// programme with a 10-second leader, not an hour-00 one.
///
/// This detects that situation from the file's first-frame timecode so the app
/// can (a) report the programme start as the round hour and (b) shade the
/// leader span on the timeline. Crucially it does **not** move the timeline
/// offset: that must stay pinned to the true first frame, or every subtitle
/// slides off the audio.
public enum CountingLeader {
    /// Longest gap (in seconds) before a round hour that is still treated as a
    /// counting leader. Modern SMPTE / 2-pop leaders run ~8–11s; 12s covers
    /// them with a small margin while rejecting genuinely odd start timecodes.
    public static let maxLeaderSeconds: Double = 12.0

    public struct Detection: Equatable {
        /// The round-hour programme start (e.g. 01:00:00:00).
        public let programStart: Timecode
        /// Leader length in seconds (first frame → programme start). Also the
        /// end, in media-time seconds from file start, of the leader region.
        public let leaderSeconds: Double
    }

    /// Returns a detection when `firstFrame` sits within `maxLeaderSeconds`
    /// before a round hour (and isn't already exactly on one); `nil` otherwise.
    public static func detect(firstFrame: Timecode) -> Detection? {
        let secs = firstFrame.seconds
        guard secs > 0 else { return nil }
        let hour = 3600.0
        let nextHour = ((secs / hour).rounded(.down) + 1) * hour
        let gap = nextHour - secs
        guard gap > 0.0001, gap <= maxLeaderSeconds else { return nil }
        let programStart = Timecode(
            h: Int((nextHour / hour).rounded()), m: 0, s: 0, f: 0,
            frameRate: firstFrame.frameRate
        )
        return Detection(programStart: programStart, leaderSeconds: gap)
    }
}
