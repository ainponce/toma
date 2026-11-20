// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import Testing

@Suite struct AnnotationPaletteTests {
    private static func hex(_ value: UInt32) -> RGBA {
        RGBA(Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255, 1)
    }

    private static func document() -> EditDocument {
        var document = EditDocument.legacy(
            take: TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: []),
            events: [])
        document.style.background = .color(RGBA(0, 0, 0, 1))
        return document
    }

    private static func step(_ id: String, _ color: RGBA) -> Annotation {
        Annotation(id: id, anchor: .whole, layer: 0, kind: .step(StepAnnotation(color: color)), rect: .unit)
    }

    private static func text(_ id: String, color: RGBA, fill: RGBA?) -> Annotation {
        Annotation(
            id: id, anchor: .whole, layer: 0, kind: .text(TextAnnotation(string: "a", preset: .plain, color: color, fill: fill)), rect: .unit)
    }

    private static func same(_ a: RGBA, _ b: RGBA) -> Bool { abs(a.r - b.r) < 1e-9 && abs(a.g - b.g) < 1e-9 && abs(a.b - b.b) < 1e-9 }

    @Test func theFixedColorsAreTheDecisions() {
        let expected: [RGBA] = [
            RGBA(1, 1, 1, 1), RGBA(0, 0, 0, 1), Self.hex(0xFF453A), Self.hex(0xFF9F0A), Self.hex(0xFFD60A), Self.hex(0x30D158),
            Self.hex(0x0A84FF), Self.hex(0xBF5AF2),
        ]
        #expect(AnnotationPalette.fixed.count == 8)
        for (a, b) in zip(AnnotationPalette.fixed, expected) { #expect(Self.same(a, b) && a.a == 1) }
        #expect(AnnotationPalette.fixed[2] == .annotationRed)
    }

    @Test func paletteHasTheFixedAndTheDocumentsColors() {
        let teal = RGBA(0.1, 0.7, 0.7, 1), pink = RGBA(1, 0.4, 0.8, 1), olive = RGBA(0.5, 0.5, 0.1, 1)
        var document = Self.document()
        document.annotations = AnnotationPlan(items: [
            Self.step("a-00000001", teal), Self.step("a-00000002", pink), Self.step("a-00000003", teal),
            Self.step("a-00000004", .annotationRed),  // already fixed
            Self.text("a-00000005", color: RGBA(1, 1, 1, 1), fill: olive),
        ])
        let colors = AnnotationPalette.colors(of: document)
        #expect(Array(colors.prefix(8)) == AnnotationPalette.fixed)
        // The most used first: teal twice, then pink and olive once each (by their first use); never a fixed one again.
        #expect(colors.count == 8 + 3)
        #expect(colors[8] == teal && colors[9] == pink && colors[10] == olive)
    }

    @Test func aColorTheDocumentUsesAndTheFixedOnesAreNotRepeated() {
        let document = Self.document()  // a black background: a fixed colour
        #expect(AnnotationPalette.colors(of: document) == AnnotationPalette.fixed)
    }

    @Test func atMostSixOfTheDocumentsAndWithoutTransparency() {
        let seven = (0..<7).map { RGBA(0.1 * Double($0 + 1), 0.05, 0.3, 1) }
        var document = Self.document()
        document.annotations = AnnotationPlan(
            items: seven.enumerated().map { Self.step("a-0000000\($0.offset)", $0.element) }
                // A translucent version of the first one counts as it.
                + [Self.text("a-00000009", color: RGBA(seven[0].r, seven[0].g, seven[0].b, 0.7), fill: nil)])
        let colors = AnnotationPalette.colors(of: document)
        #expect(colors.count == 8 + 6)
        #expect(colors[8] == seven[0])  // used twice
        #expect(colors.dropFirst(8).allSatisfy { $0.a == 1 })
        // Deterministic.
        #expect(AnnotationPalette.colors(of: document) == colors)
    }

    @Test func titleCardsAndAColorBackgroundCount() {
        let violet = RGBA(0.6, 0.2, 0.9, 1), mustard = RGBA(0.8, 0.7, 0.1, 1)
        var document = Self.document()
        document.style.background = .color(violet)
        let card = TitleCard(title: "a", style: .centered, background: .color(mustard), textColor: RGBA(0.2, 0.9, 0.4, 1))
        document.sequence = [
            Clip(id: "c-00000001", take: "take-001", start: HostTime(nanoseconds: 5), end: HostTime(nanoseconds: 5), speed: 1, content: .card(card, duration: 3_000_000_000))
        ]
        let extra = Set(AnnotationPalette.colors(of: document).dropFirst(8).map { "\($0.r),\($0.g),\($0.b)" })
        #expect(extra == ["0.6,0.2,0.9", "0.8,0.7,0.1", "0.2,0.9,0.4"])
    }
}
