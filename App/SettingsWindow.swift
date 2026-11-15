// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Carbon
import Observation
import SwiftUI
import os

/// The app's settings: the countdown before a take, what a stop does, hiding the desktop's icons, the shortcut that
/// turns Do Not Disturb on and the global shortcuts. A titled window like the permissions one, so while it is open
/// (and no take records) the app is in the Dock.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private let model: SettingsModel

    init(
        store: SettingsStore, hotKeys: HotKeyCenter, countdown: CountdownSetting, afterStop: AfterStopSetting,
        hideDesktopIcons: HideDesktopIconsSetting, focusShortcut: FocusShortcutSetting, onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        model = SettingsModel(
            store: store, hotKeys: hotKeys, countdown: countdown, afterStop: afterStop, hideDesktopIcons: hideDesktopIcons,
            focusShortcut: focusShortcut)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 330), styleMask: [.titled, .closable], backing: .buffered,
            defer: false)
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Typing a shortcut ends when the window is left: the keys go elsewhere.
    func windowDidResignKey(_ notification: Notification) {
        model.stopRecordingShortcut()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecordingShortcut()
        // On the next turn: the window is still closing, and dropping this controller releases it.
        Task { self.onClose() }
    }
}

/// How long the countdown before a take lasts: the one place it is read and saved for the settings window
/// and the island's settings card, which both show it as it is now. The controller reads the saved value
/// at every start.
@MainActor @Observable
final class CountdownSetting {
    private(set) var seconds: Int

    @ObservationIgnored private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
        seconds = store.settings.countdown
    }

    func set(_ seconds: Int) {
        self.seconds = seconds
        var settings = store.settings
        settings.countdownSeconds = seconds
        store.settings = settings
    }

    /// `RecorderSettings.countdownOptions`, as the settings name them: None, 3 s, 5 s, 10 s.
    static func label(for seconds: Int) -> Text {
        seconds == 0 ? Text("None", comment: "System audio: record none; the countdown: none") : Text(verbatim: "\(seconds.formatted()) s")
    }
}

/// What a stop does once the take is saved ("When Recording Stops"): the one place it is read and saved
/// for the settings window and the island's settings card, which both show it as it is now. The controller
/// reads the saved value at every stop.
@MainActor @Observable
final class AfterStopSetting {
    private(set) var value: AfterStop

    @ObservationIgnored private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
        value = store.settings.afterStop
    }

    func set(_ value: AfterStop) {
        self.value = value
        var settings = store.settings
        settings.afterStop = value
        store.settings = settings
    }

    /// How the settings name each choice.
    static func label(for value: AfterStop) -> Text {
        switch value {
        case .openEditor: Text("Open the Editor")
        case .stayHere: Text("Stay Where I Am")
        }
    }
}

/// Whether the desktop's icons are hidden while recording (`RecorderSettings.hideDesktopIcons`): the one place it is
/// read and saved for the settings window and the island's settings card, which both show it as it is now. The take's
/// hooks read the saved value at every start.
@MainActor @Observable
final class HideDesktopIconsSetting {
    private(set) var isOn: Bool

    @ObservationIgnored private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
        isOn = store.settings.hideDesktopIcons
    }

    func set(_ isOn: Bool) {
        self.isOn = isOn
        var settings = store.settings
        settings.hideDesktopIcons = isOn
        store.settings = settings
    }
}

/// The shortcut of the user's that turns Do Not Disturb on around each take (`RecorderSettings.focusShortcutIdentifier`):
/// the one place it is read and saved for the settings window and the island's settings card, which both show it as it
/// is now, with the user's shortcuts to choose it from (`ShortcutsCLI.list()`). The take's hooks read the saved value at
/// every start.
@MainActor @Observable
final class FocusShortcutSetting {
    private(set) var identifier: String?
    /// The user's shortcuts as Shortcuts last listed them; `nil` until it has (none if it could not).
    private(set) var shortcuts: [ShortcutInfo]?

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let runner: any ShortcutRunning
    @ObservationIgnored private var listing: Task<Void, Never>?

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Focus")

