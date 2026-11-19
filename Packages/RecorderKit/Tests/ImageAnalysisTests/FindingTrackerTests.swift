// SPDX-License-Identifier: GPL-3.0-or-later

import Analysis
import Foundation
import ProjectFormat
import Testing
@testable import ImageAnalysis

@Suite("FindingTracker")
struct FindingTrackerTests {
    private static let base: UInt64 = 1_000_000_000_000

    private func at(_ seconds: Double) -> HostTime {
        HostTime(nanoseconds: Self.base + UInt64((seconds * 1e9).rounded()))
    }

    private var whole: Range<HostTime> { at(0)..<at(100) }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }

    private func email(_ rect: NormalizedRect, _ text: String = "ana.perez@gmail.com") -> FrameObservation {
        FrameObservation(kind: .email, text: text, rect: rect)
    }

    /// `rect` grown by `grow` of its height on each side.
    private func grown(_ r: NormalizedRect) -> NormalizedRect {
        let m = FindingTracker.grow * r.height
        return rect(r.x - m, r.y - m, r.width + 2 * m, r.height + 2 * m)
    }

    private func close(_ a: NormalizedRect, _ b: NormalizedRect) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    private func contains(_ outer: NormalizedRect, _ inner: NormalizedRect) -> Bool {
        let e = 1e-9
        return outer.x <= inner.x + e && outer.y <= inner.y + e
            && outer.x + outer.width >= inner.x + inner.width - e && outer.y + outer.height >= inner.y + inner.height - e
    }

    /// The rect a block hides at source instant `t`, as the render reads it.
    private func hidden(by finding: PrivacyFinding, at t: HostTime) -> NormalizedRect {
        PrivacyGeometry.rect(of: finding.block(id: "p-00000001"), atSource: t)
    }

    /// Source instants from `a` to `b`, every `step` seconds, both ends included.
    private func instants(_ a: Double, _ b: Double, step: Double = 0.01) -> [Double] {
        Array(stride(from: a, through: b + 1e-9, by: step))
    }

    @Test func sameKindNearInTimeAndPlaceIsOne() {
        // Two rects of the same size side by side: IoU = (w − dx) / (w + dx).
        func joined(iou: Double) -> [PrivacyFinding] {
            let dx = 0.2 * (1 - iou) / (1 + iou)
            var tracker = FindingTracker(take: "take-001")
            tracker.add([email(rect(0.1, 0.1, 0.2, 0.05), "one@mail.com")], at: at(1))
            tracker.add([email(rect(0.1 + dx, 0.1, 0.2, 0.05), "two@mail.com")], at: at(1.25))
            return tracker.findings(within: whole)
        }
        let one = joined(iou: 0.35)
        #expect(one.count == 1)
        #expect(one.first?.keys.map(\.t) == [at(1), at(1.25)])
        #expect(joined(iou: 0.25).count == 2)
    }

    @Test func sameTextJoinsEvenIfItMoved() {
        var tracker = FindingTracker(take: "take-001")
        tracker.add([email(rect(0.1, 0.1, 0.2, 0.03))], at: at(1))
        tracker.add([email(rect(0.6, 0.7, 0.2, 0.03))], at: at(1.25))
        #expect(tracker.findings(within: whole).count == 1)

        var other = FindingTracker(take: "take-001")
        other.add([email(rect(0.1, 0.1, 0.2, 0.03))], at: at(1))
        other.add([email(rect(0.6, 0.7, 0.2, 0.03), "someone.else@gmail.com")], at: at(1.25))
        #expect(other.findings(within: whole).count == 2)
    }

    @Test func aGapOverHalfASecondSplits() {
        let r = rect(0.3, 0.3, 0.2, 0.04)
        func findings(missing: Int) -> [PrivacyFinding] {
            var tracker = FindingTracker(take: "take-001")
            tracker.add([email(r)], at: at(1))
            for k in 0..<missing { tracker.add([], at: at(1.25 + 0.25 * Double(k))) }
            tracker.add([email(r)], at: at(1.25 + 0.25 * Double(missing)))
            return tracker.findings(within: whole)
        }
        // One sample missed: 0.5 s apart, still one. Two missed: 0.75 s, two.
        #expect(findings(missing: 1).count == 1)
        #expect(findings(missing: 1).first?.keys.map(\.t) == [at(1), at(1.5)])
        #expect(findings(missing: 2).count == 2)
    }

    @Test func differentKindsNeverJoin() {
        let r = rect(0.3, 0.3, 0.2, 0.04)
        var tracker = FindingTracker(take: "take-001")
        tracker.add([FrameObservation(kind: .email, text: "1234 5678", rect: r)], at: at(1))
        tracker.add([FrameObservation(kind: .phone, text: "1234 5678", rect: r)], at: at(1.25))
        tracker.add([FrameObservation(kind: .face, text: nil, rect: r)], at: at(1.5))
        #expect(tracker.findings(within: whole).map(\.kind) == [.email, .phone, .face])
    }

    @Test func facesJoinByPlace() {
        var tracker = FindingTracker(take: "take-001")
        tracker.add([FrameObservation(kind: .face, text: nil, rect: rect(0.4, 0.2, 0.2, 0.3))], at: at(1))
        tracker.add([FrameObservation(kind: .face, text: nil, rect: rect(0.42, 0.21, 0.2, 0.3))], at: at(1.25))
        tracker.add([FrameObservation(kind: .face, text: nil, rect: rect(0.9, 0.6, 0.1, 0.15))], at: at(1.5))
        let findings = tracker.findings(within: whole)
        #expect(findings.count == 2)
        #expect(findings.map(\.masked) == ["", ""])
    }

    @Test func spanIsWidenedAndRectsGrown() throws {
        let r = rect(0.4, 0.4, 0.2, 0.05)
        var tracker = FindingTracker(take: "take-001")
        for k in 0...4 { tracker.add([email(r)], at: at(2 + 0.25 * Double(k))) }
        let finding = try #require(tracker.findings(within: whole).first)
        #expect(finding.start == at(1.75))
        #expect(finding.end == at(3.25))
        // 0.2 × 0.05 = 0.01 more on each side.
        #expect(!finding.keys.isEmpty)
        for key in finding.keys { #expect(close(key.rect, rect(0.39, 0.39, 0.22, 0.07))) }

        // At the content's edge, what is outside is cut off, never moved inside.
        var edge = FindingTracker(take: "take-001")
        edge.add([email(rect(0, 0.96, 0.1, 0.04))], at: at(5))
        let key = try #require(edge.findings(within: whole).first?.keys.first)
        #expect(close(key.rect, rect(0, 0.952, 0.108, 0.048)))

        // At the ends of the take, the span stops there.
        var ends = FindingTracker(take: "take-001")
        ends.add([email(r)], at: at(0))
        ends.add([email(r, "other@mail.com")], at: at(99.9))
        let spans = ends.findings(within: whole).map { $0.start..<$0.end }
        #expect(spans == [at(0)..<at(0.25), at(99.65)..<at(100)])
    }

    @Test func aStillFindingKeepsItsFirstAndLastKeys() throws {
        let r = rect(0.2, 0.5, 0.3, 0.04)
        var tracker = FindingTracker(take: "take-001")
        for k in 0..<40 { tracker.add([email(r)], at: at(1 + 0.25 * Double(k))) }
        let finding = try #require(tracker.findings(within: whole).first)
        #expect(finding.keys.map(\.t) == [at(1), at(10.75)])
        for s in instants(0.75, 10.99, step: 0.37) { #expect(close(hidden(by: finding, at: at(s)), grown(r))) }
    }

    @Test func scrollingTextIsHiddenAllAlong() throws {
        // Up 0.08 a sample, far more than its height (IoU 0): the same text keeps it one finding.
        let height = 0.03
        func place(_ s: Double) -> NormalizedRect { rect(0.2, 0.8 - 0.32 * (s - 1), 0.3, height) }
        var tracker = FindingTracker(take: "take-001")
        for k in 0...8 {
            let s = 1 + 0.25 * Double(k)
            tracker.add([email(place(s))], at: at(s))
        }
        let finding = try #require(tracker.findings(within: whole).first)
        #expect(tracker.findings(within: whole).count == 1)
        #expect(finding.start == at(0.75) && finding.end == at(3.25))
        // Where it is at every instant, moving on as it did before the first sample and after the last one.
        for s in instants(0.75, 3.249) {
            #expect(contains(hidden(by: finding, at: at(s)), place(s)), "at \(s) s")
        }
        // Between two samples, both places, however it went from one to the other.
        for k in 0..<8 {
            let (a, b) = (1 + 0.25 * Double(k), 1.25 + 0.25 * Double(k))
            for s in instants(a, b) {
                let shown = hidden(by: finding, at: at(s))
                #expect(contains(shown, place(a)) && contains(shown, place(b)), "at \(s) s")
            }
        }
    }

    @Test func aJumpBetweenSamplesIsHiddenAllAlong() throws {
        // Another window comes up between two samples with the same address elsewhere: a cut, not a scroll.
        let (a, b) = (rect(0.05, 0.05, 0.25, 0.03), rect(0.65, 0.85, 0.25, 0.03))
        var tracker = FindingTracker(take: "take-001")
        tracker.add([email(a)], at: at(1))
        tracker.add([email(a)], at: at(1.25))
        tracker.add([email(b)], at: at(1.5))
        tracker.add([email(b)], at: at(1.75))
        let finding = try #require(tracker.findings(within: whole).first)
        #expect(tracker.findings(within: whole).count == 1)
        for s in instants(1.25, 1.5) {
            let shown = hidden(by: finding, at: at(s))
            #expect(contains(shown, a) && contains(shown, b), "at \(s) s")
        }
        for s in instants(0.75, 1.25) { #expect(contains(hidden(by: finding, at: at(s)), a)) }
        for s in instants(1.5, 1.99) { #expect(contains(hidden(by: finding, at: at(s)), b)) }
    }

    @Test func manySimultaneousFindingsStayApart() throws {
        // A list of forty addresses scrolling up by more than half a row a sample: each address overlaps the last place
        // of the one above it more than its own (IoU 0.43 against 0.18), and its text keeps it apart.
        let (rowHeight, step) = (0.02, 0.014)
        func place(row: Int, sample k: Int) -> NormalizedRect {
            rect(0.1, 0.06 + 0.022 * Double(row) - step * Double(k), 0.3, rowHeight)
        }
        var tracker = FindingTracker(take: "take-001")
        for k in 0..<5 {
            tracker.add((0..<40).map { email(place(row: $0, sample: k), "user\($0)@mail.com") }, at: at(1 + 0.25 * Double(k)))
        }
        let findings = tracker.findings(within: whole)
        #expect(findings.count == 40)
        for (row, finding) in findings.enumerated() {
            #expect(finding.keys.count == 5)
            for k in 0..<5 {
                let shown = hidden(by: finding, at: at(1 + 0.25 * Double(k)))
                #expect(contains(shown, place(row: row, sample: k)), "row \(row), sample \(k)")
                // Never stretched over another row's place: no more than its own places one sample apart, grown.
                #expect(shown.height < 3 * rowHeight)
            }
        }

        // The same address twice on screen: two findings, each where it is.
        let (top, bottom) = (rect(0.1, 0.1, 0.3, 0.02), rect(0.1, 0.7, 0.3, 0.02))
        var twice = FindingTracker(take: "take-001")
        for k in 0..<3 { twice.add([email(top), email(bottom)], at: at(1 + 0.25 * Double(k))) }
        let both = twice.findings(within: whole)
        #expect(both.count == 2)
        #expect(both.map { close($0.keys[0].rect, grown(top)) || close($0.keys[0].rect, grown(bottom)) } == [true, true])
        #expect(both.map { $0.keys.map(\.t) } == [[at(1), at(1.5)], [at(1), at(1.5)]])
    }

    @Test func oneKeyAtAnInstant() throws {
        // At a crossfade the screen being left and the one shown are looked at the same instant: what both show adds
        // to that instant, a finding taking one of it.
        let r = rect(0.3, 0.3, 0.2, 0.04)
        var tracker = FindingTracker(take: "take-001")
        tracker.add([email(r)], at: at(1))
        tracker.add([email(r)], at: at(1.25))
        tracker.add([email(r)], at: at(1.25))
        let findings = tracker.findings(within: whole)
        #expect(findings.map { $0.keys.map(\.t) } == [[at(1), at(1.25)], [at(1.25)]])
    }

    @Test func onlyWhatIsInTheSpanCounts() {
        var tracker = FindingTracker(take: "take-001")
        for k in 0...8 { tracker.add([email(rect(0.3, 0.3, 0.2, 0.04))], at: at(1 + 0.25 * Double(k))) }
        #expect(tracker.findings(within: at(5)..<at(10)).isEmpty)
        let cut = tracker.findings(within: at(2)..<at(10))
        #expect(cut.map { $0.start..<$0.end } == [at(2)..<at(3.25)])
        #expect(cut.first?.keys.first?.t == at(2))
    }

    @Test func unusableRectsAreLeftOut() {
        var tracker = FindingTracker(take: "take-001")
        tracker.add([
            email(rect(.nan, 0.3, 0.2, 0.04)), email(rect(0.3, 0.3, 0, 0.04)), email(rect(1.2, 0.3, 0.2, 0.04)),
            email(rect(0.3, 0.3, .infinity, 0.04)),
        ], at: at(1))
        #expect(tracker.findings(within: whole).isEmpty)
    }

    @Test func findingsCarryMaskedTextOnly() throws {
        var tracker = FindingTracker(take: "take-001")
        tracker.add([
            email(rect(0.1, 0.1, 0.3, 0.03)),
            FrameObservation(kind: .secret, text: "sk_live_\u{34}eC39HqLyjWDarjtT1zdp7dc", rect: rect(0.1, 0.5, 0.4, 0.03)),
        ], at: at(1))
        let findings = tracker.findings(within: whole)
        #expect(findings.map(\.masked) == ["an•••@g•••.com", "sk_live_•••"])
        let json = String(decoding: try ProjectJSON.encoder().encode(findings), as: UTF8.self)
        for plain in ["ana.perez", "gmail", "4eC39HqLyjWDarjtT1zdp7dc"] { #expect(!json.contains(plain)) }
        #expect(try ProjectJSON.decoder().decode([PrivacyFinding].self, from: Data(json.utf8)) == findings)
    }

    @Test func theBlockIsABlurOfItsKind() throws {
        var tracker = FindingTracker(take: "take-007")
        tracker.add([FrameObservation(kind: .token, text: "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5", rect: rect(0.1, 0.1, 0.4, 0.03))], at: at(1))
        tracker.add([FrameObservation(kind: .token, text: "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5", rect: rect(0.1, 0.2, 0.4, 0.03))], at: at(1.25))
        let finding = try #require(tracker.findings(within: whole).first)
        let block = finding.block(id: "p-1234abcd")
        #expect(block == PrivacyBlock(
            id: "p-1234abcd", take: "take-007", start: finding.start, end: finding.end, effect: .blur, strength: 0.6,
            rect: finding.keys[0].rect, keys: finding.keys, origin: .secret))
        #expect(finding.masked == "Zm9•••")
    }
}
