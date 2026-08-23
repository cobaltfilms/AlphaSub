import Foundation

/// The text surgery behind splitting and merging cues.
///
/// These are the rules a subtitler leans on all day — where a cue may be cut so
/// the halves are still readable, which whitespace is an artefact of the cut and
/// which is the author's — and they are pure functions over the model: no view
/// model, no AppKit, no selection state.
///
/// They lived as members of `SubtitleDocumentViewModel` in the app target, which
/// has no test target reaching it, so none of this had a single test despite
/// being reachable from every split and merge the user performs. Down here in
/// AlphaSubCore they are testable directly — see `CueEditingTests`.
public enum CueEditing {

    /// Split a cue's lines at `index`, an offset into the cue's plain text
    /// (lines joined with `\n`).
    ///
    /// Returns the blocks before and after the cut. A cut that lands inside a
    /// line splits that line's segments, preserving each one's styling, and
    /// everything after it moves wholesale to the second half. Out-of-range
    /// indices return the input untouched as the first half.
    public static func splitTextBlocks(_ blocks: [TextBlock],
                                       atPlainTextIndex index: Int) -> ([TextBlock], [TextBlock]) {
        guard !blocks.isEmpty, index > 0,
              index < blocks.map(\.plainText).joined(separator: "\n").count
        else { return (blocks, []) }

        var first: [TextBlock] = []
        var second: [TextBlock] = []
        var consumed = 0
        for (bi, block) in blocks.enumerated() {
            let blockText = block.plainText
            let blockLen  = blockText.count
            let blockEnd  = consumed + blockLen
            // Block fully on the first side.
            if blockEnd <= index {
                first.append(block)
                consumed = blockEnd
                if bi < blocks.count - 1 { consumed += 1 /* the \n separator */ }
                continue
            }
            // Block fully on the second side.
            if consumed >= index {
                second.append(block)
                continue
            }
            // Block straddles the split point.
            let cutInBlock = index - consumed
            let (leftSegs, rightSegs) = splitSegments(block.segments, at: cutInBlock)
            if !leftSegs.isEmpty  { first.append(TextBlock(segments: leftSegs)) }
            if !rightSegs.isEmpty { second.append(TextBlock(segments: rightSegs)) }
            // All remaining blocks go wholesale to the second side.
            for trailing in blocks[(bi + 1)...] { second.append(trailing) }
            break
        }
        return (first, second)
    }

    /// Split one line's styled segments at a character offset inside it,
    /// keeping each side's styling intact. A cut inside a segment produces two
    /// segments carrying the same style.
    public static func splitSegments(_ segments: [TextSegment],
                                     at offset: Int) -> ([TextSegment], [TextSegment]) {
        var left: [TextSegment] = []
        var right: [TextSegment] = []
        var consumed = 0
        for seg in segments {
            let segLen = seg.text.count
            let segEnd = consumed + segLen
            if segEnd <= offset {
                left.append(seg)
                consumed = segEnd
                continue
            }
            if consumed >= offset {
                right.append(seg)
                continue
            }
            let cut = offset - consumed
            let leftText  = String(seg.text.prefix(cut))
            let rightText = String(seg.text.suffix(segLen - cut))
            if !leftText.isEmpty  { left.append(TextSegment(text: leftText,  style: seg.style)) }
            if !rightText.isEmpty { right.append(TextSegment(text: rightText, style: seg.style)) }
            consumed = segEnd
        }
        return (left, right)
    }

    /// Drop leading whitespace from the first segment and trailing whitespace
    /// from the last, leaving styling and inner spacing untouched. Blocks that
    /// become empty are removed.
    ///
    /// This is what stops a split from leaving the second half starting with the
    /// space the cut fell on.
    public static func trimmingOuterWhitespace(_ blocks: [TextBlock]) -> [TextBlock] {
        var out = blocks
        if let bi = out.indices.first, let si = out[bi].segments.indices.first {
            var text = out[bi].segments[si].text
            while let f = text.first, f.isWhitespace { text.removeFirst() }
            out[bi].segments[si].text = text
        }
        if let bi = out.indices.last, let si = out[bi].segments.indices.last {
            var text = out[bi].segments[si].text
            while let l = text.last, l.isWhitespace { text.removeLast() }
            out[bi].segments[si].text = text
        }
        return out.filter { !$0.plainText.isEmpty }
    }

    /// The index at or nearest to `index` that falls on a word boundary, so a
    /// split never lands inside a word.
    ///
    /// A boundary is the position *before* a run of whitespace: splitting there
    /// leaves the first half ending on a whole word and the leading space goes
    /// to the second half (which the caller's block split drops). Ties go to the
    /// earlier boundary. Returns `index` unchanged when the text has no
    /// whitespace at all (one long word — nothing better to do).
    public static func wordBoundaryIndex(in text: String, near index: Int) -> Int {
        let chars = Array(text)
        guard !chars.isEmpty else { return index }
        let clamped = Swift.max(0, Swift.min(chars.count, index))

        func isBoundary(_ i: Int) -> Bool {
            // Valid split points: between a non-space and a following space,
            // or at either end of the text.
            if i <= 0 || i >= chars.count { return false }
            let before = chars[i - 1]
            let at = chars[i]
            if before.isWhitespace { return false }   // don't start a half with the rest of a space run
            return at.isWhitespace
        }

        if isBoundary(clamped) { return clamped }
        var left = clamped - 1
        var right = clamped + 1
        while left > 0 || right < chars.count {
            if left > 0, isBoundary(left) { return left }
            if right < chars.count, isBoundary(right) { return right }
            left -= 1
            right += 1
        }
        return index
    }
}

/// Converting a cue's stored position into the 0–100 slider percentages the
/// custom-position UI works in.
///
/// Kept honest in one place because the two ends disagree by convention:
/// vertical is measured *from the bottom* (the DCP convention, 0 = bottom,
/// 100 = top) while horizontal is measured from the left. Getting this wrong is
/// what makes a cue jump the moment custom positioning is switched on.
public enum CuePositionMath {

    /// `VerticalPosition` as a 0–100 percentage up from the bottom.
    ///
    /// `.safeArea(.bottom)` is not 0 %: it renders at the document's configured
    /// vertical position, which the caller passes as `safeAreaBottomPercent`.
    public static func verticalSliderPercent(for position: VerticalPosition,
                                             safeAreaBottomPercent: Double) -> Double {
        switch position {
        case .percentage(let v):  return max(0, min(100, v))
        case .safeArea(.top):     return 100
        case .safeArea(.center):  return 50
        case .safeArea(.bottom):  return max(0, min(100, safeAreaBottomPercent))
        case .row, .lineShift:    return max(0, min(100, safeAreaBottomPercent))
        }
    }

    /// `HorizontalPosition` as a 0–100 percentage from the left
    /// (0 = left, 50 = centred, 100 = right).
    public static func horizontalSliderPercent(for position: HorizontalPosition) -> Double {
        switch position {
        case .percentage(let v): return max(0, min(100, v))
        case .centered:          return 50
        case .leftAligned:       return 0
        case .rightAligned:      return 100
        }
    }
}
