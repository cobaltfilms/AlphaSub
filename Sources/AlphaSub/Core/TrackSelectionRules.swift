import Foundation

/// Which tracks a whole-track edit applies to.
///
/// Extracted from `SubtitleDocumentViewModel.targetTrackIndices` so it can be
/// tested: the app target has no test target, and this rule governs *every*
/// destructive per-track action — offset, frame-rate relabel, timebase switch,
/// fix gaps. It has produced two real bugs:
///
///   1. A `selectedTrackIDs` set left over from a previously closed document
///      matched no live track, so the rule returned nothing and every
///      whole-track action silently no-oped while the UI still showed a
///      highlighted row.
///   2. Filtering "is selected" and "is unlocked" in a single pass conflated
///      *a stale selection* with *a real selection of locked tracks*. The
///      latter must yield nothing; falling through to the current track instead
///      would edit an unlocked track the user never selected, defeating the
///      lock entirely.
///
/// Hence the two-stage resolution below. It is deliberately verbose about the
/// distinction, because collapsing it is the natural-looking simplification
/// that reintroduces bug 2.
public enum TrackSelectionRules {

    /// Minimal view of a track, so the rule needs no document model.
    public struct Candidate: Equatable, Sendable {
        public let id: UUID
        public let isLocked: Bool

        public init(id: UUID, isLocked: Bool) {
            self.id = id
            self.isLocked = isLocked
        }
    }

    /// Resolve the indices a whole-track edit should touch.
    ///
    /// - Parameters:
    ///   - tracks: all tracks, in document order.
    ///   - selectedIDs: the track-list multi-selection. May contain ids that no
    ///     longer exist, which is treated as *no selection* rather than as an
    ///     empty one.
    ///   - currentIndex: the row the editor is bound to, used when nothing is
    ///     genuinely multi-selected.
    /// - Returns: indices into `tracks`, always excluding locked tracks.
    public static func targetIndices(tracks: [Candidate],
                                     selectedIDs: Set<UUID>,
                                     currentIndex: Int?) -> [Int] {
        if !selectedIDs.isEmpty {
            // Stage 1 — which selected ids still refer to a live track?
            let live = tracks.indices.filter { selectedIDs.contains(tracks[$0].id) }
            if !live.isEmpty {
                // Stage 2 — a real selection. Drop locked tracks, and return
                // the result even when it is empty: "everything I selected is
                // locked" must do nothing, not silently retarget.
                return live.filter { !tracks[$0].isLocked }
            }
            // Otherwise the set is stale. Fall through and behave exactly as if
            // nothing were selected.
        }
        guard let currentIndex,
              tracks.indices.contains(currentIndex),
              !tracks[currentIndex].isLocked else { return [] }
        return [currentIndex]
    }

    /// Why a whole-track edit found nothing to act on, so callers can explain
    /// themselves instead of showing a generic failure.
    public enum EmptyReason: Equatable, Sendable {
        /// Every track in a real multi-selection is locked.
        case allSelectedTracksLocked
        /// Nothing is selected and the current track is locked.
        case currentTrackLocked
        /// There is no track to act on at all.
        case noTrack
    }

    /// Diagnose an empty result. Only meaningful when `targetIndices` returned
    /// `[]` for the same inputs.
    public static func emptyReason(tracks: [Candidate],
                                   selectedIDs: Set<UUID>,
                                   currentIndex: Int?) -> EmptyReason {
        guard !tracks.isEmpty else { return .noTrack }
        let live = tracks.indices.filter { selectedIDs.contains(tracks[$0].id) }
        if !live.isEmpty {
            return live.allSatisfy { tracks[$0].isLocked } ? .allSelectedTracksLocked : .noTrack
        }
        guard let currentIndex, tracks.indices.contains(currentIndex) else { return .noTrack }
        return tracks[currentIndex].isLocked ? .currentTrackLocked : .noTrack
    }
}
