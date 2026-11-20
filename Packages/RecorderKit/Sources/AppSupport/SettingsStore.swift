// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Sharing
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
    /// How the camera bubble looks, and how the camera starts in the video: the last one chosen.
    public var cameraStyle: CameraStyle = .default
    /// The areas saved in Area mode ("Save Area").
    public var savedAreas: SavedAreas = .init()
    /// The proportion an area is drawn with: the last one chosen.
    public var aspectLock: AspectLock = .free
    /// The user's shortcut that turns Do Not Disturb on and off around each take (`FocusGuard`), by its Shortcuts
    /// identifier (`ShortcutInfo.identifier`, which a rename does not change); `nil`: none.
    public var focusShortcutIdentifier: String?
    /// Whether the desktop's icons are covered with the wallpaper while recording (`DesktopCoverController` in the app).
    public var hideDesktopIcons: Bool = false
    /// Whether a take notes when keys are typed, never which (`KeyActivityRecorder`), for the zoom while typing.
    public var noteKeyActivity: Bool = true
    /// What the editor's export sheet remembers: the resolution and the quality of the last export.
    public var export: ExportPreferences = .init()
    /// The named style new projects take ("Use for New Projects", 1c design §8), by its id (`NamedStyle.id`, 8 hex
    /// digits); `nil`: Toma's style (plan decision 29). An id no style of the library has any more is Toma's style too.
    public var newProjectsStyleID: String?
    /// The library's window: its frame, view, order and section (design §6.1).
    public var library: LibraryPreferences = .init()
    /// "Record Keys to Show Them" (phase 2 design §7.3): whether a take records which keys go down (`KeyPressRecorder`),
    /// for the keys on screen. Off unless the user turns it on in Settings ▸ Recording, which asks for Input Monitoring;
    /// a take never asks for it, and without it records all the same, without keys (`TakeNotice.keysNotRecorded`).
    public var recordKeys: Bool = false
    /// Where "Share Link" uploads to (phase 5, milestone 5a): the provider, bucket and link options; the secret key lives in the Keychain.
    public var share: SharePreferences = .init()
    /// The instant replay (phase 5, milestone 5c): whether it keeps the last seconds on screen, and how many.
    public var replay: ReplayPreferences = .init()

    /// The countdowns the settings offer.
    public static let countdownOptions = [0, 3, 5, 10]

    public init(
        selection: CaptureSelection? = nil, quick: QuickSettings = QuickSettings(), countdownSeconds: Int = 3,
        hotKeys: HotKeyBindings = .defaults, afterStop: AfterStop = .openEditor, teleprompter: TeleprompterSettings = .init(),
        cameraStyle: CameraStyle = .default, savedAreas: SavedAreas = .init(), aspectLock: AspectLock = .free,
        focusShortcutIdentifier: String? = nil, hideDesktopIcons: Bool = false, noteKeyActivity: Bool = true,
        export: ExportPreferences = .init(), newProjectsStyleID: String? = nil,
        library: LibraryPreferences = .init(), recordKeys: Bool = false,
        share: SharePreferences = .init(), replay: ReplayPreferences = .init()
    ) {
        self.selection = selection
        self.quick = quick
        self.countdownSeconds = countdownSeconds
        self.hotKeys = hotKeys
        self.afterStop = afterStop
        self.teleprompter = teleprompter
        self.cameraStyle = cameraStyle
        self.savedAreas = savedAreas
        self.aspectLock = aspectLock
        self.focusShortcutIdentifier = focusShortcutIdentifier
        self.hideDesktopIcons = hideDesktopIcons
        self.noteKeyActivity = noteKeyActivity
        self.export = export
        self.newProjectsStyleID = newProjectsStyleID
        self.library = library
        self.recordKeys = recordKeys
        self.share = share
        self.replay = replay
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
        cameraStyle = (try? container.decodeIfPresent(CameraStyle.self, forKey: .cameraStyle)) ?? defaults.cameraStyle
        savedAreas = (try? container.decodeIfPresent(SavedAreas.self, forKey: .savedAreas)) ?? defaults.savedAreas
        aspectLock = (try? container.decodeIfPresent(AspectLock.self, forKey: .aspectLock)) ?? defaults.aspectLock
        focusShortcutIdentifier =
            (try? container.decodeIfPresent(String.self, forKey: .focusShortcutIdentifier)) ?? defaults.focusShortcutIdentifier
        hideDesktopIcons = (try? container.decodeIfPresent(Bool.self, forKey: .hideDesktopIcons)) ?? defaults.hideDesktopIcons
        noteKeyActivity = (try? container.decodeIfPresent(Bool.self, forKey: .noteKeyActivity)) ?? defaults.noteKeyActivity
        export = (try? container.decodeIfPresent(ExportPreferences.self, forKey: .export)) ?? defaults.export
        newProjectsStyleID =
            (try? container.decodeIfPresent(String.self, forKey: .newProjectsStyleID)) ?? defaults.newProjectsStyleID
        library = (try? container.decodeIfPresent(LibraryPreferences.self, forKey: .library)) ?? defaults.library
        recordKeys = (try? container.decodeIfPresent(Bool.self, forKey: .recordKeys)) ?? defaults.recordKeys
        share = (try? container.decodeIfPresent(SharePreferences.self, forKey: .share)) ?? defaults.share
        replay = (try? container.decodeIfPresent(ReplayPreferences.self, forKey: .replay)) ?? defaults.replay
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
