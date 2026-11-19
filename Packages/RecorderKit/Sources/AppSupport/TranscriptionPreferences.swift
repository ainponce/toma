// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import os

/// What the app remembers of transcribing (phase 2 design §5.1 and §5.4; plan 2a decisions 2 and 13), in the app's
/// settings and never in a project: whether a project opening in the editor transcribes by itself ("Transcribe
/// Automatically", Settings ▸ General), the language last chosen by hand, and the threshold of "Shorten Pauses". In a
/// key of its own (`TranscriptionPreferencesStore.key`), apart from `RecorderSettings`.
public struct TranscriptionPreferences: Codable, Equatable, Sendable {
    /// A project without a transcript transcribes as it opens in the editor, if its language is installed.
    public var automatic: Bool = true
    /// The language chosen by hand last, as BCP 47 (`es-MX`); `nil` until one is.
    public var language: String? = nil
    /// The pauses "Shorten Pauses" shortens, in nanoseconds: one of `TranscriptCommands.pauseThresholds`.
    public var pauseThreshold: Int64 = TranscriptCommands.defaultPauseThreshold

    public init(automatic: Bool = true, language: String? = nil, pauseThreshold: Int64 = TranscriptCommands.defaultPauseThreshold) {
        self.automatic = automatic
        self.language = language
        self.pauseThreshold = pauseThreshold
    }

    /// A field missing from what was saved, or that cannot be read (of another type, an empty language, a threshold
    /// "Shorten Pauses" does not offer), takes its default; the others are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TranscriptionPreferences()
        automatic = (try? container.decodeIfPresent(Bool.self, forKey: .automatic)) ?? defaults.automatic
        let language = (try? container.decodeIfPresent(String.self, forKey: .language)) ?? nil
        self.language = language?.isEmpty == false ? language : defaults.language
        let threshold = (try? container.decodeIfPresent(Int64.self, forKey: .pauseThreshold)) ?? defaults.pauseThreshold
        pauseThreshold = TranscriptCommands.pauseThresholds.contains(threshold) ? threshold : defaults.pauseThreshold
    }
}

/// Where `TranscriptionPreferences` are saved: the user's defaults, under `key`.
@MainActor
public final class TranscriptionPreferencesStore {
    public static let key = "transcriptionPreferences"

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Settings")
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// What was saved last; the defaults when nothing was, or what was saved is not preferences at all.
    public var preferences: TranscriptionPreferences {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return TranscriptionPreferences() }
            do {
                return try JSONDecoder().decode(TranscriptionPreferences.self, from: data)
            } catch {
                Self.logger.error("Cannot read the transcription preferences, using the defaults: \(String(describing: error), privacy: .public)")
                return TranscriptionPreferences()
            }
        }
        set {
            do {
                defaults.set(try JSONEncoder().encode(newValue), forKey: Self.key)
            } catch {
                Self.logger.error("Cannot save the transcription preferences: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
