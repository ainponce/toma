// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The annotations the Annotations tab can add by a button (not those of a file).
public enum NewAnnotation: String, CaseIterable, Sendable {
    case text, arrow, shape, callout, step
}

/// What a new annotation is and where it goes (phase 3 plan 3a, decision 8). Pure.
public enum AnnotationDefaults {
    /// A new text's size: 5 % of the height of its space.
    public static let textSize = 0.05

    /// The `kind` of a new annotation: `text` is the string of a text or a speech bubble (the app gives the localized
    /// "Text"). An arrow goes from (0.35, 0.35) to (0.55, 0.55) with a filled head, red; a shape is a red rectangle's
    /// border; a speech bubble has a white fill and black text, and points at (0.45, 0.45).
    public static func kind(_ new: NewAnnotation, text: String) -> AnnotationKind {
        switch new {
        case .text:
            .text(TextAnnotation(string: text, preset: .plain, size: textSize))
        case .arrow:
            .arrow(ArrowAnnotation(from: NormalizedPoint(x: 0.35, y: 0.35), to: NormalizedPoint(x: 0.55, y: 0.55), head: .filled))
        case .shape:
            .shape(ShapeAnnotation(shape: .rect))
        case .callout:
            .callout(
                CalloutAnnotation(
                    text: TextAnnotation(
                        string: text, preset: .label, size: textSize, color: RGBA(0, 0, 0, 1), fill: RGBA(1, 1, 1, 1)),
                    target: NormalizedPoint(x: 0.45, y: 0.45)))
        case .step:
            .step(StepAnnotation())
        }
    }

    /// An image of `assets/`, whole inside its box, with square corners and no shadow.
    public static func image(asset: String) -> AnnotationKind {
        .image(ImageAnnotation(asset: asset, fit: .fit))
    }

    /// A clip of `assets/`, the whole file (`fileDuration` ns), at its own volume, with its sound.
    public static func clip(asset: String, fileDuration: Int64) -> AnnotationKind {
        .clip(ClipAnnotation(asset: asset, start: 0, end: max(fileDuration, 0)))
    }

    /// Where a new annotation of `kind` goes, in fractions of its space: a text (0.3, 0.45) and 0.4 wide; an arrow the box
    /// of its ends; a shape (0.35, 0.35) and 0.3 × 0.3; a speech bubble (0.55, 0.2) and 0.3 wide; a step a circle 0.07 of
    /// the height high at (0.46, 0.44); an image or a clip 0.3 wide with the proportion of its picture (`aspect`, width over
    /// height; 1 without it), centred, and at most 0.9 high. `spaceAspect` is the width over the height of the space in
    /// pixels, so a step is round and a picture is not stretched.
    public static func rect(for kind: AnnotationKind, aspect: Double?, spaceAspect: Double) -> NormalizedRect {
        let space = spaceAspect.isFinite && spaceAspect > 0 ? spaceAspect : 1
        switch kind {
        case let .text(text):
            return NormalizedRect(x: 0.3, y: 0.45, width: 0.4, height: text.size * 1.2)
        case let .arrow(arrow):
            return AnnotationGeometry.arrowRect(arrow, aspect: space)
        case .shape:
            return NormalizedRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        case let .callout(callout):
            return NormalizedRect(x: 0.55, y: 0.2, width: 0.3, height: callout.text.size * 2.4)
        case .step:
            return NormalizedRect(x: 0.46, y: 0.44, width: 0.07 / space, height: 0.07)
        case .image, .clip:
            let picture = aspect.map { $0.isFinite && $0 > 0 ? $0 : 1 } ?? 1
            var width = 0.3
            var height = width * space / picture
            if height > 0.9 {
                height = 0.9
                width = height * picture / space
            }
            return NormalizedRect(x: 0.5 - width / 2, y: 0.5 - height / 2, width: width, height: height)
        }
    }
}
