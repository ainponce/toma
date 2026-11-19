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

    @Test func theKeysOwnCharacterIsItsLabelOnAnyKeyboard() {
        let mods = Self.command | Self.shift
        // A Spanish keyboard: ⇧7 types "/", ⇧2 a double quote, ⇧4 "$". The key's own character is what the shortcut shows.
        #expect(KeyLabels.key(code: 26, chars: "/", mods: mods, key: "7") == "7")
        #expect(KeyLabels.key(code: 19, chars: "\"", mods: mods, key: "2") == "2")
        #expect(KeyLabels.key(code: 21, chars: "$", mods: mods, key: "4") == "4")
        // A letter is a capital either way; a key that types nothing keeps its special label.
        #expect(KeyLabels.key(code: 0, chars: "A", mods: mods, key: "a") == "A")
        #expect(KeyLabels.key(code: 41, chars: "Ñ", mods: Self.command, key: "ñ") == "Ñ")
        #expect(KeyLabels.key(code: 123, chars: nil, mods: Self.shift, key: nil) == "←")
        // A line recorded without `key` (or with an empty one): the US way back from what ⇧ typed, wrong on that
        // keyboard for ⇧7 and ⇧2 but right where it agrees with US (⇧4).
        #expect(KeyLabels.key(code: 26, chars: "/", mods: mods) == "/")
        #expect(KeyLabels.key(code: 19, chars: "\"", mods: mods) == "'")
        #expect(KeyLabels.key(code: 21, chars: "$", mods: mods, key: "") == "4")
        #expect(KeyLabels.key(code: 8, chars: nil, mods: Self.command, key: nil) == nil)
    }
}
