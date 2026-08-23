import Foundation

/// The "Fix Gaps & Timing" pass, as a pure function over a track's cues.
///
/// The rule this encodes is narrower than it looks, and the narrowing was
/// learned the hard way — see ``fixTiming(_:frameRate:gapFrames:minFrames:maxFrames:options:)``.
/// It lived on the view model, where the delivery specs it enforces could not be
/// tested against; here it takes cues in and gives cues back.
public enum TimingRules {

    /// Which corrections the pass should apply. Each maps to a checkbox in the
    /// Fix Timing sheet, so the user picks exactly what runs rather than getting
    /// all of it (issue #34).
    public struct Options: Equatable {
        /// Extend cues that are on screen too briefly.
        public var fixMinDuration: Bool
        /// Keep the minimum gap, and remove overlaps.
        public var enforceGaps: Bool
        /// Shorten cues that stay on screen too long.
        public var fixMaxDuration: Bool
        /// Pull apart cues that are stitched together — the out-point sitting
        /// on the next cue's in-point — so they get the full minimum gap.
        /// Only meaningful alongside `enforceGaps`.
        ///
        /// On by default: a stitched pair puts the same frame at the end of one
        /// cue and the start of the next, which is what the delivery specs mean
        /// by "no gap" (easyDCP: "Timed Text Spots shall have … a gap of at
        /// least two frames inbetween each other"). Turn it off for a house
        /// style that butts cues deliberately.
        public var separateStitched: Bool

        public init(fixMinDuration: Bool = true,
                    enforceGaps: Bool = true,
                    fixMaxDuration: Bool = false,
                    separateStitched: Bool = true) {
            self.fixMinDuration = fixMinDuration
            self.enforceGaps = enforceGaps
            self.fixMaxDuration = fixMaxDuration
            self.separateStitched = separateStitched
        }

        public var isEmpty: Bool { !fixMinDuration && !enforceGaps && !fixMaxDuration }
    }

    /// Outcome of a pass.
    public struct Result: Equatable {
        /// Cues whose out-point moved.
        public var changed: Int
        /// Cues still under the minimum duration afterwards, because the
        /// following cue starts too soon to make room. Counted rather than
        /// hidden — the silent failure behind issue #36.
        public var unresolvedShort: Int
        /// Cues that still don't have the full gap to the next one afterwards,
        /// because pulling the out-point back any further would collapse the
        /// cue. Counted for the same reason as `unresolvedShort`.
        public var unresolvedGap: Int

        public init(changed: Int = 0, unresolvedShort: Int = 0, unresolvedGap: Int = 0) {
            self.changed = changed
            self.unresolvedShort = unresolvedShort
            self.unresolvedGap = unresolvedGap
        }
    }

    /// Recompute out-points for one track's cues. Returns the new cues and what
    /// the pass did; the caller decides whether to preview or apply.
    ///
    /// Only out-points move — in-points are the subtitler's timing decisions and
    /// are never touched — and a cue is never collapsed below one frame.
    ///
    /// The subtle part is what "a legal gap" means, and it has moved once. The
    /// pass used to treat a STITCHED pair — one cue's out-point sitting on the
    /// next cue's in-point, gap 0 — as legal and leave it alone, on the theory
    /// that specs allow either a butt or a full gap. They don't: a stitched
    /// pair shows the same frame as the last frame of one cue and the first
    /// frame of the next, and the delivery specs ask for real separation
    /// (easyDCP: "Timed Text Spots shall have a minimum duration of 15 frames
    /// and a gap of at least two frames inbetween each other"). So with
    /// `separateStitched` on — the default — anything from an overlap up to
    /// `gapFrames - 1` is opened to the full gap, and only a gap already at or
    /// above the minimum is left alone. Turning the option off restores the
    /// old butt-preserving behaviour for a house style that wants it.
    public static func fixTiming(_ subtitles: [Subtitle],
                                 frameRate: FrameRate,
                                 gapFrames: Int,
                                 minFrames: Int64,
                                 maxFrames: Int64,
                                 options: Options) -> (subtitles: [Subtitle], result: Result) {
        var subs = subtitles
        var result = Result()
        let gapF = Int64(max(0, gapFrames))

        for i in subs.indices {
            let start = subs[i].startTime.totalFrames
            let end = subs[i].endTime.totalFrames
            var desired = end

            // Extend to the minimum duration…
            if options.fixMinDuration { desired = max(desired, start + minFrames) }
            // …cap over-long cues…
            if options.fixMaxDuration { desired = min(desired, start + maxFrames) }
            // …then clamp so the gap to the next cue is LEGAL (see above).
            var nextStart: Int64? = nil
            if options.enforceGaps, i + 1 < subs.count {
                let ns = subs[i + 1].startTime.totalFrames
                nextStart = ns
                // The floor below which the gap is wrong. With
                // `separateStitched` off a stitched pair (gap exactly 0) is
                // still accepted, so only a positive-but-too-small gap and a
                // real overlap are corrected.
                let gap = ns - desired
                let stitchedIsLegal = !options.separateStitched
                if gap < 0 || (gap == 0 && !stitchedIsLegal) || (gap > 0 && gap < gapF) {
                    if gap < 0 && stitchedIsLegal && ns - end == 0 {
                        // Was already butted before the pass and butts are
                        // allowed: a min-duration extension must not force it
                        // apart, so put it back where it was.
                        desired = ns
                    } else {
                        desired = ns - gapF
                    }
                }
            }

            if desired < start + 1 { desired = start + 1 }   // never collapse a cue

            // Either clamp can leave a cue short of what it was supposed to
            // reach — surface it instead of failing silently.
            if options.fixMinDuration && (desired - start) < minFrames {
                result.unresolvedShort += 1
            }
            if let ns = nextStart, options.separateStitched, gapF > 0, ns - desired < gapF {
                result.unresolvedGap += 1
            }
            if desired != end {
                subs[i].endTime = Timecode(totalFrames: desired, frameRate: frameRate)
                result.changed += 1
            }
        }
        return (subs, result)
    }
}
