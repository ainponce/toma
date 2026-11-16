// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Testing

@Suite struct KeyComboTests {
    @Test func keyComboDisplayAndCarbonModifiers() {
        let c = HotKeyBindings.defaults.combos[.islandOrStop]!
        #expect(c.keyCode == 19 && c.displayString == "⇧⌘2" && c.carbonModifiers == 0x300)
        #expect(HotKeyBindings.defaults.combos[.pauseResume]!.displayString == "⌥⌘P")
        #expect(HotKeyBindings.defaults.combos[.pauseResume]!.keyCode == 35)
        #expect(HotKeyBindings.defaults.combos[.marker]!.displayString == "⌥⌘M")
        #expect(HotKeyBindings.defaults.combos[.marker]!.keyCode == 46)
        #expect(HotKeyBindings.defaults.combos[.restartTake] == nil)

        // macOS order, whatever order the modifiers were given in.
        let all = KeyCombo(keyCode: 40, modifiers: [.command, .shift, .option, .control], key: "K")
        #expect(all.displayString == "⌃⌥⇧⌘K" && all.carbonModifiers == 0x1B00)
        #expect(KeyCombo(keyCode: 40, modifiers: .control, key: "K").carbonModifiers == 0x1000)
        #expect(KeyCombo(keyCode: 40, modifiers: .option, key: "K").carbonModifiers == 0x800)

        // The app names some keys in the user's language; what is saved stays as it is.
        let space = KeyCombo(keyCode: 49, modifiers: [.option, .command], key: "Space")
        #expect(space.displayString(keyName: "Espacio") == "⌥⌘Espacio" && space.displayString == "⌥⌘Space")
    }

    @Test func onlyTheIslandShortcutIsActiveAtRest() {
        #expect(HotKeyBindings.activeActions(isRecording: false) == [.islandOrStop])
        #expect(HotKeyBindings.activeActions(isRecording: true) == HotKeyAction.allCases)
    }

    @Test func keyComboNeedsCommandOrControl() {
        #expect(KeyCombo(keyCode: 19, modifiers: [.shift, .command], key: "2").isAllowedAsGlobalHotKey)
        #expect(KeyCombo(keyCode: 40, modifiers: [.control, .option], key: "K").isAllowedAsGlobalHotKey)
        #expect(!KeyCombo(keyCode: 35, modifiers: .option, key: "P").isAllowedAsGlobalHotKey)
        #expect(!KeyCombo(keyCode: 35, modifiers: [.option, .shift], key: "P").isAllowedAsGlobalHotKey)
        #expect(!KeyCombo(keyCode: 35, modifiers: .shift, key: "P").isAllowedAsGlobalHotKey)
        #expect(!KeyCombo(keyCode: 35, modifiers: [], key: "P").isAllowedAsGlobalHotKey)
        #expect(HotKeyBindings.defaults.combos.values.allSatisfy { $0.isAllowedAsGlobalHotKey })
        #expect(HotKeyBindings.defaults.combos.count == 3)
    }

    @Test func bindingsAreSavedWithTheSettings() throws {
        // Only the key code, the modifiers and the key are saved.
        let combo = KeyCombo(keyCode: 19, modifiers: [.shift, .command], key: "2")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(combo)) as? [String: Any]
        #expect(json.map { Set($0.keys) } == ["keyCode", "modifiers", "key"])

        var settings = RecorderSettings()
        #expect(settings.hotKeys == .defaults)
        settings.hotKeys.combos[.restartTake] = KeyCombo(keyCode: 15, modifiers: [.control, .command], key: "R")
        settings.hotKeys.combos[.marker] = nil
        let decoded = try JSONDecoder().decode(RecorderSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.hotKeys == settings.hotKeys)

        // Settings saved before there were shortcuts get the defaults; an action this version does not know
        // is left out.
        let old = try JSONDecoder().decode(RecorderSettings.self, from: Data(#"{"countdownSeconds": 5}"#.utf8))
        #expect(old.hotKeys == .defaults && old.countdownSeconds == 5)
        let newer = Data(#"{"hotKeys": {"combos": {"marker": {"keyCode": 46, "modifiers": 5, "key": "M"}, "zoom": {"keyCode": 6, "modifiers": 1, "key": "Z"}}}}"#.utf8)
        let fromNewer = try JSONDecoder().decode(RecorderSettings.self, from: newer)
        #expect(fromNewer.hotKeys.combos == [.marker: KeyCombo(keyCode: 46, modifiers: [.command, .option], key: "M")])
    }
}
