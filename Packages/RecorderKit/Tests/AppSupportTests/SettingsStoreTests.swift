// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

@MainActor @Suite struct SettingsStoreTests {
    @Test func settingsRoundTripAndDefaults() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(store.settings == RecorderSettings(selection: nil, quick: QuickSettings(), countdownSeconds: 3))
            #expect(store.settings.countdownSeconds == 3 && store.settings.quick == QuickSettings())

            let selection = CaptureSelection(
                mode: .area, displayIDs: [2, 1], windowID: 42,
                area: AreaChoice(displayID: 2, rect: Rect(x: -1920, y: 0, width: 640, height: 360)),
                camera: .device(uniqueID: "camera-1"), microphone: .off, systemAudio: .applications(["com.example.app"]))
            let settings = RecorderSettings(
                selection: selection,
                quick: QuickSettings(framesPerSecondByDisplay: [1: 30, 2: 120], displayScale: .points),
                countdownSeconds: 5)
            store.settings = settings
            #expect(store.settings == settings)
            // Another store reads what this one saved.
            #expect(SettingsStore(defaults: defaults).settings == settings)
        }
    }

    @Test func settingsWithMissingKeysUseDefaults() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)

            defaults.set(Data(#"{"countdownSeconds":10}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings == RecorderSettings(selection: nil, quick: QuickSettings(), countdownSeconds: 10))

            // Saved by a version whose quick settings had no display scale.
            let saved = RecorderSettings(
                selection: .mainDisplay(1), quick: QuickSettings(framesPerSecondByDisplay: [1: 30], displayScale: .points))
            var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            var quick = try #require(json["quick"] as? [String: Any])
            #expect(quick.removeValue(forKey: "displayScale") != nil)
            json["quick"] = quick
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: SettingsStore.key)
            #expect(store.settings.quick == QuickSettings(framesPerSecondByDisplay: [1: 30], displayScale: .native))
            #expect(store.settings.selection == .mainDisplay(1) && store.settings.countdownSeconds == 3)

            defaults.set(Data("not settings".utf8), forKey: SettingsStore.key)
            #expect(store.settings == RecorderSettings())
        }
    }

    /// A defaults suite of its own, removed when `body` returns.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
