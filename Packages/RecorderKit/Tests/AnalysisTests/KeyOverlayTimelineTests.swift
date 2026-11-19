// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@testable import Analysis

private let take = "take-001"
private let base: UInt64 = 5_000_000_000_000
private func sec(_ s: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: s) }
private func host(_ s: Double) -> HostTime { HostTime(nanoseconds: base + UInt64(s * 1e9)) }
private let command = KeyLabels.commandBit, shift = KeyLabels.shiftBit, fn = KeyLabels.functionBit

private func key(_ s: Double, code: UInt16 = 0, _ chars: String? = "a", mods: UInt32 = 0, isRepeat: Bool = false) -> InputEvent {
    InputEvent(t: host(s), kind: .keyPress(code: code, chars: chars, mods: mods, isRepeat: isRepeat))
}

private func text(_ s: Double, _ chars: String) -> InputEvent { key(s, chars) }

private func map(_ clips: [(Double, Double, Double)] = [(0, 60, 1)]) -> TimeMap {
    TimeMap(sequence: clips.enumerated().map { i, c in
        Clip(id: "c-0000000\(i)", take: take, start: host(c.0), end: host(c.1), speed: c.2)
    })
}

private func timeline(_ events: [InputEvent], _ mode: KeyOverlayMode = .all, _ map: TimeMap = map()) -> KeyOverlayTimeline {
    KeyOverlayTimeline(events: events, take: take, timeMap: map, mode: mode)
}

@Suite struct KeyOverlayTimelineTests {
    @Test func shortcutModeShowsOnlyShortcuts() {
        let events = [text(1, "h"), text(1.1, "i"), key(2, code: 8, "c", mods: command), key(3, code: 123, nil)]
        let t = timeline(events, .shortcuts)
        #expect(t.shown(atOutput: sec(2.5)) == [KeyOverlayShown(content: .keys(["⌘", "C"]), opacity: 1)])
        #expect(t.shown(atOutput: sec(1.2)).isEmpty)
        #expect(t.shown(atOutput: sec(3.5)).isEmpty)
        #expect(timeline(events, .off).isEmpty)
    }

    @Test func typingJoinsIntoAPillAndCutsFromTheLeft() {
        let letters = Array("abcdefghijklmnopqrstuvwxy")
        let events = letters.enumerated().map { text(1 + Double($0.offset) * 0.1, String($0.element)) }
        let t = timeline(events)
        #expect(t.shown(atOutput: sec(1.25)).first?.content == .text("abc"))
        #expect(t.shown(atOutput: sec(4)).first?.content == .text("…fghijklmnopqrstuvwxy"))
        #expect(t.shown(atOutput: sec(1.0 + 19 * 0.1 + 0.01)).first?.content == .text("abcdefghijklmnopqrst"))
    }

    @Test func aGapOverOneAndAHalfSecondsStartsANewPill() {
        let t = timeline([text(1, "a"), text(2.5, "b"), text(4.1, "c")])
        #expect(t.shown(atOutput: sec(2.6)).map(\.content) == [.text("ab")])
        #expect(t.shown(atOutput: sec(4.2)).map(\.content) == [.text("c")])
        #expect(t.shown(atOutput: sec(4.15)).map(\.content) == [.text("c")])
    }

    @Test func returnEndsThePillAndDeleteRemovesACharacter() {
        let t = timeline([text(1, "a"), text(1.1, "b"), key(1.2, code: 51, nil), text(1.3, "c"), key(1.4, code: 36, nil), text(1.5, "d")])
        #expect(t.shown(atOutput: sec(1.25)).map(\.content) == [.text("a")])
        #expect(t.shown(atOutput: sec(1.35)).map(\.content) == [.text("ac")])
        // The return is not shown; the next key starts a pill that replaces the old one.
        let after = t.shown(atOutput: sec(1.55))
        #expect(after.map(\.content) == [.text("ac"), .text("d")])
        // A delete with nothing to delete is a loose key.
        let bare = timeline([key(1, code: 51, nil)])
        #expect(bare.shown(atOutput: sec(1.5)).map(\.content) == [.keys(["⌫"])])
    }

