// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Testing

// The Replay's shortcut (fases 4 y 5 plan 5c, decision 14): ⌃⌥⌘R by default, given to the settings saved before it, and
// never given back once it was removed.

@Suite struct HotKeyBindingsReplayTests {
    private static let saveReplay = KeyCombo(keyCode: 15, modifiers: [.control, .option, .command], key: "R")
    /// The shortcuts a version of phase 3 saved with its defaults, as it wrote them: no `cleared`.
    private static let phase3JSON = #"""
        {"combos": {"islandOrStop": {"keyCode": 19, "modifiers": 3, "key": "2"},
                    "pauseResume": {"keyCode": 35, "modifiers": 5, "key": "P"},
                    "marker": {"keyCode": 46, "modifiers": 5, "key": "M"}}}
        """#

    private static func decode(_ json: String) throws -> HotKeyBindings {
        try JSONDecoder().decode(HotKeyBindings.self, from: Data(json.utf8))
    }

    @Test func defaultsHaveSaveReplay() {
        #expect(HotKeyAction.allCases.last == .saveReplay)
        #expect(HotKeyAction.saveReplay.rawValue == "saveReplay")
        #expect(HotKeyBindings.defaults.combos[.saveReplay] == Self.saveReplay)
        #expect(Self.saveReplay.displayString == "⌃⌥⌘R" && Self.saveReplay.isAllowedAsGlobalHotKey)
        // The other defaults are as they were.
        #expect(HotKeyBindings.defaults.combos.filter { $0.key != .saveReplay } == [
            .islandOrStop: KeyCombo(keyCode: 19, modifiers: [.shift, .command], key: "2"),
            .pauseResume: KeyCombo(keyCode: 35, modifiers: [.option, .command], key: "P"),
            .marker: KeyCombo(keyCode: 46, modifiers: [.option, .command], key: "M"),
        ])
        // Settings saved before there were shortcuts get them all.
        let old = try? JSONDecoder().decode(RecorderSettings.self, from: Data(#"{"countdownSeconds": 5}"#.utf8))
        #expect(old?.hotKeys == .defaults)
    }

    @Test func phase3BindingsGetTheReplayShortcut() throws {
        #expect(try Self.decode(Self.phase3JSON) == .defaults)
        // Through the settings, as `SettingsStore` reads them.
        let settings = try JSONDecoder().decode(RecorderSettings.self, from: Data(#"{"hotKeys": \#(Self.phase3JSON)}"#.utf8))
        #expect(settings.hotKeys.combos[.saveReplay] == Self.saveReplay)
    }

    @Test func clearedReplayShortcutStaysCleared() throws {
        var bindings = HotKeyBindings.defaults
        bindings.combos[.saveReplay] = nil
        let data = try JSONEncoder().encode(bindings)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["cleared"] as? [String] == ["restartTake", "saveReplay"])
        #expect(try JSONDecoder().decode(HotKeyBindings.self, from: data) == bindings)
        let none = #"{"combos": {}, "cleared": ["islandOrStop", "pauseResume", "marker", "restartTake", "saveReplay"]}"#
        #expect(try Self.decode(none).combos.isEmpty)
    }

    @Test func oldActionsClearedStayCleared() throws {
        // A phase 3 file without the pause's shortcut: the user removed it, and it stays removed.
        let json = #"{"combos": {"islandOrStop": {"keyCode": 19, "modifiers": 3, "key": "2"}}}"#
        #expect(try Self.decode(json).combos == [
            .islandOrStop: KeyCombo(keyCode: 19, modifiers: [.shift, .command], key: "2"), .saveReplay: Self.saveReplay,
        ])
        // Every shortcut removed: only the Replay's, which that version did not have.
        #expect(try Self.decode(#"{"combos": {}}"#).combos == [.saveReplay: Self.saveReplay])
    }

    @Test func aDefaultAnotherActionHoldsIsNotGiven() throws {
        // In phase 3 the user gave ⌃⌥⌘R to restarting the take: one shortcut does one thing.
        let json = #"{"combos": {"restartTake": {"keyCode": 15, "modifiers": 13, "key": "R"}}}"#
        #expect(try Self.decode(json).combos == [.restartTake: Self.saveReplay])
    }

    @Test func anActionLaterThanTheFileGetsItsDefault() throws {
        // A file with `cleared` named every action its version knew: one it names in neither list came later.
        let json = #"{"combos": {"marker": {"keyCode": 46, "modifiers": 5, "key": "M"}}, "cleared": ["islandOrStop", "pauseResume", "restartTake"]}"#
        #expect(try Self.decode(json).combos == [
            .marker: KeyCombo(keyCode: 46, modifiers: [.option, .command], key: "M"), .saveReplay: Self.saveReplay,
        ])
        // Names this version does not know, in either list, are left out.
        let newer = #"{"combos": {"zoom": {"keyCode": 6, "modifiers": 1, "key": "Z"}}, "cleared": ["islandOrStop", "pauseResume", "marker", "restartTake", "saveReplay", "later"]}"#
        #expect(try Self.decode(newer).combos.isEmpty)
    }

    @Test func activeActionsWithReplay() {
        #expect(HotKeyBindings.activeActions(isRecording: false, replayOn: true) == [.islandOrStop, .saveReplay])
        #expect(HotKeyBindings.activeActions(isRecording: false, replayOn: false) == [.islandOrStop])
        #expect(HotKeyBindings.activeActions(isRecording: false) == [.islandOrStop])
        // During a take, today's: the Replay is off while a take records.
        let take: [HotKeyAction] = [.islandOrStop, .pauseResume, .marker, .restartTake]
        #expect(HotKeyBindings.activeActions(isRecording: true) == take)
        #expect(HotKeyBindings.activeActions(isRecording: true, replayOn: true) == take)
    }

    @Test func bindingsRoundTrip() throws {
        let cases: [HotKeyBindings] = [
            .defaults,
            HotKeyBindings(combos: [:]),
            HotKeyBindings(combos: [.saveReplay: KeyCombo(keyCode: 1, modifiers: [.control, .command], key: "S")]),
            HotKeyBindings(combos: [
                .restartTake: KeyCombo(keyCode: 15, modifiers: [.control, .command], key: "R"), .marker: Self.saveReplay,
            ]),
        ]
        for bindings in cases {
            let data = try JSONEncoder().encode(bindings)
            #expect(try JSONDecoder().decode(HotKeyBindings.self, from: data) == bindings)
            let settings = RecorderSettings(hotKeys: bindings)
            #expect(try JSONDecoder().decode(RecorderSettings.self, from: JSONEncoder().encode(settings)).hotKeys == bindings)
        }
    }
}
