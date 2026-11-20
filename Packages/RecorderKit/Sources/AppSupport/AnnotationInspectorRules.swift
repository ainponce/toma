// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// What the Annotations tab's inspector does with an annotation besides its commands (phase 3 plan 3a, Task A14;
/// decisions 2, 3, 5 and 6). Pure.
public enum AnnotationInspectorRules {
    /// `annotation` carried from space `old` to space `new`, both in the same pixels (where a frame draws it now, and where
    /// the anchor it goes to would draw it in that frame), so it does not move on the screen when its anchor changes: its
    /// rect, an arrow's ends and a speech bubble's point on the same pixels, and what is a fraction of its space's height
    /// (a text's size, a speech bubble's, an arrow's and a shape's stroke) on as many pixels. A picture's corners are a
    /// fraction of its own box and stay. `annotation` as it is when a space has no area or is not a number.
    public static func reanchored(_ annotation: Annotation, from old: Rect, to new: Rect) -> Annotation {
        let numbers = [old.x, old.y, old.width, old.height, new.x, new.y, new.width, new.height]
        guard numbers.allSatisfy(\.isFinite), old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { return annotation }
        func point(_ p: NormalizedPoint) -> NormalizedPoint {
            let pixel = AnnotationGeometry.point(p, in: old)
            return NormalizedPoint(x: (pixel.x - new.x) / new.width, y: (pixel.y - new.y) / new.height)
        }
        let heights = old.height / new.height
        var moved = annotation
        moved.rect = AnnotationGeometry.normalized(AnnotationGeometry.pixels(annotation.rect, in: old), in: new)
        switch annotation.kind {
        case var .text(text):
            text.size *= heights
            moved.kind = .text(text)
        case var .callout(callout):
            callout.text.size *= heights
            callout.target = point(callout.target)
            moved.kind = .callout(callout)
        case var .arrow(arrow):
            arrow.from = point(arrow.from)
            arrow.to = point(arrow.to)
            arrow.width *= heights
            moved.kind = .arrow(arrow)
        case var .shape(shape):
            shape.width *= heights
            moved.kind = .shape(shape)
        case .step, .image, .clip:
            break
        }
        return moved
    }

    /// The entrances the inspector offers for `kind`: None, Fade and Pop, and Draw for an arrow or a shape (the others
    /// would read it as a fade).
    public static func entrances(for kind: AnnotationKind) -> [AnnotationEnter] {
        switch kind {
        case .arrow, .shape: [.none, .fade, .pop, .draw]
        default: [.none, .fade, .pop]
        }
    }

    /// Whether the inspector offers a rotation for `kind`: not for an arrow or a speech bubble, which their points place
    /// (decision 6).
    public static func rotates(_ kind: AnnotationKind) -> Bool {
        switch kind {
        case .arrow, .callout: false
        default: true
        }
    }

    /// `text` in style `preset`: a background that was its style's own (`TextAnnotation.defaultFill(for:)`, a Label's and
    /// a Lower third's black, none for the others) becomes the new style's; one chosen by hand stays.
    public static func restyled(_ text: TextAnnotation, to preset: TextPreset) -> TextAnnotation {
        var restyled = text
        if text.fill == TextAnnotation.defaultFill(for: text.preset) { restyled.fill = TextAnnotation.defaultFill(for: preset) }
        restyled.preset = preset
        return restyled
    }
}
