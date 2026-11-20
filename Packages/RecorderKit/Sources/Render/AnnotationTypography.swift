// SPDX-License-Identifier: GPL-3.0-or-later
// `NSFontDescriptor.withDesign(_:)` only: the public way to the system font's rounded, serif and mono designs, on the
// descriptor CoreText uses (the two are the same object). Nothing of AppKit's interface.
import AppKit
import CoreText
import Foundation
import ProjectFormat

/// How the texts of the annotations and of their speech bubbles are set, `annotation-1` (phase 3 plan 3a, decisions 4 and
/// 5): the font, the lines and the box. `AnnotationScene` measures with it and the drawing of the annotations draws with
/// it, so a text is drawn exactly where its box says.
///
/// - The font is the system's (SF Pro), rounded, serif (New York) or mono (SF Mono) (`TextFont`), the designs of the
///   system font (`NSFontDescriptor.SystemDesign`), in the weight of `kCTFontWeightTrait` 0, 0.3, 0.4 or 0.56
///   (`TextWeight`), asked for `fontLanguage` so a character it lacks falls back the same way on every Mac; `text.size` of
///   the annotation's unit (the height of its space) tall. CoreText applies its own tracking and optical size for that
///   size.
/// - The lines: the string cut at each new line (a new line at the end starts an empty line), and each piece wrapped by
///   words (`CTTypesetterSuggestLineBreak`) to the box's width less its padding on both sides; a word wider than that is
///   cut where it must. The words are wrapped as if the unit were `referenceUnit`, the box's width scaled with it, so a
///   text breaks into the same lines at every size it is drawn at (the preview's, an export's at 4K, a screen's card
///   that grows): CoreText's tracking and optical size make a line's width not quite proportional to its size, which
///   would move a word from line to line. Each line is `ascent + descent + leading` of CoreText tall at its own size.
/// - The box is as wide as the annotation's rect (decision 5) and as tall as its lines and its padding above and below:
///   none for Plain and Title (drawn with the captions' shadow), 0.3 em above and below and 0.55 em on each side for a
///   Label (a pill), 0.45 em and 0.8 em for a Lower third (its bar of 0.12 em at its left inside that), where an em is the
///   text's size. A speech bubble's text has the Label's padding whatever its style.
enum AnnotationTypography {
    /// The language the font is asked for (`TitleTexture.fontLanguage`), so a text in Chinese, Japanese or Korean is drawn
    /// with the same glyphs whatever language the system is set to.
    static let fontLanguage = "en"

    /// The unit the lines are wrapped at, in pixels: the stage's reference height (`StagePoints`' 1080 px).
    static let referenceUnit = 1080.0

    /// The padding of a Label, in em: on each side, then above and below.
    static let labelPaddingEm = SIMD2(0.55, 0.3)
    /// The padding of a Lower third, in em: on each side, then above and below.
    static let lowerThirdPaddingEm = SIMD2(0.8, 0.45)
    /// The corners of a Label's pill, of a Lower third's box and of a speech bubble, and a Lower third's bar, in em.
    static let labelCornerEm = 0.3
    static let lowerThirdCornerEm = 0.12
    static let lowerThirdBarEm = 0.12
    static let calloutCornerEm = 0.35

    /// The `kCTFontWeightTrait` of each weight (as AppKit's `NSFont.Weight`): regular 0, semibold 0.3, bold 0.4, heavy 0.56.
    static func weight(of weight: TextWeight) -> Double {
        switch weight {
        case .regular: 0
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        }
    }

