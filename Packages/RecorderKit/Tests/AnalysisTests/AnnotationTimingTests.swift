// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ProjectFormat

@testable import Analysis

@Suite struct AnnotationTimingTests {
    typealias F = AnnotationFixtures

    static func state(_ a: Annotation, _ seconds: Double, document: EditDocument? = nil) -> AnnotationState? {
        let d = document ?? F.document([a])
        return AnnotationTiming.state(of: a, atOutput: F.ns(seconds), document: d, timeMap: TimeMap(sequence: d.sequence))
    }

    @Test func contentShowsInItsSourceRange() {
        let a = F.text(anchor: F.content(6, 12))
        #expect(Self.state(a, 5.9) == nil)
        #expect(Self.state(a, 7) != nil)
        // The frozen frame's point (8 s) is inside [6, 12).
        #expect(Self.state(a, 9) != nil)
        #expect(Self.state(a, 11) != nil)
        #expect(Self.state(a, 12.0) == nil)
        // A freeze whose point is outside shows nothing.
        let b = F.text(anchor: F.content(1, 5))
        #expect(Self.state(b, 9) == nil)
        // Another take's stretch is not its source.
        let other = F.text(anchor: .content(take: "take-002", start: F.at(6), end: F.at(12)))
        #expect(Self.state(other, 7) == nil)
    }

    @Test func outputRangeClosesCuts() {
        let d = F.document()
        let map = TimeMap(sequence: d.sequence)
        func range(_ a: Annotation) -> Range<Int64>? { AnnotationTiming.outputRange(of: a, document: d, timeMap: map) }
        #expect(range(F.text(anchor: F.content(6, 12))) == F.ns(6)..<F.ns(12))
        // A cut in the middle closes: [7, 18) over the cut-out nothing is the same block.
        #expect(range(F.text(anchor: F.content(7, 18))) == F.ns(7)..<F.ns(18))
        // Cut whole: before the take's clips and after them.
        #expect(range(F.text(anchor: F.content(8.2, 9.8))) == nil)
        #expect(range(F.text(anchor: F.content(25, 30))) == nil)
        #expect(range(F.text(anchor: .whole)) == 0..<F.ns(20))
        #expect(range(F.text(anchor: .output(start: F.ns(3), end: F.ns(5)))) == F.ns(3)..<F.ns(5))
        #expect(range(F.text(anchor: .output(start: 5, end: 5))) == nil)
    }

    @Test func outputAnchorsAndWholeShowInTheirRange() {
        let a = F.text(anchor: .output(start: F.ns(2), end: F.ns(6)))
        #expect(Self.state(a, 1.99) == nil && Self.state(a, 3) != nil && Self.state(a, 6) == nil)
        // Also over the frozen frame.
        let b = F.text(anchor: .output(start: F.ns(7), end: F.ns(12)))
        #expect(Self.state(b, 9) != nil)
        let whole = F.text(anchor: .whole)
        #expect(Self.state(whole, 0) != nil && Self.state(whole, 19.99) != nil && Self.state(whole, 20) == nil)
    }

    @Test func enterAndExitTake250ms() {
        let a = F.text(anchor: .output(start: F.ns(2), end: F.ns(6)))
        #expect(Self.state(a, 2)?.opacity == 0)
        #expect(abs((Self.state(a, 2.125)?.opacity ?? -1) - 0.5) < 1e-9)
        #expect(Self.state(a, 2.25)?.opacity == 1)
        #expect(Self.state(a, 4)?.opacity == 1)
        #expect(abs((Self.state(a, 5.875)?.opacity ?? -1) - 0.5) < 1e-9)
        #expect((Self.state(a, 5.999)?.opacity ?? 1) < 0.001)
        // Off: full from the first instant to the last.
        let none = F.text(anchor: .output(start: F.ns(2), end: F.ns(6)), enter: .none, exit: .none)
        #expect(Self.state(none, 2)?.opacity == 1 && Self.state(none, 5.999)?.opacity == 1)
        // The annotation's own opacity multiplies.
        let half = F.text(anchor: .output(start: F.ns(2), end: F.ns(6)), opacity: 0.5)
        #expect(Self.state(half, 4)?.opacity == 0.5)
        let bad = F.text(anchor: .output(start: F.ns(2), end: F.ns(6)), opacity: 7)
        #expect(Self.state(bad, 4)?.opacity == 1)
    }

    @Test func shortAnnotationSplitsItsTransitions() {
        let a = F.text(anchor: .output(start: F.ns(2), end: F.ns(2.3)))
        // T = 0.15 s: in at its half a second... full at 0.15 and out starting there.
        #expect(abs((Self.state(a, 2.075)?.opacity ?? -1) - 0.5) < 1e-9)
        #expect(Self.state(a, 2.15)?.opacity == 1)
        #expect(abs((Self.state(a, 2.225)?.opacity ?? -1) - 0.5) < 1e-9)
    }

