// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// What the recorder remembers between takes.
public struct RecorderSettings: Codable, Equatable, Sendable {
    /// What was chosen to record last; `nil` until something is chosen.
    public var selection: CaptureSelection?
    public var quick: QuickSettings
    /// How long the countdown before a take lasts, in seconds: 0, 3, 5 or 10 (`countdownOptions`).
    public var countdownSeconds: Int = 3
    /// The global shortcuts.
    public var hotKeys: HotKeyBindings = .defaults
    /// What a stop does once the take is saved ("When Recording Stops"): open the editor, or stay.
    public var afterStop: AfterStop = .openEditor
    /// The teleprompter: whether it shows, its script and how it reads it.
    public var teleprompter: TeleprompterSettings = .init()

    /// The countdowns the settings offer.
    public static let countdownOptions = [0, 3, 5, 10]

    public init(
        selection: CaptureSelection? = nil, quick: QuickSettings = QuickSettings(), countdownSeconds: Int = 3,
        hotKeys: HotKeyBindings = .defaults, afterStop: AfterStop = .openEditor, teleprompter: TeleprompterSettings = .init()
    ) {
        self.selection = selection
        self.quick = quick
        self.countdownSeconds = countdownSeconds
        self.hotKeys = hotKeys
        self.afterStop = afterStop
        self.teleprompter = teleprompter
    }

    /// A field missing from what was saved (by a version that did not have it), or that this version
    /// cannot read (a selection with a mode from another version), takes its default; the others are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RecorderSettings()
        selection = (try? container.decodeIfPresent(CaptureSelection.self, forKey: .selection)) ?? defaults.selection
        quick = (try? container.decodeIfPresent(QuickSettings.self, forKey: .quick)) ?? defaults.quick
        countdownSeconds = (try? container.decodeIfPresent(Int.self, forKey: .countdownSeconds)) ?? defaults.countdownSeconds
        hotKeys = (try? container.decodeIfPresent(HotKeyBindings.self, forKey: .hotKeys)) ?? defaults.hotKeys
        afterStop = (try? container.decodeIfPresent(AfterStop.self, forKey: .afterStop)) ?? defaults.afterStop
        teleprompter = (try? container.decodeIfPresent(TeleprompterSettings.self, forKey: .teleprompter)) ?? defaults.teleprompter
    }

    /// The countdown to count, in whole seconds: what was saved, kept between 0 and 10.
    public var countdown: Int {
        min(max(countdownSeconds, 0), Self.countdownOptions.max() ?? 0)
    }
}

/// Keeps `RecorderSettings` in `defaults`, as JSON under `key`.
@MainActor
public final class SettingsStore {
    public static let key = "recorderSettings"

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Settings")
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// What was saved last; the defaults when nothing was, or what was saved is not settings at all.
    public var settings: RecorderSettings {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return RecorderSettings() }
            do {
                return try JSONDecoder().decode(RecorderSettings.self, from: data)
            } catch {
                Self.logger.error("Cannot read the saved settings, using the defaults: \(String(describing: error), privacy: .public)")
                return RecorderSettings()
            }
        }
        set {
            do {
                defaults.set(try JSONEncoder().encode(newValue), forKey: Self.key)
            } catch {
                Self.logger.error("Cannot save the settings: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