    /// The design of the system font each font is.
    static func design(of font: TextFont) -> NSFontDescriptor.SystemDesign {
        switch font {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
    }

    /// The font `text` is set in with an em of `text.size × unit` pixels, `scale` times as large (a texture drawn larger
    /// than its pixels, `TitleTexture.scale(for:)`; the scene measures at 1): the system font for `fontLanguage` in the
    /// text's design and weight. `nil` for a size that is not a positive number, or if CoreText cannot make it.
    static func font(_ text: TextAnnotation, unit: Double, scale: Double) -> CTFont? {
        let size = text.size * unit * scale
        guard size > 0, size.isFinite, let base = CTFontCreateUIFontForLanguage(.system, size, fontLanguage as CFString) else {
            return nil
        }
        let traits = [kCTFontWeightTrait: weight(of: text.weight)] as CFDictionary
        let weighted = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
        // The same descriptor as AppKit's: its design changed, its weight and its language kept. The system's is as it is.
        let designed =
            text.font == .system
            ? weighted : (weighted as NSFontDescriptor).withDesign(design(of: text.font)).map { $0 as CTFontDescriptor } ?? weighted
        return CTFontCreateWithFontDescriptor(designed, size, nil)
    }

    /// The height of a line: CoreText's ascent, descent and leading of `font`.
    static func lineHeight(of font: CTFont) -> Double {
        Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// The padding of a text of `preset` with an em of `em` pixels: on each side (`x`) and above and below (`y`).
    static func padding(_ preset: TextPreset, em: Double) -> SIMD2<Double> {
        switch preset {
        case .plain, .title: .zero
        case .label: labelPaddingEm * em
        case .lowerThird: lowerThirdPaddingEm * em
        }
    }

    /// `string` set in `font` as lines no wider than `width` pixels (see the type's notes), without the spaces at their
    /// ends; at least one, empty for an empty string.
    static func lines(of string: String, font: CTFont, width: Double) -> [String] {
        let room = width.isFinite ? max(width, 1) : 1
        var lines: [String] = []
        for paragraph in string.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let text = String(paragraph)
            let attributed = NSAttributedString(string: text, attributes: attributes(font: font))
            let length = attributed.length
            guard length > 0 else {
                lines.append("")
                continue
            }
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let utf16 = text as NSString
            var start = 0
            while start < length {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, room)
                guard count > 0 else { break }
                let line = utf16.substring(with: NSRange(location: start, length: min(count, length - start)))
                lines.append(String(line.reversed().drop(while: \.isWhitespace).reversed()))
                start += count
            }
        }
        return lines.isEmpty ? [""] : lines
    }

    /// The lines of `text` as a box `width` pixels wide with its padding of `paddingPreset` (its own preset's when `nil`;
    /// a speech bubble's is `.label`), with `unit` the height of its space, wrapped at `referenceUnit` (see the type's
    /// notes): the same for every `unit`. `nil` without a font (`font(_:unit:scale:)`) or a unit.
    static func lines(of text: TextAnnotation, width: Double, unit: Double, padding paddingPreset: TextPreset? = nil) -> [String]? {
        guard unit > 0, unit.isFinite, let font = Self.font(text, unit: referenceUnit, scale: 1) else { return nil }
        let padding = Self.padding(paddingPreset ?? text.preset, em: text.size * unit)
        return Self.lines(of: text.string, font: font, width: (width - 2 * padding.x) * referenceUnit / unit)
    }

    /// The box of `text`, `width` pixels wide, in pixels: that width, and the height of its lines
    /// (`lines(of:width:unit:padding:)`, each as tall as a line of its own size) and of its padding above and below (of
    /// `paddingPreset`, its own preset's when `nil`; a speech bubble's is `.label`), with `unit` the height of its space.
    /// Without a font, the padding alone.
    static func box(of text: TextAnnotation, width: Double, unit: Double, padding paddingPreset: TextPreset? = nil) -> SIMD2<Double> {
        let padding = Self.padding(paddingPreset ?? text.preset, em: text.size * unit)
        guard let font = Self.font(text, unit: unit, scale: 1),
            let lines = Self.lines(of: text, width: width, unit: unit, padding: paddingPreset)
        else { return SIMD2(width, 2 * padding.y) }
        return SIMD2(width, Double(lines.count) * lineHeight(of: font) + 2 * padding.y)
    }

    /// What a line of `font` is set with: the font and `fontLanguage`.
    static func attributes(font: CTFont) -> [NSAttributedString.Key: Any] {
        [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTLanguageAttributeName as String): fontLanguage,
        ]
    }
}
