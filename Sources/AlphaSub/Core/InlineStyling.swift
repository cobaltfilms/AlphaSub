import Foundation

/// Inline (part-of-a-line) styling: italicising one word, not the whole cue.
///
/// The model has always been able to hold it — a `TextBlock` is a list of
/// `TextSegment`s, each with its own `TextStyle` and colour, and both DCP
/// formats carry it on the wire (`<Text>` is mixed content in ST 428-7 and
/// InterOp alike, so a nested `<Font Italic="yes">` may wrap a single word).
/// What was missing was any way to *address* part of a cue: the toggles walked
/// every segment, and the editor rebuilt the cue from a plain `String` on every
/// keystroke, which flattened imported styling back to nothing.
///
/// These are pure functions over a cue's blocks, addressed by character offsets
/// into the cue's plain text (its lines joined with `\n`) — the same coordinate
/// space `CueEditing.splitTextBlocks(_:atPlainTextIndex:)` already uses. Offsets
/// are in `Character`s, not UTF-16 units; AppKit hands out UTF-16 `NSRange`s, so
/// the UI converts at the boundary rather than letting two coordinate systems
/// loose in the model.
///
/// The implementation expands a cue to one attribute per character, mutates
/// that, and coalesces back into segments. A cue is a couple of hundred
/// characters at most, and the alternative — segment-boundary surgery for every
/// operation — is where this kind of code goes wrong.
public enum InlineStyling {

    /// A stretch of the cue's plain text that shares one style and colour.
    public struct Run: Equatable {
        /// Character offsets into the cue's plain text (lines joined with `\n`).
        public var range: Range<Int>
        public var style: TextStyle
        public var color: TextColor?

        public init(range: Range<Int>, style: TextStyle, color: TextColor? = nil) {
            self.range = range
            self.style = style
            self.color = color
        }
    }

    /// One character's styling. Private: the public currency is `Run`.
    private struct Attr: Equatable {
        var style: TextStyle = []
        var color: TextColor?
    }

    // MARK: - Reading

    /// The cue's plain text: its lines joined with `\n`.
    public static func plainText(_ blocks: [TextBlock]) -> String {
        blocks.map(\.plainText).joined(separator: "\n")
    }

    /// The styled runs over that plain text, in order, merged so that adjacent
    /// runs never share the same style *and* colour. Unstyled stretches are
    /// included (with an empty style) so the runs tile the whole string.
    public static func runs(of blocks: [TextBlock]) -> [Run] {
        let attrs = flatten(blocks).map(\.attr)
        var result: [Run] = []
        var start = 0
        var i = 0
        while i < attrs.count {
            if attrs[i] != attrs[start] {
                result.append(Run(range: start..<i, style: attrs[start].style, color: attrs[start].color))
                start = i
            }
            i += 1
        }
        if start < attrs.count {
            result.append(Run(range: start..<attrs.count, style: attrs[start].style, color: attrs[start].color))
        }
        return result
    }

    /// The cue's text with its inline styling shown as tags — `<i>`, `<b>`,
    /// `<u>` — for places that can only display a plain string, such as a
    /// table row. Not a file format: it is how the styling is *read out*, so
    /// that a cue carrying one italic word is distinguishable at a glance from
    /// one that does not.
    public static func markup(of blocks: [TextBlock]) -> String {
        blocks.map { block in
            block.segments.map { segment -> String in
                var text = segment.text
                // Innermost first, so the tags nest in a stable order.
                if segment.style.contains(.underline) { text = "<u>\(text)</u>" }
                if segment.style.contains(.bold)      { text = "<b>\(text)</b>" }
                if segment.style.contains(.italic)    { text = "<i>\(text)</i>" }
                return text
            }.joined()
        }.joined(separator: "\n")
    }

