// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import RecorderKitTestSupport
import Testing

@MainActor @Suite struct TranscriptionPreferencesTests {
    /// By default a project transcribes on opening, in no chosen language, with pauses of 1 s; what is saved is read back
    /// as it was, by another store too.
    @Test func preferencesDefaultAndRoundTrip() throws {
        try withDefaults { defaults in
            let store = TranscriptionPreferencesStore(defaults: defaults)
            #expect(store.preferences == TranscriptionPreferences())
            #expect(store.preferences.automatic)
            #expect(store.preferences.language == nil)
            #expect(store.preferences.pauseThreshold == 1_000_000_000)

            let chosen = TranscriptionPreferences(automatic: false, language: "es-MX", pauseThreshold: 500_000_000)
            store.preferences = chosen
            #expect(store.preferences == chosen)
            #expect(TranscriptionPreferencesStore(defaults: defaults).preferences == chosen)
            // Its own key, apart from the recorder's settings.
            #expect(defaults.data(forKey: TranscriptionPreferencesStore.key) != nil)
            #expect(defaults.data(forKey: SettingsStore.key) == nil)
        }
    }

    /// A field that is missing or cannot be read takes its default; the others are kept. A pause threshold "Shorten
    /// Pauses" does not offer is the default too, and what is not preferences at all reads as the defaults.
    @Test func unreadableFieldsKeepTheirDefaults() throws {
        try withDefaults { defaults in
            let store = TranscriptionPreferencesStore(defaults: defaults)
            defaults.set(Data(#"{"automatic":"x","pauseThreshold":2000000000}"#.utf8), forKey: TranscriptionPreferencesStore.key)
            #expect(store.preferences == TranscriptionPreferences(automatic: true, language: nil, pauseThreshold: 2_000_000_000))

            defaults.set(Data(#"{"automatic":false,"language":7}"#.utf8), forKey: TranscriptionPreferencesStore.key)
            #expect(store.preferences == TranscriptionPreferences(automatic: false, language: nil, pauseThreshold: 1_000_000_000))

            defaults.set(Data(#"{"language":"en-US","pauseThreshold":1234}"#.utf8), forKey: TranscriptionPreferencesStore.key)
            #expect(store.preferences == TranscriptionPreferences(automatic: true, language: "en-US", pauseThreshold: 1_000_000_000))

            defaults.set(Data(#"{"language":""}"#.utf8), forKey: TranscriptionPreferencesStore.key)
            #expect(store.preferences.language == nil)

            defaults.set(Data("not json".utf8), forKey: TranscriptionPreferencesStore.key)
            #expect(store.preferences == TranscriptionPreferences())
        }
    }

    /// A defaults suite of its own, removed when `body` returns.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "TranscriptionPreferencesTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
