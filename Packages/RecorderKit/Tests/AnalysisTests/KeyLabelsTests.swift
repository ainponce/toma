// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Analysis

@Suite struct KeyLabelsTests {
    static let shift = KeyLabels.shiftBit, control = KeyLabels.controlBit, option = KeyLabels.optionBit
    static let command = KeyLabels.commandBit, fn = KeyLabels.functionBit

    @Test func shortcutsAreCommandOrControlOrAModifiedSpecialKey() {
        #expect(KeyLabels.isShortcut(code: 8, mods: Self.command))
        #expect(KeyLabels.isShortcut(code: 0, mods: Self.control))
        #expect(KeyLabels.isShortcut(code: 123, mods: Self.shift))
        #expect(KeyLabels.isShortcut(code: 36, mods: Self.option))
        #expect(!KeyLabels.isShortcut(code: 0, mods: Self.shift))
        #expect(!KeyLabels.isShortcut(code: 14, mods: Self.option))
        #expect(!KeyLabels.isShortcut(code: 123, mods: 0))
        // An arrow comes with fn on a laptop: still not a shortcut.
        #expect(!KeyLabels.isShortcut(code: 123, mods: Self.fn))
        #expect(!KeyLabels.isShortcut(code: 49, mods: Self.shift))
        #expect(KeyLabels.isShortcut(code: 49, mods: Self.command))
    }

    @Test func labelsReadLikeTheDesign() {
        let mods = Self.command | Self.shift
        #expect(KeyLabels.modifiers(mods) == ["⌘", "⇧"])
        #expect(KeyLabels.key(code: 21, chars: "$", mods: mods) == "4")
        #expect(KeyLabels.modifiers(Self.control | Self.option | Self.command | Self.shift | Self.fn) == ["⌘", "⇧", "⌥", "⌃"])
        #expect(KeyLabels.modifiers(Self.option) + [KeyLabels.key(code: 123, chars: nil)!] == ["⌥", "←"])
        #expect(KeyLabels.key(code: 111, chars: nil) == "F12")
        #expect(KeyLabels.key(code: 53, chars: nil) == "esc")
        #expect(KeyLabels.key(code: 51, chars: nil) == "⌫")
        #expect(KeyLabels.key(code: 49, chars: " ") == "␣")
        #expect(KeyLabels.key(code: 8, chars: "c") == "C")
        #expect(KeyLabels.key(code: 8, chars: nil) == nil)
        #expect(KeyLabels.isSpecial(code: 90))
        #expect(!KeyLabels.isSpecial(code: 0))
    }
}