    /// Whether every character in `range` already carries `flag` — what decides
    /// which way a toggle goes. An empty or out-of-range selection is `false`,
    /// so a toggle over nothing turns the style *on*.
    public static func styleIsUniform(_ flag: TextStyle, in range: Range<Int>,
                                      of blocks: [TextBlock]) -> Bool {
        let attrs = flatten(blocks).map(\.attr)
        let r = clamp(range, to: attrs.count)
        guard !r.isEmpty else { return false }
        return attrs[r].allSatisfy { $0.style.contains(flag) }
    }

    /// The colour shared by every character in `range`, or `nil` when they
    /// differ, when the range is empty, or when the characters carry no colour
    /// of their own. Companion to `styleIsUniform` for the formatting bar's
    /// colour swatch, which must report the run under the caret rather than
    /// the first run of the cue.
    public static func uniformColor(in range: Range<Int>, of blocks: [TextBlock]) -> TextColor? {
        let attrs = flatten(blocks).map(\.attr)
        let r = clamp(range, to: attrs.count)
        guard let first = attrs[r].first else { return nil }
        return attrs[r].allSatisfy({ $0.color == first.color }) ? first.color : nil
    }

    /// The range a caret-or-selection should be *read* through.
    ///
    /// A selection reads as itself. A bare caret reads as the character BEFORE
    /// it — the one whose styling typing would inherit (`applyPlainText`), so
    /// the Italic button lights up exactly when the next character typed would
    /// come out italic. At offset 0 there is nothing before, so it reads the
    /// character after. `nil` selection means the whole cue, which is also the
    /// scope a toggle then applies to.
    public static func probeRange(for selection: Range<Int>?, in blocks: [TextBlock]) -> Range<Int> {
        let length = plainText(blocks).count
        guard let selection else { return 0..<length }
        guard selection.isEmpty else { return selection }
        let caret = min(max(selection.lowerBound, 0), length)
        if caret > 0 { return (caret - 1)..<caret }
        return 0..<min(1, length)
    }

    // MARK: - Writing

    /// Toggle `flag` over a character range: on unless every character in the
    /// range already has it, in which case off. Blocks outside the range — and
    /// every block's language and per-line position — are untouched.
    public static func toggleStyle(_ flag: TextStyle, in range: Range<Int>,
                                   of blocks: [TextBlock]) -> [TextBlock] {
        var chars = flatten(blocks)
        let r = clamp(range, to: chars.count)
        guard !r.isEmpty else { return blocks }
        let allHave = chars[r].allSatisfy { $0.attr.style.contains(flag) }
        for i in r {
            if allHave { chars[i].attr.style.subtract(flag) }
            else       { chars[i].attr.style.formUnion(flag) }
        }
        return rebuild(chars, like: blocks)
    }

    /// Set (or clear, with `nil`) the colour over a character range.
    public static func setColor(_ color: TextColor?, in range: Range<Int>,
                                of blocks: [TextBlock]) -> [TextBlock] {
        var chars = flatten(blocks)
        let r = clamp(range, to: chars.count)
        guard !r.isEmpty else { return blocks }
        for i in r { chars[i].attr.color = color }
        return rebuild(chars, like: blocks)
    }

    /// Replace the cue's text with `newText`, carrying the existing styling
    /// across the edit.
    ///
    /// The editor is a plain-text view: it hands back a whole `String`, not a
    /// description of what changed. Comparing the common prefix and suffix
    /// recovers the edit — which is exact for the one-insertion-or-deletion
    /// shape typing actually produces, and degrades gracefully for a paste.
    /// Text that survived keeps its own styling; inserted text inherits the
    /// character before it (the rule a text view itself uses for typing
    /// attributes), or the character after it when inserting at the very start.
    ///
    /// One `TextBlock` per display line is preserved — the invariant every
    /// exporter relies on — and each line keeps the language and per-line
    /// position of the line that was at that index before the edit.
    public static func applyPlainText(_ newText: String, to blocks: [TextBlock]) -> [TextBlock] {
        let old = flatten(blocks)
        let new = Array(newText)
        guard old.map(\.ch) != new else { return blocks }

        // Longest common prefix, then longest common suffix of what is left.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].ch == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix].ch == new[new.count - 1 - suffix] { suffix += 1 }

        // What inserted characters inherit: the surviving character before the
        // insertion point, else the one after it, else nothing.
        let inherited: Attr
        if prefix > 0 { inherited = old[prefix - 1].attr }
        else if old.count - suffix < old.count { inherited = old[old.count - suffix].attr }
        else { inherited = Attr() }

        var chars: [(ch: Character, attr: Attr)] = []
        chars.reserveCapacity(new.count)
        for (i, ch) in new.enumerated() {
            if i < prefix {
                chars.append((ch, old[i].attr))
            } else if i >= new.count - suffix {
                chars.append((ch, old[old.count - (new.count - i)].attr))
            } else {
                chars.append((ch, inherited))
            }
        }
        return rebuild(chars, like: blocks)
    }

