// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import Testing

@Suite struct AnnotationInspectorRulesTests {
    /// Where the content of the screen is drawn in a 1920 × 1080 output, zoomed in, and the output frame.
    private static let content = Rect(x: 200, y: 100, width: 2400, height: 1350)
    private static let output = Rect(x: 0, y: 0, width: 1920, height: 1080)

    private static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    private static func pixels(_ p: NormalizedPoint, in space: Rect) -> SIMD2<Double> {
        SIMD2(space.x + p.x * space.width, space.y + p.y * space.height)
    }

    private static func annotation(_ kind: AnnotationKind, rect: NormalizedRect) -> Annotation {
        Annotation(
            id: "a-00000001", anchor: .content(take: "take-001", start: HostTime(nanoseconds: 0), end: HostTime(nanoseconds: 3_000_000_000)),
            layer: 1, kind: kind, rect: rect)
    }

    @Test func aTextStaysOnItsPixelsAndItsSize() {
        let text = TextAnnotation(string: "Hola", preset: .lowerThird, size: 0.04)
        let before = Self.annotation(.text(text), rect: NormalizedRect(x: 0.25, y: 0.5, width: 0.4, height: 0.05))
        let after = AnnotationInspectorRules.reanchored(before, from: Self.content, to: Self.output)
        // x: 200 + 0.25 × 2400 = 800 px, the 1920 wide output's 0.41666…; width 960 px, 0.5 of it.
        #expect(Self.close(after.rect.x, 800.0 / 1920) && Self.close(after.rect.y, (100 + 0.5 * 1350) / 1080))
        #expect(Self.close(after.rect.width, 960.0 / 1920) && Self.close(after.rect.height, 0.05 * 1350 / 1080))
        guard case let .text(moved) = after.kind else {
            Issue.record("not a text")
            return
        }
        // 0.04 of 1350 px is 54 px: 0.05 of 1080.
        #expect(Self.close(moved.size, 0.05))
        #expect(moved.string == "Hola" && moved.preset == .lowerThird)
        #expect(after.id == before.id && after.anchor == before.anchor && after.layer == before.layer)
    }

    @Test func anArrowKeepsItsEndsAndItsWidth() {
        let arrow = ArrowAnnotation(
            from: NormalizedPoint(x: 0.1, y: 0.2), to: NormalizedPoint(x: 0.6, y: 0.7), curve: 0.3, width: 0.008, head: .open)
        let before = Self.annotation(.arrow(arrow), rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        let after = AnnotationInspectorRules.reanchored(before, from: Self.content, to: Self.output)
        guard case let .arrow(moved) = after.kind else {
            Issue.record("not an arrow")
            return
        }
        let (from, to) = (Self.pixels(arrow.from, in: Self.content), Self.pixels(arrow.to, in: Self.content))
        #expect(Self.close(Self.pixels(moved.from, in: Self.output).x, from.x) && Self.close(Self.pixels(moved.from, in: Self.output).y, from.y))
        #expect(Self.close(Self.pixels(moved.to, in: Self.output).x, to.x) && Self.close(Self.pixels(moved.to, in: Self.output).y, to.y))
        #expect(Self.close(moved.width, 0.008 * 1350 / 1080) && moved.curve == 0.3 && moved.head == .open)
    }

    @Test func aCalloutsPointAndAShapesBorderGoWithIt() {
        let callout = CalloutAnnotation(
            text: TextAnnotation(string: "Acá", preset: .label, size: 0.05, color: RGBA(0, 0, 0, 1), fill: RGBA(1, 1, 1, 1)),
            target: NormalizedPoint(x: 0.45, y: 0.45))
        let bubble = AnnotationInspectorRules.reanchored(
            Self.annotation(.callout(callout), rect: NormalizedRect(x: 0.55, y: 0.2, width: 0.3, height: 0.12)), from: Self.output,
            to: Self.content)
        guard case let .callout(moved) = bubble.kind else {
            Issue.record("not a callout")
            return
        }
        let target = Self.pixels(callout.target, in: Self.output)
        #expect(Self.close(Self.pixels(moved.target, in: Self.content).x, target.x))
        #expect(Self.close(Self.pixels(moved.target, in: Self.content).y, target.y))
        #expect(Self.close(moved.text.size, 0.05 * 1080 / 1350))

        let shape = ShapeAnnotation(shape: .ellipse, width: 0.004, fill: RGBA(1, 0, 0, 0.25))
        let border = AnnotationInspectorRules.reanchored(
            Self.annotation(.shape(shape), rect: NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)), from: Self.content,
            to: Self.output)
        guard case let .shape(drawn) = border.kind else {
            Issue.record("not a shape")
            return
        }
        #expect(Self.close(drawn.width, 0.004 * 1350 / 1080) && drawn.shape == .ellipse && drawn.fill == RGBA(1, 0, 0, 0.25))
    }

