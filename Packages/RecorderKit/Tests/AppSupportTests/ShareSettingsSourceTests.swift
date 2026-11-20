// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Sharing
import Testing

// What `toma` reads of the app's settings (plan 5a decision 15): Settings ▸ Share and the export's quality, as the app
// saved them, without `AppSupport`.

@MainActor @Suite struct ShareSettingsSourceTests {
    @Test func theCommandLineReadsWhatSettingsSaved() throws {
        #expect(ShareSettingsSource.settingsKey == SettingsStore.key)
        #expect(ShareSettingsSource.appDomain == "dev.toma.Toma")
        try withSuite { defaults in
            let share = SharePreferences(
                provider: .s3, endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1", bucket: "videos.toma",
                prefix: "clips/", accessKeyID: "AKIAIOSFODNN7EXAMPLE", publicBaseURL: "https://videos.example.com",
                linkDays: 3)
            let store = SettingsStore(defaults: defaults)
            store.settings = RecorderSettings(countdownSeconds: 5, export: ExportPreferences(highQuality: true), share: share)
            #expect(ShareSettingsSource.read(defaults) == SavedShareSettings(preferences: share, highQuality: true))
            store.settings.export.highQuality = false
            #expect(ShareSettingsSource.read(defaults).highQuality == false)
        }
    }

    @Test func missingOrBrokenSettingsAreDefaults() throws {
        let defaultSettings = SavedShareSettings(preferences: SharePreferences(), highQuality: false)
        #expect(ShareSettingsSource.read(nil) == defaultSettings)
        try withSuite { defaults in
            #expect(ShareSettingsSource.read(defaults) == defaultSettings)
            // Each of these reads as the app reads it.
            let saved = [
                "not json",
                #"[1, 2]"#,
                #"{"countdownSeconds": 5}"#,
                #"{"share": 5, "export": {"highQuality": true}}"#,
                #"{"share": {"bucket": "b", "linkDays": "x"}, "export": 3}"#,
                #"{"share": {"provider": "nope", "bucket": "b"}, "export": {"highQuality": "yes", "shortSide": 720}}"#,
            ]
            for text in saved {
                defaults.set(Data(text.utf8), forKey: SettingsStore.key)
                let app = SettingsStore(defaults: defaults).settings
                let read = ShareSettingsSource.read(defaults)
                #expect(read == SavedShareSettings(preferences: app.share, highQuality: app.export.highQuality), "\(text)")
            }
            defaults.set(Data(#"{"share": 5, "export": {"highQuality": true}}"#.utf8), forKey: SettingsStore.key)
            #expect(ShareSettingsSource.read(defaults) == SavedShareSettings(preferences: SharePreferences(), highQuality: true))
            defaults.set(Data(#"{"share": {"bucket": "b"}}"#.utf8), forKey: SettingsStore.key)
            #expect(ShareSettingsSource.read(defaults).preferences == SharePreferences(bucket: "b"))
            // Not data at all.
            defaults.set("text", forKey: SettingsStore.key)
            #expect(ShareSettingsSource.read(defaults) == defaultSettings)
        }
    }

    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ShareSettingsSourceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