    // MARK: - Rewriting by a tool

    /// Replace the cue's text with `newText` when the change may be anywhere
    /// and in several places at once — what a tool does, as opposed to typing.
    ///
    /// A re-wrap moves every line break; a typography or spelling pass edits
    /// wherever it finds something. `applyPlainText` would treat everything
    /// between the first and the last change as one replacement and give it a
    /// single style, which is how a re-wrapped cue used to lose its italics.
    /// This aligns the two texts character by character instead:
    ///
    /// * a character that survives keeps its own style and colour;
    /// * text that *replaces* something takes the style of what it replaces
    ///   (a corrected word stays italic);
    /// * other inserted text inherits the character before it, as typing does;
    /// * inserted whitespace between two differently styled characters is
    ///   unstyled, so a run never creeps across the gap a re-wrap just closed.
    ///
    /// The result is one `TextBlock` per display line. With the same number of
    /// lines each keeps its language and its own position. When the number of
    /// lines changes, a language shared by every line carries to the new ones,
    /// and individually positioned lines (a DCP import) are re-stacked: the
    /// line the stack hangs from stays where it was (the last for a cue in the
    /// lower half of the picture, the first for one in the upper half, the
    /// middle for one centred) and the others step away from it by the
    /// spacing the cue already uses, or by `lineSpacing` when the cue had a
    /// single line and so no spacing of its own (pass the track's, from
    /// `LayoutConsensus.lineSpacing(of:)`). With no spacing to go by, the
    /// per-line positions are dropped and the lines hang together from the
    /// cue's position — a half-positioned stack would overlap.
    public static func applyRewrittenText(_ newText: String, to blocks: [TextBlock],
                                          lineSpacing: Double? = nil) -> [TextBlock] {
        let old = flatten(blocks)
        let new = Array(newText)
        let oldChars = old.map(\.ch)
        guard oldChars != new else { return blocks }

        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: oldChars) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Walk the edit script in order. `replaced` is the style of the first
        // real character removed since the last surviving one: what an
        // insertion at this point is standing in for.
        var attrs: [Attr?] = []
        attrs.reserveCapacity(new.count)
        var replaced: Attr?
        var oi = 0
        for ni in new.indices {
            while removed.contains(oi) {
                if replaced == nil, old[oi].ch != "\n", !old[oi].ch.isWhitespace { replaced = old[oi].attr }
                oi += 1
            }
            if inserted.contains(ni) {
                attrs.append(new[ni].isWhitespace ? nil : replaced)
            } else {
                attrs.append(old[oi].attr)
                oi += 1
                replaced = nil
            }
        }