    @Test func fadesInHoldsAndFadesOut() {
        let t = timeline([text(1, "a"), text(1.4, "b")])
        func opacity(_ s: Double) -> Double { t.shown(atOutput: sec(s)).first?.opacity ?? 0 }
        #expect(opacity(1.0) == 0)
        #expect(abs(opacity(1.05) - 0.5) < 1e-9)
        #expect(opacity(1.1) == 1)
        #expect(opacity(2.4) == 1)
        #expect(abs(opacity(2.5) - 0.5) < 1e-9)
        #expect(opacity(2.6) == 0 && t.shown(atOutput: sec(2.6)).isEmpty)
        #expect(t.shown(atOutput: sec(10)).isEmpty)
    }

    @Test func aShortcutReplacesThePillWithACrossfade() {
        let t = timeline([text(1, "a"), key(1.5, code: 8, "c", mods: command)])
        let mid = t.shown(atOutput: sec(1.55))
        #expect(mid.map(\.content) == [.text("a"), .keys(["⌘", "C"])])
        #expect(mid.allSatisfy { abs($0.opacity - 0.5) < 1e-9 })
        let done = t.shown(atOutput: sec(1.7))
        #expect(done.map(\.content) == [.keys(["⌘", "C"])] && done[0].opacity == 1)
    }

    @Test func rapidShortcutsNeverShowMoreThanTwo() {
        let events = (0..<6).map { key(1 + Double($0) * 0.03, code: 8, "c", mods: command) }
        let t = timeline(events)
        for ms in stride(from: 900, to: 1400, by: 5) { #expect(t.shown(atOutput: sec(Double(ms) / 1000)).count <= 2) }
    }

    @Test func keysInACutAreNotShown() {
        let cut = map([(0, 5, 1), (7, 60, 1)])
        let t = timeline([text(1, "a"), text(5.5, "x"), text(6, "y"), text(8, "b")], .all, cut)
        // 8 s of source is 6 s of output; the cut keys left nothing.
        #expect(t.shown(atOutput: sec(5.5)).isEmpty)
        #expect(t.shown(atOutput: sec(6.2)).map(\.content) == [.text("b")])
        #expect(timeline([text(5.5, "x")], .all, cut).isEmpty)
    }

    @Test func speedCompressesTheTimes() {
        let fast = map([(0, 60, 2)])
        let t = timeline([text(1, "a"), text(2, "b")], .all, fast)
        // Keys at 0.5 s and 1 s of output; the hold is still 1 s of output after the last.
        #expect(t.shown(atOutput: sec(0.7)).map(\.content) == [.text("a")])
        #expect(t.shown(atOutput: sec(1.0)).map(\.content) == [.text("ab")])
        #expect(t.shown(atOutput: sec(2.0)).first?.opacity == 1)
        #expect(t.shown(atOutput: sec(2.3)).isEmpty)
        // Two seconds of source apart would break a pill at 1×; at 2× they are 1 s apart and join.
        #expect(timeline([text(1, "a"), text(3.2, "b")], .all, fast).shown(atOutput: sec(1.7)).map(\.content) == [.text("ab")])
    }

    @Test func repeatsExtendAShortcutAndTypeInAPill() {
        let shortcut = timeline([key(1, code: 123, nil, mods: shift), key(1.5, code: 123, nil, mods: shift, isRepeat: true),
                                 key(2, code: 123, nil, mods: shift, isRepeat: true)])
        #expect(shortcut.shown(atOutput: sec(1.2)).map(\.content) == [.keys(["⇧", "←"])])
        #expect(shortcut.shown(atOutput: sec(2.8)).map(\.content) == [.keys(["⇧", "←"])])
        let pill = timeline([text(1, "a"), key(1.1, code: 0, "a", isRepeat: true), key(1.2, code: 0, "a", isRepeat: true)])
        #expect(pill.shown(atOutput: sec(1.5)).map(\.content) == [.text("aaa")])
    }

    @Test func looseSpecialKeysShowOnlyInAll() {
        let events = [key(1, code: 123, nil, mods: fn), key(3, code: 53, nil)]
        #expect(timeline(events, .shortcuts).isEmpty)
        let t = timeline(events, .all)
        #expect(t.shown(atOutput: sec(1.5)).map(\.content) == [.keys(["←"])])
        #expect(t.shown(atOutput: sec(3.5)).map(\.content) == [.keys(["esc"])])
    }

    @Test func noKeysIsEmpty() {
        #expect(timeline([]).isEmpty)
        #expect(timeline([InputEvent(t: host(1), kind: .keyActivity)]).isEmpty)
        #expect(timeline([]).shown(atOutput: 0).isEmpty)
    }
}
