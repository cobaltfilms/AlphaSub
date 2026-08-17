import Foundation
import AlphaSubCore

/// Shared horizontal-placement logic for the two DCP subtitle formats
/// (SMPTE ST 428-7 and DLP InterOp / CineCanvas).
///
/// In both formats a subtitle's horizontal placement is a `Halign` anchor plus
/// an `Hposition` value, where **`Hposition` is a percentage of screen width
/// measured from the `Halign` anchor point**: from the screen CENTRE for
/// `Halign="center"` (positive = right), from the LEFT edge for
/// `Halign="left"` (positive = right), and from the RIGHT edge for
/// `Halign="right"` (positive = left). The standard centred subtitle is
/// `Halign="center" Hposition="0"` — confirmed by every real DCP sample
/// (`samples/dcp_xml/*.xml`), which are ordinary centred movie subtitles all
/// written as `Halign="center" … Hposition="0.0"`.
///
/// The old SMPTE importer mapped `Hposition` straight to
/// `.percentage(Hposition)` — treating it as an absolute left-origin coordinate
/// — so a centred cue (`Hposition="0"`) became `.percentage(0)` = the LEFT
/// edge, shoving every imported subtitle to the left of the picture. A later
/// fix treated it as always centre-relative, which mis-placed left/right
/// anchored cues. This composes the anchor and anchor-relative offset into
/// AlphaSub's left-origin `HorizontalPosition` (0 % = left edge, 50 % =
/// centre, 100 % = right edge) and back, keeping the two formats consistent.
/// Colour conversion for the two DCP subtitle formats.
///
/// DCP writes colours as `AARRGGBB` — **alpha first**, which is the reverse of
/// the `#RRGGBBAA` `TextColor(hex:)` accepts. Passing one to the other rotates
/// every channel, so the conversion lives here and both importers and exporters
/// go through it.
enum DCPColor {
    /// `AARRGGBB` or bare `RRGGBB` → `TextColor`. Alpha is discarded: the model
    /// carries opaque colours only, and DCP subtitle text is always opaque.
    static func textColor(fromHex hex: String) -> TextColor? {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# \n\t\r"))
        guard !clean.isEmpty, clean.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch clean.count {
        case 8: return TextColor(hex: String(clean.dropFirst(2)))
        case 6: return TextColor(hex: clean)
        default: return nil
        }
    }

    /// `TextColor` → opaque `FFRRGGBB`, uppercase, as DCP expects.
    static func hex(from color: TextColor) -> String {
        String(format: "FF%02X%02X%02X", color.r, color.g, color.b)
    }
}

public enum DCPHorizontal {
    static func placement(halign: String?, hposition: Double?) -> (HorizontalPosition, TextAlignment) {
        let ha = (halign ?? "center").trimmingCharacters(in: .whitespaces).lowercased()
        let hp = hposition ?? 0

        // Hposition is measured from the Halign anchor; our model is left-origin.
        switch ha {
        case "left", "start":
            let horizontal: HorizontalPosition = hp == 0
                ? .leftAligned
                : .percentage(min(100, max(0, hp)))
            return (horizontal, .left)
        case "right", "end":
            let horizontal: HorizontalPosition = hp == 0
                ? .rightAligned
                : .percentage(min(100, max(0, 100 - hp)))
            return (horizontal, .right)
        default:
            let horizontal: HorizontalPosition = hp == 0
                ? .centered
                : .percentage(min(100, max(0, 50 + hp)))
            return (horizontal, .center)
        }
    }

    /// Inverse of ``placement(halign:hposition:)`` — turn AlphaSub's left-origin
    /// horizontal placement back into a DCP `Halign` anchor + anchor-relative
    /// `Hposition` so exports match the spec (a centred cue writes
    /// `Halign="center" Hposition="0.0"`, not `Hposition="50.0"`; a left cue at
    /// 10 % writes `Halign="left" Hposition="10.0"`).
    public static func attributes(horizontal: HorizontalPosition,
                                  alignment: TextAlignment) -> (halign: String, hposition: Double) {
        let screenPct: Double
        switch horizontal {
        case .centered:          screenPct = 50
        case .leftAligned:       screenPct = 0
        case .rightAligned:      screenPct = 100
        case .percentage(let v): screenPct = min(100, max(0, v))
        }
        switch alignment {
        case .left, .start:  return ("left", screenPct)
        case .right, .end:   return ("right", 100 - screenPct)
        default:             return ("center", screenPct - 50)
        }
    }
}

