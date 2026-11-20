// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The colours the annotation inspector offers (phase 3 plan 3a, decision 18): eight fixed ones and up to six that the
/// document already uses, the most used first. The `ColorPicker` next to them is the app's.
public enum AnnotationPalette {
    /// How many of the document's colours the palette adds.
    public static let documentColorLimit = 6

    /// White, black, #FF453A, #FF9F0A, #FFD60A, #30D158, #0A84FF and #BF5AF2, all opaque.
    public static let fixed: [RGBA] = [
        RGBA(1, 1, 1, 1), RGBA(0, 0, 0, 1), .annotationRed, rgb(0xFF, 0x9F, 0x0A), rgb(0xFF, 0xD6, 0x0A), rgb(0x30, 0xD1, 0x58),
        rgb(0x0A, 0x84, 0xFF), rgb(0xBF, 0x5A, 0xF2),
    ]

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> RGBA { RGBA(Double(r) / 255, Double(g) / 255, Double(b) / 255, 1) }

    /// `fixed`, then the colours `document` already uses (its annotations' texts, fills, strokes and steps; its title
    /// cards' text and background; a colour background), made opaque, without repeating one of `fixed` or another one:
    /// the most used first, those used as often in the order they are first found.
    public static func colors(of document: EditDocument) -> [RGBA] {
        var used: [RGBA] = []
        var counts: [Int] = []
        func note(_ color: RGBA?) {
            guard let color, color.r.isFinite, color.g.isFinite, color.b.isFinite else { return }
            let opaque = RGBA(color.r, color.g, color.b, 1)
            if let index = used.firstIndex(where: { same($0, opaque) }) {
                counts[index] += 1
            } else {
                used.append(opaque)
                counts.append(1)
            }
        }
        if case let .color(color) = document.style.background { note(color) }
        for annotation in document.annotations.items {
            switch annotation.kind {
            case let .text(text):
                note(text.color)
                note(text.fill)
            case let .callout(callout):
                note(callout.text.color)
                note(callout.text.fill)
            case let .arrow(arrow): note(arrow.color)
            case let .shape(shape):
                note(shape.stroke)
                note(shape.fill)
            case let .step(step): note(step.color)
            case .image, .clip: break
            }
        }
        for clip in document.sequence {
            guard case let .card(card, _)? = clip.content else { continue }
            note(card.textColor)
            if case let .color(color) = card.background { note(color) }
        }
        let extra = used.indices
            .filter { index in !fixed.contains { same($0, used[index]) } }
            // Stable: `sorted` is not, so the first found breaks a tie by its index.
            .sorted { counts[$0] != counts[$1] ? counts[$0] > counts[$1] : $0 < $1 }
            .prefix(documentColorLimit)
            .map { used[$0] }
        return fixed + extra
    }

    private static func same(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 1e-6 && abs(a.g - b.g) < 1e-6 && abs(a.b - b.b) < 1e-6
    }
}
