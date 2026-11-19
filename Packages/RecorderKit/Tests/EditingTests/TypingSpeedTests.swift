// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import Editing
import ProjectFormat

/// `typingSpeed-1` over a take whose clips start at the source second 0 of `TwoClips.base`.
@Suite struct TypingSpeedTests {
    private typealias F = TwoClips

    /// `keyActivity` every 0.25 s from `from` to `to` seconds.
    private func keys(_ from: Double, _ to: Double) -> [InputEvent] {
        let count = Int(((to - from) / 0.25).rounded())
        return (0...count).map { InputEvent(t: F.at(from + Double($0) * 0.25), kind: .keyActivity) }
    }

    private func document(_ clips: [Clip] = [F.clip(1, from: 0, to: 30)]) -> EditDocument { F.document(clips) }

    private func spans(_ doc: EditDocument, _ events: [InputEvent]) -> [SourceRange] {
        TypingSpeed.spans(doc, take: F.take, events: events)
    }

    private func apply(_ doc: EditDocument, _ events: [InputEvent], speed: Double = 3, ids: F.CountingIDs = F.CountingIDs()) -> EditStep? {
        TypingSpeed.apply(doc, take: F.take, events: events, speed: speed, makeID: ids.make)
    }

    @Test func onlySpansOfTwoSecondsOrMoreShrunkAQuarterEachSide() {
        // Typing 1.0 to 4.0 s is the span [1.0, 4.25); 6.0 to 7.0 s, [6.0, 7.25), too short.
        let found = spans(document(), keys(1, 4) + keys(6, 7))
        #expect(found == [SourceRange(take: F.takeID, start: F.at(1.25), end: F.at(4.0))])
    }

    @Test func aSpanSplitsItsClipAndSpeedsTheMiddle() throws {
        let doc = document()
        let ids = F.CountingIDs()
        let step = try #require(apply(doc, keys(1, 4), ids: ids))
        let edited = try F.applying(step, to: doc)
        #expect(edited.sequence.map(\.start) == [F.at(0), F.at(1.25), F.at(4.0)])
        #expect(edited.sequence.map(\.end) == [F.at(1.25), F.at(4.0), F.at(30)])
        #expect(edited.sequence.map(\.speed) == [1, 3, 1])
        #expect(edited.sequence.map(\.id) == ["c-00000001"] + ids.made)
        #expect(ids.made.count == 2)
        #expect(step.changes.count == 3)
        #expect(step.target == "c-00000001")
    }

    @Test func clipsAtAnotherSpeedAreLeftAlone() {
        let doc = document([F.clip(1, from: 0, to: 30, speed: 0.5)])
        #expect(spans(doc, keys(1, 4)).isEmpty)
        #expect(apply(doc, keys(1, 4)) == nil)
    }

    @Test func aSpanAcrossACutSpeedsBothSides() throws {
        // Output 0-4 s is the source 0-4 s, output 4-8 s the source 10-14 s: typing 2.0 to 6.0 (source 12 s).
        let doc = document([F.clip(1, from: 0, to: 4), F.clip(2, from: 10, to: 14)])
        let events = keys(2, 3.75) + keys(10, 12)
        let step = try #require(apply(doc, events))
        let edited = try F.applying(step, to: doc)
        let sped = edited.sequence.filter { $0.speed == 3 }
        #expect(sped.count == 2)
        #expect(sped.map(\.take) == [F.takeID, F.takeID])
        #expect(Set(step.target.split(separator: ",")) == ["c-00000001", "c-00000002"])
    }

    @Test func piecesShorterThanAFrameAreNotMade() throws {
        // The stretch ends 0.5 frame before the end of the clip: the clip is not split there.
        let end = 4.0 + F.frame.asSeconds / 2
        let doc = document([F.clip(1, from: 0, to: end)])
        let step = try #require(apply(doc, keys(1, 4.0)))
        let edited = try F.applying(step, to: doc)
        #expect(edited.sequence.count == 2)
        #expect(edited.sequence.map(\.speed) == [1, 3])
        #expect(edited.sequence.last?.end == F.at(end))
    }

    @Test func summaryCountsAndTimes() {
        // Stretches of exactly 6 s and 3 s.
        let events = keys(1, 7.25) + keys(10, 13.25)
        let summary = TypingSpeed.summary(document(), take: F.take, events: events, speed: 3)
        #expect(summary == TypingSpeed.Summary(count: 2, before: F.output(9), after: F.output(3)))
    }

    @Test func noTypingIsNoStep() {
        #expect(apply(document(), []) == nil)
        #expect(apply(document(), keys(1, 2.5)) == nil)
        #expect(TypingSpeed.summary(document(), take: F.take, events: [], speed: 3) == TypingSpeed.Summary(count: 0, before: 0, after: 0))
    }

    @Test func labelIsSpeedTyping() throws {
        let step = try #require(apply(document(), keys(1, 4)))
        #expect(step.label == .speedTyping)
        #expect(TypingSpeed.id == "typingSpeed-1")
        #expect(TypingSpeed.speeds == [2, 3, 4, 8])
        #expect(TypingSpeed.defaultSpeed == 3)
    }
}

private extension Int64 {
    var asSeconds: Double { Double(self) / 1e9 }
}
