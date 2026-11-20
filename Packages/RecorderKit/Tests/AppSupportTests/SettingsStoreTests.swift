// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Testing

@MainActor @Suite struct SettingsStoreTests {
    @Test func settingsRoundTripAndDefaults() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(store.settings == RecorderSettings(selection: nil, quick: QuickSettings(), countdownSeconds: 3))
            #expect(store.settings.countdownSeconds == 3 && store.settings.quick == QuickSettings())
            #expect(!store.settings.hideDesktopIcons)

            let selection = CaptureSelection(
                mode: .area, displayIDs: [2, 1], windowID: 42, windowOwner: WindowOwner(bundleID: "com.apple.Safari", name: "Safari"),
                area: AreaChoice(displayID: 2, rect: Rect(x: -1920, y: 0, width: 640, height: 360)),
                camera: .device(uniqueID: "camera-1"), microphone: .off, systemAudio: .applications(["com.example.app"]))
            let settings = RecorderSettings(
                selection: selection,
                quick: QuickSettings(framesPerSecondByDisplay: [1: 30, 2: 120], displayScale: .points),
                countdownSeconds: 5, focusShortcutIdentifier: "2D1E36B2-5C9A-4F83-9C67-1A2B3C4D5E6F", hideDesktopIcons: true)
            store.settings = settings
            #expect(store.settings == settings)
            // Another store reads what this one saved.
            #expect(SettingsStore(defaults: defaults).settings == settings)
        }
    }

    @Test func phase3SettingsDecodeWithDefaultShareAndReplay() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            // What phase 3 saved has neither `share` nor `replay`.
            defaults.set(Data(#"{"countdownSeconds":5,"recordKeys":true}"#.utf8), forKey: SettingsStore.key)
            let settings = store.settings
            #expect(settings.countdownSeconds == 5 && settings.recordKeys)
            #expect(settings.share == SharePreferences() && settings.replay == ReplayPreferences())
            #expect(
                settings.share == SharePreferences(
                    provider: .r2, endpoint: "", region: "auto", bucket: "", prefix: "toma/", accessKeyID: "", publicBaseURL: "", linkDays: 7))
            #expect(settings.replay == ReplayPreferences(enabled: false, seconds: 30))
            #expect(ReplayPreferences.validSeconds == [15, 30, 60, 120, 300])
            // A length the settings do not offer, or a provider this version does not know, takes its default.
            defaults.set(
                Data(#"{"share":{"provider":"gcs","bucket":"b"},"replay":{"enabled":true,"seconds":7}}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings.share == SharePreferences(bucket: "b"))
            #expect(store.settings.replay == ReplayPreferences(enabled: true, seconds: 30))
            // And they round-trip.
            var changed = RecorderSettings()
            changed.share = SharePreferences(provider: .minio, endpoint: "http://localhost:9000", bucket: "x", linkDays: 1)
            changed.replay = ReplayPreferences(enabled: true, seconds: 120)
            store.settings = changed
            #expect(store.settings == changed)
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
            try save(saved, in: defaults, changing: "quick") { #expect($0.removeValue(forKey: "displayScale") != nil) }
            #expect(store.settings.quick == QuickSettings(framesPerSecondByDisplay: [1: 30], displayScale: .native))
            #expect(store.settings.selection == .mainDisplay(1) && store.settings.countdownSeconds == 3)

            defaults.set(Data("not settings".utf8), forKey: SettingsStore.key)
            #expect(store.settings == RecorderSettings())
        }
    }

    @Test func quickSettingsSavedBeforeTheNewFieldsKeepTheirValues() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            // Saved as Task 14a did: frame rates by display and the scale, without the window's and the camera's.
            let saved = RecorderSettings(
                selection: .mainDisplay(1),
                quick: QuickSettings(
                    framesPerSecondByDisplay: [1: 30, 2: 120], displayScale: .points, windowFramesPerSecond: 24, cameraPreset: .p2160,
                    cameraFramesPerSecond: 60))
            try save(saved, in: defaults, changing: "quick") { quick in
                for key in ["windowFramesPerSecond", "cameraPreset", "cameraFramesPerSecond"] {
                    #expect(quick.removeValue(forKey: key) != nil, "\(key)")
                }
            }
            let quick = store.settings.quick
            #expect(quick.framesPerSecondByDisplay == [1: 30, 2: 120] && quick.displayScale == .points)
            #expect(quick.windowFramesPerSecond == 60 && quick.cameraPreset == .p1080 && quick.cameraFramesPerSecond == 30)

            // All of them saved now are read back; a preset from another version takes its default.
            store.settings = saved
            #expect(SettingsStore(defaults: defaults).settings == saved)
            try save(saved, in: defaults, changing: "quick") { $0["cameraPreset"] = "p4320" }
            #expect(store.settings.quick == QuickSettings(
                framesPerSecondByDisplay: [1: 30, 2: 120], displayScale: .points, windowFramesPerSecond: 24, cameraFramesPerSecond: 60))
        }
    }

    @Test func frameRatesThatAreNotPositiveTakeTheirDefaults() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let saved = RecorderSettings(
                selection: .mainDisplay(1),
                quick: QuickSettings(framesPerSecondByDisplay: [1: 30], windowFramesPerSecond: 24, cameraFramesPerSecond: 60))
            for value in [0, -30] {
                try save(saved, in: defaults, changing: "quick") { quick in
                    quick["windowFramesPerSecond"] = value
                    quick["cameraFramesPerSecond"] = value
                }
                // Never a frame interval of 1/0 s: the defaults, and the rest is kept.
                #expect(store.settings.quick == QuickSettings(framesPerSecondByDisplay: [1: 30]), "\(value)")
            }
        }
    }

    @Test func aWindowSavedWithoutItsAppHasNone() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            var selection = CaptureSelection.mainDisplay(1)
            selection.mode = .window
            selection.windowID = 42
            selection.windowOwner = WindowOwner(bundleID: "com.apple.Safari", name: "Safari")
            try save(RecorderSettings(selection: selection), in: defaults, changing: "selection") {
                #expect($0.removeValue(forKey: "windowOwner") != nil)
            }
            // Read as saved by a version that did not save the window's app: the island chooses no window for it.
            selection.windowOwner = nil
            #expect(store.settings.selection == selection)
        }
    }

    @Test func settingsThisVersionCannotReadKeepTheRest() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let saved = RecorderSettings(
                selection: .mainDisplay(1), quick: QuickSettings(framesPerSecondByDisplay: [1: 30], displayScale: .points),
                countdownSeconds: 10)

            // A capture mode from another version.
            try save(saved, in: defaults, changing: "selection") { $0["mode"] = "teleport" }
            #expect(store.settings == RecorderSettings(selection: nil, quick: saved.quick, countdownSeconds: 10))

            // A display scale from another version.
            try save(saved, in: defaults, changing: "quick") { $0["displayScale"] = "half" }
            #expect(store.settings == RecorderSettings(
                selection: .mainDisplay(1), quick: QuickSettings(framesPerSecondByDisplay: [1: 30], displayScale: .native),
                countdownSeconds: 10))
        }
    }

    @Test func settingsDefaultToOpeningTheEditor() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(store.settings.afterStop == .openEditor)
            #expect(AfterStop.allCases == [.openEditor, .stayHere])

            // Saved by a version without the setting.
            defaults.set(Data(#"{"countdownSeconds":5}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings.afterStop == .openEditor && store.settings.countdownSeconds == 5)

            var settings = store.settings
            settings.afterStop = .stayHere
            store.settings = settings
            #expect(SettingsStore(defaults: defaults).settings == settings)
            #expect(SettingsStore(defaults: defaults).settings.afterStop == .stayHere)

            // A choice from another version: the default, and the rest is kept.
            defaults.set(Data(#"{"countdownSeconds":10,"afterStop":"ask"}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings.afterStop == .openEditor && store.settings.countdownSeconds == 10)
        }
    }

    @Test func settingsWithoutTeleprompterUseDefaults() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(store.settings.teleprompter == TeleprompterSettings())

            // Saved by a version without the teleprompter.
            defaults.set(Data(#"{"countdownSeconds":5}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings.teleprompter == TeleprompterSettings() && store.settings.countdownSeconds == 5)

            var settings = store.settings
            settings.teleprompter = TeleprompterSettings(isOn: true, script: "Hello, this is Toma.", fontSize: 30, speed: 1.5, opacity: 0.4)
            store.settings = settings
            #expect(SettingsStore(defaults: defaults).settings == settings)

            // Saved by a version whose teleprompter had no opacity: its default, and the rest is kept.
            try save(settings, in: defaults, changing: "teleprompter") { #expect($0.removeValue(forKey: "opacity") != nil) }
            #expect(store.settings.teleprompter == TeleprompterSettings(
                isOn: true, script: "Hello, this is Toma.", fontSize: 30, speed: 1.5, opacity: 0.85))
            #expect(store.settings.countdownSeconds == 5)

            // A value this version cannot read: its default, and the rest is kept.
            try save(settings, in: defaults, changing: "teleprompter") { $0["speed"] = "fast" }
            #expect(store.settings.teleprompter == TeleprompterSettings(
                isOn: true, script: "Hello, this is Toma.", fontSize: 30, speed: 1, opacity: 0.4))
        }
    }

    @Test func settingsRememberTheCameraStyle() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(store.settings.cameraStyle == .default)

            var settings = store.settings
            settings.cameraStyle = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .top)
            store.settings = settings
            #expect(SettingsStore(defaults: defaults).settings.cameraStyle == CameraStyle(shape: .landscape, size: 0.17, anchor: .top))
            #expect(SettingsStore(defaults: defaults).settings == settings)

            // Saved by a version without the camera style.
            defaults.set(Data(#"{"countdownSeconds":5}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings.cameraStyle == .default && store.settings.countdownSeconds == 5)

            // A shape from another version: the default style, and the rest is kept.
            try save(settings, in: defaults, changing: "cameraStyle") { $0["shape"] = "hexagon" }
            #expect(store.settings.cameraStyle == .default && store.settings.countdownSeconds == settings.countdownSeconds)
        }
    }

    @Test func settingsRememberTheSavedAreasAndTheProportion() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(store.settings.savedAreas == SavedAreas() && store.settings.aspectLock == .free)

            var settings = store.settings
            settings.savedAreas.remember(AreaChoice(displayID: 2, rect: Rect(x: -1920, y: 0, width: 1280, height: 720)))
            settings.aspectLock = .tall9x16
            store.settings = settings
            #expect(SettingsStore(defaults: defaults).settings == settings)
            #expect(SettingsStore(defaults: defaults).settings.savedAreas.areas.map(\.displayID) == [2])

            // Saved by a version without them.
            defaults.set(Data(#"{"countdownSeconds":5}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings.savedAreas == SavedAreas() && store.settings.aspectLock == .free)
            // A proportion from another version: free, and the rest is kept.
            var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            json["aspectLock"] = "golden"
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: SettingsStore.key)
            #expect(store.settings.aspectLock == .free && store.settings.savedAreas == settings.savedAreas)
        }
    }

    @Test func settingOffBuildsNoKeyRecorder() throws {
        for noteKeyActivity in [false, true] {
            let factory = LiveCaptureSourceFactory(cameraHost: CameraSessionHost(), noteKeyActivity: noteKeyActivity) { _ in }
            let input = try #require(factory.input(windowTrack: nil, displayIDs: []) as? CompositeInputRecorder)
            #expect(input.recorders.count { $0 is KeyActivityRecorder } == (noteKeyActivity ? 1 : 0), "noteKeyActivity \(noteKeyActivity)")
            // The scroll is recorded either way.
            #expect(input.recorders.count { $0 is ScrollRecorder } == 1)
        }
    }

    @Test func missingSettingIsOn() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(store.settings.noteKeyActivity)

            // Saved by a version without the setting.
            defaults.set(Data(#"{"countdownSeconds":5}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings.noteKeyActivity && store.settings.countdownSeconds == 5)

            var settings = store.settings
            settings.noteKeyActivity = false
            store.settings = settings
            #expect(SettingsStore(defaults: defaults).settings == settings)
            #expect(!SettingsStore(defaults: defaults).settings.noteKeyActivity)

            // A value this version cannot read: on, and the rest is kept.
            defaults.set(Data(#"{"countdownSeconds":10,"noteKeyActivity":"sometimes"}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings.noteKeyActivity && store.settings.countdownSeconds == 10)
        }
    }

    @Test func newProjectsStyleIDRoundTripsAndDefaultsToToma() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            // Toma's style until one is chosen.
            #expect(store.settings.newProjectsStyleID == nil)
            #expect(RecorderSettings().newProjectsStyleID == nil)

            var settings = store.settings
            settings.countdownSeconds = 5
            settings.newProjectsStyleID = "a1b2c3d4"
            store.settings = settings
            #expect(SettingsStore(defaults: defaults).settings.newProjectsStyleID == "a1b2c3d4")
            #expect(SettingsStore(defaults: defaults).settings == settings)

            // Back to Toma's style.
            settings.newProjectsStyleID = nil
            store.settings = settings
            #expect(SettingsStore(defaults: defaults).settings.newProjectsStyleID == nil)
            #expect(SettingsStore(defaults: defaults).settings.countdownSeconds == 5)

            // Saved by 1b, which had no such field: Toma's style, and the rest is kept.
            defaults.set(Data(#"{"countdownSeconds":10,"noteKeyActivity":false}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings.newProjectsStyleID == nil)
            #expect(store.settings.countdownSeconds == 10 && !store.settings.noteKeyActivity)

            // A value this version cannot read: Toma's style, and the rest is kept.
            defaults.set(Data(#"{"countdownSeconds":10,"newProjectsStyleID":42}"#.utf8), forKey: SettingsStore.key)
            #expect(store.settings.newProjectsStyleID == nil && store.settings.countdownSeconds == 10)
        }
    }

    /// Saves `settings` in `defaults` as another version could have: with `change` made to the object at `key`.
    private func save(
        _ settings: RecorderSettings, in defaults: UserDefaults, changing key: String, _ change: (inout [String: Any]) -> Void
    ) throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var object = try #require(json[key] as? [String: Any])
        change(&object)
        json[key] = object
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: SettingsStore.key)
    }

    /// A defaults suite of its own, removed when `body` returns.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