    init(store: SettingsStore, runner: any ShortcutRunning) {
        self.store = store
        self.runner = runner
        identifier = store.settings.focusShortcutIdentifier
    }

    /// `nil`: no shortcut, Do Not Disturb is left as it is.
    func set(_ identifier: String?) {
        self.identifier = identifier
        var settings = store.settings
        settings.focusShortcutIdentifier = identifier
        store.settings = settings
    }

    /// Lists the user's shortcuts again, unless they are being listed: a shortcut made meanwhile shows.
    func refreshShortcuts() {
        guard listing == nil else { return }
        listing = Task {
            do {
                shortcuts = try await runner.list()
            } catch {
                Self.logger.error("Cannot list the shortcuts: \(String(describing: error), privacy: .public)")
                shortcuts = []
            }
            listing = nil
        }
    }

    /// The chosen shortcut is among the ones listed: it may have been deleted since it was chosen.
    var isChosenListed: Bool {
        guard let identifier, let shortcuts else { return false }
        return shortcuts.contains { $0.identifier == identifier }
    }
}

/// What the settings window shows and changes; every change is saved at once.
@MainActor @Observable
final class SettingsModel {
    /// Why a shortcut just typed was not taken.
    enum Refusal: Equatable {
        case needsCommandOrControl
        case taken
    }

    /// The action whose shortcut is being typed.
    private(set) var recording: HotKeyAction?
    /// The last shortcut typed for this action was refused.
    private(set) var refusal: (action: HotKeyAction, reason: Refusal)?

    @ObservationIgnored let hotKeys: HotKeyCenter
    @ObservationIgnored let countdown: CountdownSetting
    @ObservationIgnored let afterStop: AfterStopSetting
    @ObservationIgnored let hideDesktopIcons: HideDesktopIconsSetting
    @ObservationIgnored let focusShortcut: FocusShortcutSetting
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var monitor: Any?

    init(
        store: SettingsStore, hotKeys: HotKeyCenter, countdown: CountdownSetting, afterStop: AfterStopSetting,
        hideDesktopIcons: HideDesktopIconsSetting, focusShortcut: FocusShortcutSetting
    ) {
        self.store = store
        self.hotKeys = hotKeys
        self.countdown = countdown
        self.afterStop = afterStop
        self.hideDesktopIcons = hideDesktopIcons
        self.focusShortcut = focusShortcut
    }

    var bindings: HotKeyBindings { hotKeys.bindings }

    /// The next key press with modifiers is `action`'s shortcut: Esc gives up, Delete leaves it without one.
    func startRecordingShortcut(for action: HotKeyAction) {
        stopRecordingShortcut()
        recording = action
        refusal = nil
        hotKeys.suspend(true)
        // A local monitor: only the keys this window gets.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return typed(event)
        }
    }

    func stopRecordingShortcut() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        hotKeys.suspend(false)
    }

    func clear(_ action: HotKeyAction) {
        refusal = nil
        save(nil, for: action)
    }

    private func typed(_ event: NSEvent) -> NSEvent? {
        guard let action = recording else { return event }
        let combo = KeyCombo(event: event)
        switch Int(event.keyCode) {
        case kVK_Escape where combo.modifiers.isEmpty:
            stopRecordingShortcut()
            return nil
        case kVK_Delete where combo.modifiers.isEmpty, kVK_ForwardDelete where combo.modifiers.isEmpty:
            stopRecordingShortcut()
            clear(action)
            return nil
        default:
            break
        }
        guard combo.isAllowedAsGlobalHotKey else {
            refusal = (action, .needsCommandOrControl)
            return nil
        }
        // Checked while Toma's own are taken away, so a shortcut it already has counts as free.
        guard hotKeys.isAvailable(combo) else {
            refusal = (action, .taken)
            return nil
        }
        stopRecordingShortcut()
        refusal = nil
        save(combo, for: action)
        return nil
    }

    /// One shortcut does one thing: given to `action`, it is taken from any other.
    private func save(_ combo: KeyCombo?, for action: HotKeyAction) {
        var bindings = hotKeys.bindings
        if let combo {
            for (other, existing) in bindings.combos where existing == combo && other != action { bindings.combos[other] = nil }
        }
        bindings.combos[action] = combo
        var settings = store.settings
        settings.hotKeys = bindings
        store.settings = settings
        hotKeys.update(bindings: bindings)
    }
}

private struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Picker(selection: Binding(get: { model.countdown.seconds }, set: { model.countdown.set($0) })) {
                ForEach(RecorderSettings.countdownOptions, id: \.self) { seconds in
                    CountdownSetting.label(for: seconds)
                }
            } label: {
                Text("Countdown")
            }
            .pickerStyle(.segmented)
            Picker(selection: Binding(get: { model.afterStop.value }, set: { model.afterStop.set($0) })) {
                ForEach(AfterStop.allCases, id: \.self) { value in
                    AfterStopSetting.label(for: value)
                }
            } label: {
                Text("When Recording Stops")
            }
            Toggle(isOn: Binding(get: { model.hideDesktopIcons.isOn }, set: { model.hideDesktopIcons.set($0) })) {
                Text("Hide desktop icons while recording")
            }
            Section {
                FocusShortcutPicker(setting: model.focusShortcut)
            } footer: {
                Text(
                    "Before the countdown, Toma runs the shortcut with the text “on”. If it answers “changed”, Toma runs it with “off” when the recording ends. The project's README says how to make it.",
                    comment: "Under the Do Not Disturb shortcut in Settings; “on”, “off” and “changed” stay as they are")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    ShortcutRow(model: model, action: action)
                }
            } header: {
                Text("Shortcuts")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The shortcut that turns Do Not Disturb on, among the user's shortcuts (listed again each time it shows), or none.
/// One chosen that Shortcuts no longer lists says so.
private struct FocusShortcutPicker: View {
    let setting: FocusShortcutSetting

    var body: some View {
        Picker(selection: Binding(get: { setting.identifier }, set: { setting.set($0) })) {
            Text("No Shortcut").tag(String?.none)
            ForEach(setting.shortcuts ?? [], id: \.identifier) { shortcut in
                Text(verbatim: shortcut.name).tag(Optional(shortcut.identifier))
            }
            if let identifier = setting.identifier, !setting.isChosenListed {
                // While they are listed, and once listed if it is not among them.
                (setting.shortcuts == nil ? Text("Loading…") : Text("Shortcut Not Found")).tag(Optional(identifier))
            }
        } label: {
            Text("Turn on Do Not Disturb with a shortcut")
        }
        .onAppear { setting.refreshShortcuts() }
    }
}

/// One action: its name, its shortcut (click it, then type the new one), and why the last one typed was
/// not taken, or that its shortcut does nothing now because another app or macOS uses it.
private struct ShortcutRow: View {
    let model: SettingsModel
    let action: HotKeyAction

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Button { model.startRecordingShortcut(for: action) } label: {
                    Group {
                        if model.recording == action {
                            Text("Type Shortcut")
                        } else if let combo = model.bindings.combos[action] {
                            Text(verbatim: combo.displayString)
                        } else {
                            Text("No Shortcut")
                        }
                    }
                    .frame(minWidth: 110)
                }
                if model.bindings.combos[action] != nil {
                    Button { model.clear(action) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help(Text("Remove Shortcut"))
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                title
                if let message {
                    message.font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var title: Text {
        switch action {
        case .islandOrStop: Text("New Recording or Stop")
        case .pauseResume: Text("Pause or Resume")
        case .marker: Text("Marker")
        case .restartTake: Text("Restart Take")
        }
    }

    private var message: Text? {
        if let refusal = model.refusal, refusal.action == action {
            switch refusal.reason {
            case .needsCommandOrControl: return Text("Shortcuts need ⌘ or ⌃.")
            case .taken: return Text("This shortcut is used by macOS or another app.")
            }
        }
        if model.hotKeys.busy.contains(action) { return Text("This shortcut is used by macOS or another app.") }
        return nil
    }
}