    @Test func picturesAndStepsKeepTheirLookAndAnEmptySpaceChangesNothing() {
        let image = Self.annotation(
            .image(ImageAnnotation(asset: "assets/x.png", fit: .fill, corner: 0.2, shadow: true)),
            rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let moved = AnnotationInspectorRules.reanchored(image, from: Self.content, to: Self.output)
        // A picture's corners are a fraction of its own box, which keeps its pixels.
        #expect(moved.kind == image.kind)
        #expect(Self.close(moved.rect.width * 1920, 0.3 * 2400) && Self.close(moved.rect.height * 1080, 0.3 * 1350))
        let step = Self.annotation(.step(StepAnnotation()), rect: NormalizedRect(x: 0.46, y: 0.44, width: 0.04, height: 0.07))
        #expect(AnnotationInspectorRules.reanchored(step, from: Self.content, to: Rect(x: 0, y: 0, width: 0, height: 1080)) == step)
        #expect(AnnotationInspectorRules.reanchored(step, from: Rect(x: 0, y: 0, width: 10, height: .nan), to: Self.output) == step)
    }

    @Test func drawIsOfferedOnlyToArrowsAndShapes() {
        let text = AnnotationKind.text(TextAnnotation(string: "a", preset: .plain))
        let arrow = AnnotationKind.arrow(ArrowAnnotation(from: NormalizedPoint(x: 0, y: 0), to: NormalizedPoint(x: 1, y: 1), head: .filled))
        #expect(AnnotationInspectorRules.entrances(for: text) == [.none, .fade, .pop])
        #expect(AnnotationInspectorRules.entrances(for: arrow) == [.none, .fade, .pop, .draw])
        #expect(AnnotationInspectorRules.entrances(for: .shape(ShapeAnnotation(shape: .rect))) == [.none, .fade, .pop, .draw])
        #expect(AnnotationInspectorRules.rotates(text) && AnnotationInspectorRules.rotates(.step(StepAnnotation())))
        #expect(!AnnotationInspectorRules.rotates(arrow))
        let callout = CalloutAnnotation(text: TextAnnotation(string: "a", preset: .label), target: NormalizedPoint(x: 0, y: 0))
        #expect(!AnnotationInspectorRules.rotates(.callout(callout)))
    }

    @Test func aStylesOwnBackgroundFollowsTheStyleAndOneChosenStays() {
        let plain = TextAnnotation(string: "a", preset: .plain)
        let label = AnnotationInspectorRules.restyled(plain, to: .label)
        #expect(label.preset == .label && label.fill == TextAnnotation.defaultFill(for: .label))
        let title = AnnotationInspectorRules.restyled(label, to: .title)
        #expect(title.preset == .title && title.fill == nil)
        var chosen = TextAnnotation(string: "a", preset: .label)
        chosen.fill = RGBA(0, 0.5, 1, 1)
        #expect(AnnotationInspectorRules.restyled(chosen, to: .plain).fill == RGBA(0, 0.5, 1, 1))
        #expect(AnnotationInspectorRules.restyled(chosen, to: .plain).preset == .plain)
    }
}