    @Test func popIsTheCriticalSpringLandingAtOne() {
        #expect(AnnotationTiming.pop(0) == 0.9 && AnnotationTiming.pop(-1) == 0.9)
        #expect(AnnotationTiming.pop(1) == 1 && AnnotationTiming.pop(2) == 1)
        var last = 0.9
        for i in 1..<100 {
            let v = AnnotationTiming.pop(Double(i) / 100)
            #expect(v > last && v < 1)
            last = v
        }
        let omega = 2 * Double.pi / 0.30
        func s(_ t: Double) -> Double { 1 - (1 + omega * t) * exp(-omega * t) }
        #expect(abs(AnnotationTiming.pop(0.4) - (0.9 + 0.1 * s(0.1) / s(0.25))) < 1e-12)
        let a = F.text(anchor: .output(start: F.ns(2), end: F.ns(6)), enter: .pop)
        let early = Self.state(a, 2.1)
        #expect(early?.scale == AnnotationTiming.pop(0.4) && abs((early?.opacity ?? 0) - 0.4) < 1e-9)
        #expect(Self.state(a, 3)?.scale == 1)
    }

    @Test func drawOnlyForArrowsAndShapes() {
        let arrow = F.text(
            anchor: .output(start: F.ns(2), end: F.ns(6)),
            kind: .arrow(ArrowAnnotation(from: NormalizedPoint(x: 0.1, y: 0.1), to: NormalizedPoint(x: 0.5, y: 0.5), head: .filled)), enter: .draw)
        let mid = Self.state(arrow, 2.125)
        #expect(mid?.opacity == 1 && abs((mid?.drawn ?? -1) - 0.5) < 1e-9)
        #expect(Self.state(arrow, 2)?.drawn == 0 && Self.state(arrow, 3)?.drawn == 1)
        let shape = F.text(
            anchor: .output(start: F.ns(2), end: F.ns(6)), kind: .shape(ShapeAnnotation(shape: .rect)), enter: .draw)
        #expect(abs((Self.state(shape, 2.125)?.drawn ?? -1) - 0.5) < 1e-9)
        // A text reads it as a fade.
        let text = F.text(anchor: .output(start: F.ns(2), end: F.ns(6)), enter: .draw)
        let t = Self.state(text, 2.125)
        #expect(abs((t?.opacity ?? -1) - 0.5) < 1e-9 && t?.drawn == 1)
    }

    @Test func freezeHoldsTheProgress() {
        // It comes in at 7.9 s of source: 0.1 s in at the freeze, which is still while the frame lasts.
        let a = F.text(anchor: F.content(7.9, 12))
        let first = Self.state(a, 8.0)
        #expect(first != nil)
        #expect(first == Self.state(a, 8.9) && first == Self.state(a, 9.99))
        #expect(abs((first?.opacity ?? -1) - 0.352) < 1e-9)  // smoothstep(0.4)
        // The exit: the same, standing still.
        let b = F.text(anchor: F.content(7, 10.1))
        let held = Self.state(b, 8.0)
        #expect(held != nil && held == Self.state(b, 9.5))
    }

    @Test func aCutStartHasAlreadyCome() {
        // Starts in the cut [8, 10)... after the freeze's point: it begins at the clip's first instant, already in.
        let a = F.text(anchor: F.content(9, 14))
        #expect(Self.state(a, 10)?.opacity == 1)
        #expect(Self.state(a, 10.5)?.opacity == 1)
        // The exit still fades at its real end.
        #expect((Self.state(a, 13.99)?.opacity ?? 1) < 0.01)
    }

    @Test func speedScalesContentTransitions() {
        // The first clip at 2×: [0, 8) s of source last 4 s of output; the freeze is at 4 s.
        let d = F.document(sequence: F.clips(speedOfFirst: 2))
        let a = F.text(anchor: F.content(2, 7))  // output 1 s … 3.5 s
        let map = TimeMap(sequence: d.sequence)
        #expect(AnnotationTiming.outputRange(of: a, document: d, timeMap: map) == F.ns(1)..<F.ns(3.5))
        #expect(abs((Self.state(a, 1.125, document: d)?.opacity ?? -1) - 0.5) < 1e-9)
        #expect(Self.state(a, 1.25, document: d)?.opacity == 1)
        #expect(abs((Self.state(a, 3.375, document: d)?.opacity ?? -1) - 0.5) < 1e-9)
    }

    @Test func notOverCardsNorImportedClips() {
        let card = Clip(
            id: "c-0000000c", take: "take-001", start: F.at(8), end: F.at(8), speed: 1,
            content: .card(TitleCard(title: "T", style: .centered, background: .stage), duration: F.ns(2)))
        var clips = F.clips()
        clips[1] = card
        let d = F.document(sequence: clips)
        let a = F.text(anchor: F.content(6, 12))
        #expect(Self.state(a, 7, document: d) != nil)
        #expect(Self.state(a, 9, document: d) == nil)
        // The output's own annotation does go over it.
        #expect(Self.state(F.text(anchor: .whole), 9, document: d) != nil)
    }

    @Test func outsideTheOutputIsNil() {
        let a = F.text(anchor: .whole)
        #expect(Self.state(a, -1) == nil && Self.state(a, 20) == nil)
        let empty = F.document(sequence: [])
        #expect(AnnotationTiming.outputRange(of: a, document: empty, timeMap: TimeMap(sequence: [])) == nil)
    }
}