/// Shared vertical placement between AlphaSub's model and the DCP dialects.
///
/// AlphaSub stores vertical position as "percent up from the bottom" — the
/// same convention both DCP formats write as `Valign="bottom"` plus a
/// `Vposition` measured up from the bottom edge, so a stored percentage
/// exports verbatim.
public enum DCPVertical {
    public static func attributes(vertical: VerticalPosition,
                                  baseVPosition: Double = 8.0) -> (valign: String, vposition: Double) {
        switch vertical {
        case .safeArea(.top):    return ("top", baseVPosition)
        case .safeArea(.center): return ("center", 50.0)
        case .safeArea(.bottom): return ("bottom", baseVPosition)
        case .percentage(let pct):
            // Model 0 = bottom; DCP bottom-anchored Vposition counts up from
            // the bottom edge — same convention, no conversion.
            return ("bottom", max(1.0, min(100.0, pct)))
        case .row(let r):        return ("top", Double(r))
        case .lineShift:         return ("bottom", baseVPosition)
        }
    }
}

/// Shared `<Text>` discovery for the two DCP subtitle importers.
///
/// In both DCP dialects a `<Font>` element may appear at ANY level — including
/// INSIDE `<Subtitle>`, wrapping the `<Text>` lines (the standard way mastering
/// tools write whole-cue italics). The importers used to iterate only the
/// direct children of `<Subtitle>` looking for `<Text>`, so Font-wrapped cues
/// imported with no text and no position at all. This walks the subtree,
/// accumulating the Font style (Italic/Weight) each `<Text>` inherits.
enum DCPTextTree {
    /// All `<Text>` descendants of a `<Subtitle>` element in document order,
    /// each paired with the style and colour inherited from wrapping `<Font>`
    /// elements. Colour is carried alongside style because a whole-cue colour is
    /// written exactly like whole-cue italics — on a `<Font>` that wraps the
    /// `<Text>` rather than on the run itself (#50).
    static func texts(in subtitleElem: XMLElement) -> [(elem: XMLElement, inheritedStyle: TextStyle, inheritedColor: TextColor?)] {
        var result: [(XMLElement, TextStyle, TextColor?)] = []
        collect(subtitleElem, inherited: [], inheritedColor: nil, into: &result)
        return result
    }

    private static func collect(_ elem: XMLElement, inherited: TextStyle,
                                inheritedColor: TextColor?,
                                into result: inout [(XMLElement, TextStyle, TextColor?)]) {
        for child in (elem.children ?? []).compactMap({ $0 as? XMLElement }) {
            switch localName(child.name) {
            case "Text":
                result.append((child, inherited, inheritedColor))
            case "Font":
                var style = inherited
                switch child.attribute(forName: "Italic")?.stringValue?.lowercased() {
                case "yes": style.insert(.italic)
                case "no":  style.remove(.italic)
                default:    break
                }
                switch child.attribute(forName: "Weight")?.stringValue?.lowercased() {
                case "bold":   style.insert(.bold)
                case "normal": style.remove(.bold)
                default:       break
                }
                switch child.attribute(forName: "Underline")?.stringValue?.lowercased() {
                case "yes": style.insert(.underline)
                case "no":  style.remove(.underline)
                default:    break
                }
                let color = child.attribute(forName: "Color")?.stringValue
                    .flatMap(DCPColor.textColor(fromHex:)) ?? inheritedColor
                collect(child, inherited: style, inheritedColor: color, into: &result)
            default:
                // Ruby/Space/etc. — do not descend; Text never hides in them.
                continue
            }
        }
    }

    static func localName(_ name: String?) -> String {
        guard let name else { return "" }
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }
}
