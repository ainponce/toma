// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What `toma share` needs of the app's settings: Settings ▸ Share and the export sheet's quality.
public struct SavedShareSettings: Equatable, Sendable {
    public var preferences: SharePreferences
    public var highQuality: Bool

    public init(preferences: SharePreferences, highQuality: Bool) {
        self.preferences = preferences
        self.highQuality = highQuality
    }
}

/// Reads what the app saved (`SettingsStore`, JSON under `recorderSettings` in the defaults of `dev.toma.Toma`) for the
/// command line, which does not link `AppSupport`: only `share` and `export.highQuality`, each decoded as
/// `RecorderSettings` decodes it, so `toma` shares to the same storage as the app. Never the secret: it is not there.
public enum ShareSettingsSource {
    public static let appDomain = "dev.toma.Toma"
    public static let settingsKey = "recorderSettings"

    /// `share` and `export.highQuality` of the settings the app saved; what is missing or cannot be read, the defaults.
    public static func read(_ defaults: UserDefaults? = UserDefaults(suiteName: appDomain)) -> SavedShareSettings {
        let fallback = SavedShareSettings(preferences: SharePreferences(), highQuality: false)
        guard let data = defaults?.data(forKey: settingsKey),
            let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return fallback }
        return SavedShareSettings(
            preferences: saved.share ?? fallback.preferences,
            highQuality: saved.export?.highQuality ?? fallback.highQuality)
    }

    /// The two parts of `RecorderSettings` read; each that cannot be read is `nil`, as `RecorderSettings` keeps its
    /// default.
    private struct Saved: Decodable {
        var share: SharePreferences?
        var export: Export?

        struct Export: Decodable {
            var highQuality: Bool?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                highQuality = try? container.decodeIfPresent(Bool.self, forKey: .highQuality)
            }

            private enum CodingKeys: String, CodingKey { case highQuality }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            share = try? container.decodeIfPresent(SharePreferences.self, forKey: .share)
            export = try? container.decodeIfPresent(Export.self, forKey: .export)
        }

        private enum CodingKeys: String, CodingKey { case share, export }
    }
}