        return rebuild(resolved(new, attrs), like: blocks, restackingWith: .some(lineSpacing))
    }

    /// Divide a cue among `texts`, consecutive pieces of its own text — the
    /// speakers of a dialogue cue being split into one cue each.
    ///
    /// Each piece takes its characters' styling from the original *in order*:
    /// the second piece starts looking where the first one stopped. Aligning
    /// every piece against the whole cue instead would let two speakers who say
    /// the same word share the styling of whichever said it first. Characters
    /// the pieces leave out (the dialogue dashes) are simply skipped.
    public static func dividing(_ blocks: [TextBlock], into texts: [String],
                                lineSpacing: Double? = nil) -> [[TextBlock]] {
        let old = flatten(blocks)
        var cursor = 0
        return texts.map { text in
            let new = Array(text)
            var attrs: [Attr?] = []
            attrs.reserveCapacity(new.count)
            for ch in new {
                guard !ch.isWhitespace,
                      let found = old[cursor...].firstIndex(where: { $0.ch == ch })
                else { attrs.append(nil); continue }
                attrs.append(old[found].attr)
                cursor = found + 1
            }
            return rebuild(resolved(new, attrs), like: blocks, restackingWith: .some(lineSpacing))
        }
    }

    /// Give every character an `Attr`: its own when known, otherwise from its
    /// neighbours — the character before it, as typing does; unstyled for
    /// whitespace that sits between two differently styled characters.
    private static func resolved(_ new: [Character], _ attrs: [Attr?]) -> [(ch: Character, attr: Attr)] {
        var chars: [(ch: Character, attr: Attr)] = []
        chars.reserveCapacity(new.count)
        for (i, ch) in new.enumerated() {
            if let attr = attrs[i] { chars.append((ch, attr)); continue }
            let before = chars.last(where: { $0.ch != "\n" })?.attr
            let after = new.indices[(i + 1)...]
                .first(where: { new[$0] != "\n" && attrs[$0] != nil })
                .flatMap { attrs[$0] }
            if ch.isWhitespace {
                chars.append((ch, before == after ? (before ?? Attr()) : Attr()))
            } else {
                chars.append((ch, before ?? after ?? Attr()))
            }
        }
        return chars
    }

    /// Replace the cue's text wholesale — a translation — where the new words
    /// have no character-level relation to the old ones.
    ///
    /// Styling is carried only where that is unambiguous: a cue that was
    /// uniformly styled stays so, and when the number of lines is unchanged
    /// each uniformly styled line keeps its own (an italic line over a plain
    /// one). One italic word among plain ones cannot be mapped onto different
    /// words, and guessing would italicise the wrong one, so mixed styling is
    /// dropped. Lines, languages and positions follow `applyRewrittenText`.
    public static func applyReplacementText(_ newText: String, to blocks: [TextBlock],
                                            lineSpacing: Double? = nil) -> [TextBlock] {
        func uniform(_ block: [TextBlock]) -> Attr? {
            let visible = flatten(block).filter { !$0.ch.isWhitespace }
            guard let first = visible.first?.attr else { return Attr() }
            return visible.allSatisfy { $0.attr == first } ? first : nil
        }
        let newLines = newText.components(separatedBy: "\n")
        let perLine: [Attr]
        if let whole = uniform(blocks) {
            perLine = Array(repeating: whole, count: newLines.count)
        } else if newLines.count == blocks.count {
            perLine = blocks.map { uniform([$0]) ?? Attr() }
        } else {
            perLine = Array(repeating: Attr(), count: newLines.count)
        }
        var chars: [(ch: Character, attr: Attr)] = []
        for (index, line) in newLines.enumerated() {
            if index > 0 { chars.append(("\n", Attr())) }
            for ch in line { chars.append((ch, perLine[index])) }
        }
        return rebuild(chars, like: blocks, restackingWith: .some(lineSpacing))
    }

    // MARK: - Flatten / rebuild

    private static func flatten(_ blocks: [TextBlock]) -> [(ch: Character, attr: Attr)] {
        var chars: [(ch: Character, attr: Attr)] = []
        for (bi, block) in blocks.enumerated() {
            if bi > 0 { chars.append(("\n", Attr())) }
            for seg in block.segments {
                let attr = Attr(style: seg.style, color: seg.color)
                for ch in seg.text { chars.append((ch, attr)) }
            }
        }
        return chars
    }

    /// Coalesce characters back into one block per line, taking each line's
    /// language and per-line position from the block that was at that index.
    /// Lines beyond the original count carry none — the same as a cue whose
    /// text was typed from scratch.
    ///
    /// `restackingWith` is for tools, which change the number of lines on
    /// purpose: `nil` keeps the by-index rule above (typing); `.some(spacing)`
    /// re-derives per-line attributes when the line count changes, as
    /// `applyRewrittenText` describes.
    private static func rebuild(_ chars: [(ch: Character, attr: Attr)],
                                like template: [TextBlock],
                                restackingWith restack: Double?? = nil) -> [TextBlock] {
        var lines: [[(ch: Character, attr: Attr)]] = [[]]
        for c in chars {
            if c.ch == "\n" { lines.append([]) } else { lines[lines.count - 1].append(c) }
        }
        if let spacing = restack, lines.count != template.count, !template.isEmpty {
            return restacked(lines, like: template, lineSpacing: spacing)
        }
        return lines.enumerated().map { (index, line) in
            let source = index < template.count ? template[index] : nil
            return TextBlock(segments: segments(of: line),
                             language: source?.language,
                             verticalPosition: source?.verticalPosition,
                             horizontalPosition: source?.horizontalPosition)
        }
    }

    private static func segments(of line: [(ch: Character, attr: Attr)]) -> [TextSegment] {
        var segments: [TextSegment] = []
        for c in line {
            if var last = segments.last, last.style == c.attr.style, last.color == c.attr.color {
                last.text.append(c.ch)
                segments[segments.count - 1] = last
            } else {
                segments.append(TextSegment(text: String(c.ch), style: c.attr.style, color: c.attr.color))
            }
        }
        return segments.isEmpty ? [TextSegment(text: "", style: [])] : segments
    }

    /// Per-line attributes for a cue whose number of lines a tool has changed.
    private static func restacked(_ lines: [[(ch: Character, attr: Attr)]],
                                  like template: [TextBlock],
                                  lineSpacing: Double?) -> [TextBlock] {
        // A language every line shared is the cue's language; one that only
        // some lines had belongs to those lines and cannot be reassigned.
        let languages = Set(template.map(\.language))
        let language = languages.count == 1 ? template[0].language : nil

        // Vertical. Percentages run from the bottom of the picture, and where
        // the stack sits says which line it hangs from: a stack in the lower
        // half grows upward from its last line (the usual case), one in the
        // upper half grows downward from its first, and one that straddles the
        // middle stays centred where it was.
        let percents: [Double] = template.compactMap {
            if case .percentage(let v) = $0.verticalPosition { return v }
            return nil
        }
        var vertical = [VerticalPosition?](repeating: nil, count: lines.count)
        if percents.count == template.count, let first = percents.first, let last = percents.last {
            let step: Double? = percents.count >= 2
                ? (first - last) / Double(percents.count - 1)
                : lineSpacing
            let high = max(first, last), low = min(first, last)
            if lines.count == 1 {
                vertical = [.percentage(low > 50 ? first : (high > 50 && low < 50 ? (first + last) / 2 : last))]
            } else if let step {
                let span = step * Double(lines.count - 1)
                let top: Double
                if low > 50 {
                    top = first                              // hangs from its first line
                } else if high > 50 && low < 50 {
                    top = (first + last) / 2 + span / 2      // stays centred
                } else {
                    top = last + span                        // stands on its last line
                }
                vertical = lines.indices.map { .percentage(top - step * Double($0)) }
            }
        }
        // Horizontal goes with the vertical: a line placed sideways but not in
        // height would still leave the stack half-positioned.
        let keepsPositions = vertical.contains { $0 != nil }
            || template.allSatisfy { $0.verticalPosition == nil }
        return lines.enumerated().map { (index, line) in
            let source = template[min(index, template.count - 1)]
            return TextBlock(segments: segments(of: line),
                             language: language,
                             verticalPosition: vertical[index],
                             horizontalPosition: keepsPositions ? source.horizontalPosition : nil)
        }
    }

    private static func clamp(_ range: Range<Int>, to count: Int) -> Range<Int> {
        let lower = max(0, min(range.lowerBound, count))
        let upper = max(lower, min(range.upperBound, count))
        return lower..<upper
    }
}
