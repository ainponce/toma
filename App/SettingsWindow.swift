// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Carbon
import Observation
import SwiftUI
import os

/// The app's settings: the countdown before a take, what a stop does, transcribing a project as it opens, hiding the
/// desktop's icons, noting when keys are typed, recording which keys (with its Input Monitoring permission), the shortcut
/// that turns Do Not Disturb on and the global shortcuts. A Mac settings window: its panes' icons in
/// the toolbar, as tall as the pane shown. Titled like the permissions one, so while it is open (and no take records) the
/// app is in the Dock.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private let model: SettingsModel
    private let tabs: SettingsTabsController

    init(
        store: SettingsStore, hotKeys: HotKeyCenter, countdown: CountdownSetting, afterStop: AfterStopSetting,
        hideDesktopIcons: HideDesktopIconsSetting, focusShortcut: FocusShortcutSetting, appearance: AppearanceSetting,
        probe: any PermissionProbe, onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        model = SettingsModel(
            store: store, hotKeys: hotKeys, countdown: countdown, afterStop: afterStop, hideDesktopIcons: hideDesktopIcons,
            focusShortcut: focusShortcut, appearance: appearance, probe: probe)
        tabs = SettingsTabsController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsPaneView.width, height: 300), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Settings")
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.contentViewController = tabs
        tabs.fitWindow(animated: false)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Shows the Recording pane (where "Record Keys to Show Them" is).
    func showRecordingPane() {
        tabs.selectedTabViewItemIndex = SettingsPane.recording.index
    }

    /// Shows the Share pane (the editor's Share, before it is set up).
    func showSharePane() {
        tabs.selectedTabViewItemIndex = SettingsPane.share.index
    }

    #if DEBUG
    /// `-TomaShowcase settings <general|recording|shortcuts|share>`: the window on that pane. `recording-keys`: the Recording
    /// pane with "Record Keys to Show Them" on and Input Monitoring not allowed, made up (nothing is saved or asked);
    /// `recording-focus`, the same with "Follow Keyboard Focus" and Accessibility.
    func showcase(pane: String) {
        if pane == "recording-keys" {
            model.showcaseRecordKeysNotAllowed()
            tabs.selectedTabViewItemIndex = SettingsPane.recording.index
        }
        if pane == "recording-focus" {
            model.keyboardFocus.showcaseNotAllowed()
            tabs.selectedTabViewItemIndex = SettingsPane.recording.index
        }
        // `share`, `share-new`, `share-problems` or `share-tested`: the Share pane, made up (`SettingsShareModel.showcase`).
        if pane.hasPrefix("share") { tabs.selectedTabViewItemIndex = SettingsPane.share.index }
        if let pane = SettingsPane(rawValue: pane) { tabs.selectedTabViewItemIndex = pane.index }
    }
    #endif

    /// Back from System Settings (or another app), the window is key again: Input Monitoring and Accessibility may have
    /// changed.
    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshInputMonitoring()
        model.keyboardFocus.refresh()
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

/// The settings window's panes, in the toolbar's order.
private enum SettingsPane: String, CaseIterable {
    case general, recording, shortcuts, share, replay

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .general: String(localized: "General", comment: "The settings pane of the app's look and what a stop does")
        case .recording: String(localized: "Recording")
        case .shortcuts: String(localized: "Shortcuts")
        case .share: String(localized: "Share", comment: "The settings pane of where Share Link uploads to")
        case .replay: String(localized: "Replay", comment: "The settings pane of the instant replay")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .shortcuts: "command"
        case .share: "square.and.arrow.up"
        case .replay: "arrow.counterclockwise.circle"
        }
    }
}

/// The panes as the toolbar's tabs. A tab view controller leaves the window's size alone, so the window is fit to the
/// pane shown: when it is chosen (animated, unless "Reduce motion") and when its content grows or shrinks.
@MainActor
private final class SettingsTabsController: NSTabViewController {
    private var panes: [NSHostingController<SettingsPaneView>] = []

    init(model: SettingsModel) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let controller = NSHostingController(rootView: SettingsPaneView(model: model, pane: pane))
            controller.sizingOptions = .preferredContentSize
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
            addTabViewItem(item)
            panes.append(controller)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if tabViewItems.indices.contains(selectedTabViewItemIndex) {
            view.window?.title = tabViewItems[selectedTabViewItemIndex].label
        }
        fitWindow(animated: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        // A settings window is titled with its pane, as the system's are.
        if let label = tabViewItem?.label { view.window?.title = label }
        fitWindow(animated: view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard panes.indices.contains(selectedTabViewItemIndex), viewController === panes[selectedTabViewItemIndex]
        else { return }
        fitWindow(animated: false)
    }

    /// The window as big as the pane shown wants, its top edge where it was.
    func fitWindow(animated: Bool) {
        guard let window = view.window, let content = window.contentView, panes.indices.contains(selectedTabViewItemIndex)
        else { return }
        let size = panes[selectedTabViewItemIndex].sizeThatFits(
            in: CGSize(width: SettingsPaneView.width, height: .greatestFiniteMagnitude))
        let frame = window.frame
        // The title bar and the toolbar.
        let chrome = CGSize(width: frame.width - content.frame.width, height: frame.height - content.frame.height)
        let height = (size.height + chrome.height).rounded(.up)
        let fitted = NSRect(
            x: frame.minX, y: frame.maxY - height, width: SettingsPaneView.width + chrome.width, height: height)
        guard fitted != frame else { return }
        window.setFrame(fitted, display: true, animate: animated)
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
    /// `RecorderSettings.noteKeyActivity`; the take reads the saved value at every start.
    private(set) var noteKeyActivity: Bool
    /// `RecorderSettings.recordKeys`; the take reads the saved value at every start, and records keys only with Input
    /// Monitoring allowed.
    private(set) var recordKeys: Bool
    /// Input Monitoring as macOS says now: read when the window opens, becomes key and after asking.
    private(set) var inputMonitoring: PermissionState
    /// The last shortcut typed for this action was refused.
    private(set) var refusal: (action: HotKeyAction, reason: Refusal)?
    /// "Transcribe Automatically" (`TranscriptionPreferences.automatic`): a project without a transcript transcribes as it
    /// opens in the editor, if its language is installed. Each editor reads the saved value as its project opens.
    private(set) var transcribeAutomatically: Bool

    @ObservationIgnored let hotKeys: HotKeyCenter
    @ObservationIgnored let countdown: CountdownSetting
    @ObservationIgnored let afterStop: AfterStopSetting
    @ObservationIgnored let hideDesktopIcons: HideDesktopIconsSetting
    @ObservationIgnored let focusShortcut: FocusShortcutSetting
    @ObservationIgnored let appearance: AppearanceSetting
    /// "Follow Keyboard Focus", with Accessibility.
    @ObservationIgnored let keyboardFocus: KeyboardFocusSetting
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let transcription: TranscriptionPreferencesStore
    @ObservationIgnored private var probe: any PermissionProbe
    @ObservationIgnored private var monitor: Any?

    init(
        store: SettingsStore, hotKeys: HotKeyCenter, countdown: CountdownSetting, afterStop: AfterStopSetting,
        hideDesktopIcons: HideDesktopIconsSetting, focusShortcut: FocusShortcutSetting, appearance: AppearanceSetting,
        probe: any PermissionProbe
    ) {
        self.store = store
        self.appearance = appearance
        self.hotKeys = hotKeys
        self.countdown = countdown
        self.afterStop = afterStop
        self.hideDesktopIcons = hideDesktopIcons
        self.focusShortcut = focusShortcut
        noteKeyActivity = store.settings.noteKeyActivity
        self.probe = probe
        recordKeys = store.settings.recordKeys
        inputMonitoring = probe.state(of: .inputMonitoring)
        keyboardFocus = KeyboardFocusSetting(store: store, probe: probe)
        let transcription = TranscriptionPreferencesStore()
        self.transcription = transcription
        transcribeAutomatically = transcription.preferences.automatic
    }

    var bindings: HotKeyBindings { hotKeys.bindings }

    func setTranscribeAutomatically(_ isOn: Bool) {
        transcribeAutomatically = isOn
        var preferences = transcription.preferences
        preferences.automatic = isOn
        transcription.preferences = preferences
    }

    func setNoteKeyActivity(_ isOn: Bool) {
        noteKeyActivity = isOn
        var settings = store.settings
        settings.noteKeyActivity = isOn
        store.settings = settings
    }

    /// Saved at once. Turning it on is where Input Monitoring is asked for (a take never asks): the system's prompt, if
    /// it was never asked for (design §7.3, plan decision 20).
    func setRecordKeys(_ isOn: Bool) {
        recordKeys = isOn
        var settings = store.settings
        settings.recordKeys = isOn
        store.settings = settings
        refreshInputMonitoring()
        if isOn, inputMonitoring == .notDetermined { askForInputMonitoring() }
    }

    /// With the keys on and Input Monitoring not allowed: the system's prompt if it was never asked for, System Settings
    /// after that (asked again first, in case macOS forgot Toma; `PermissionSettingsOpener`).
    func allowInputMonitoring() {
        switch PermissionAction(for: inputMonitoring) {
        case nil: break
        case .prompt: askForInputMonitoring()
        case .openSettings:
            Task {
                await PermissionSettingsOpener.live(probe: probe).open(.inputMonitoring)
                refreshInputMonitoring()
            }
        }
    }

    func refreshInputMonitoring() {
        let state = probe.state(of: .inputMonitoring)
        if inputMonitoring != state { inputMonitoring = state }
    }

    private func askForInputMonitoring() {
        Task {
            _ = await probe.request(.inputMonitoring)
            refreshInputMonitoring()
        }
    }

    #if DEBUG
    /// `-TomaShowcase settings recording-keys`: the keys on, and Input Monitoring asked for and not allowed, made up.
    func showcaseRecordKeysNotAllowed() {
        probe = NotAllowedProbe()
        recordKeys = true
        inputMonitoring = .denied
    }

    /// Every permission asked for and not allowed; asking changes nothing.
    private struct NotAllowedProbe: PermissionProbe {
        func state(of kind: PermissionKind) -> PermissionState { .denied }
        func request(_ kind: PermissionKind) async -> PermissionState { .denied }
    }
    #endif

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

/// One pane of the settings window: a grouped form, as wide as every other pane so only the window's height changes.
private struct SettingsPaneView: View {
    static let width: CGFloat = 500

    let model: SettingsModel
    let pane: SettingsPane

    var body: some View {
        Form {
            switch pane {
            case .general: general
            case .recording: recording
            case .shortcuts: shortcuts
            case .share: SettingsSharePane()
            case .replay: SettingsReplayPane()
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var general: some View {
        Section {
            AppearancePicker(setting: model.appearance)
            Picker(selection: Binding(get: { model.afterStop.value }, set: { model.afterStop.set($0) })) {
                ForEach(AfterStop.allCases, id: \.self) { value in
                    AfterStopSetting.label(for: value)
                }
            } label: {
                Text("When Recording Stops")
            }
            Toggle(isOn: Binding(get: { model.transcribeAutomatically }, set: { model.setTranscribeAutomatically($0) })) {
                Text("Transcribe Automatically", comment: "A setting: a project transcribes as it opens in the editor")
                Text(
                    "When a project opens in the editor, if its language is installed.",
                    comment: "Under the setting that transcribes a project as it opens in the editor")
            }
        }
        SettingsCommandLineSection()
    }

    @ViewBuilder
    private var recording: some View {
        Section {
            Picker(selection: Binding(get: { model.countdown.seconds }, set: { model.countdown.set($0) })) {
                ForEach(RecorderSettings.countdownOptions, id: \.self) { seconds in
                    CountdownSetting.label(for: seconds)
                }
            } label: {
                Text("Countdown")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: Binding(get: { model.hideDesktopIcons.isOn }, set: { model.hideDesktopIcons.set($0) })) {
                Text("Hide desktop icons while recording")
            }
            Toggle(isOn: Binding(get: { model.noteKeyActivity }, set: { model.setNoteKeyActivity($0) })) {
                Text("Note When Keys Are Typed (Never Which)", comment: "A setting: a take notes when keys are typed, never which keys")
                Text(
                    "For the zoom while typing. Nothing is noted in password fields.",
                    comment: "Under the setting that notes when keys are typed")
            }
            Toggle(isOn: Binding(get: { model.recordKeys }, set: { model.setRecordKeys($0) })) {
                Text("Record Keys to Show Them", comment: "A setting: a take records which keys are pressed, to show them on screen")
                Text(
                    "Needs Input Monitoring permission. Nothing is recorded where an app turns on secure input, as password fields do; a field of an app that doesn't is recorded like any other.",
                    comment: "Under the setting that records which keys are pressed")
            }
            if model.recordKeys, model.inputMonitoring != .granted {
                InputMonitoringRow(model: model)
            }
            KeyboardFocusRows(setting: model.keyboardFocus)
        }
        Section {
            FocusShortcutPicker(setting: model.focusShortcut)
        } footer: {
            SettingsFooter(
                Text(
                    "Before the countdown, Toma runs the shortcut with the text “on”. If it answers “changed”, Toma runs it with “off” when the recording ends. The project's README says how to make it.",
                    comment: "Under the Do Not Disturb shortcut in Settings; “on”, “off” and “changed” stay as they are"))
        }
    }

    @ViewBuilder
    private var shortcuts: some View {
        Section {
            ForEach(HotKeyAction.allCases, id: \.self) { action in
                ShortcutRow(model: model, action: action)
            }
        } footer: {
            SettingsFooter(
                Text(
                    "Click a shortcut and type the new one. Esc cancels, ⌫ removes it.",
                    comment: "Under the shortcuts in Settings"))
        }
        // The keys typed next would go to a pane that is not shown.
        .onDisappear { model.stopRecordingShortcut() }
    }
}

/// Under "Record Keys to Show Them" while Input Monitoring is not allowed: the takes record no keys until it is. The
/// permissions window's words: its name, its state, and Allow… the first time or System Settings after.
private struct InputMonitoringRow: View {
    let model: SettingsModel

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if model.inputMonitoring == .denied {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                }
                Button { model.allowInputMonitoring() } label: {
                    if PermissionAction(for: model.inputMonitoring) == .prompt {
                        Text("Allow…")
                    } else {
                        Text("Open System Settings")
                    }
                }
            }
        } label: {
            Text("Input Monitoring")
            if model.inputMonitoring == .denied {
                Text("Not allowed", comment: "The state of a permission")
            } else {
                Text("Not requested yet", comment: "The state of a permission that was never asked for")
            }
        }
    }
}

/// The text under a section, lined up with the rows' text above it as the system's settings set theirs.
private struct SettingsFooter: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Dark, Match System or Light, each drawn as a small window of that look, as the system's settings draw theirs.
private struct AppearancePicker: View {
    let setting: AppearanceSetting

    var body: some View {
        // Its name centered on the tiles, which a labeled row would top-align.
        HStack {
            Text("Appearance")
            Spacer()
            HStack(spacing: 4) {
                ForEach(AppAppearance.allCases, id: \.self) { value in
                    AppearanceChoice(value: value, isSelected: setting.value == value) { setting.set(value) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Appearance"))
    }
}

/// One look: its small window, its name under it, a ring in the accent color once chosen.
private struct AppearanceChoice: View {
    let value: AppAppearance
    let isSelected: Bool
    let choose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                AppearanceThumbnail(value: value)
                    .frame(width: 68, height: 44)
                    .padding(2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator.opacity(isHovered ? 1 : 0)),
                                lineWidth: isSelected ? 2.5 : 1)
                    }
                AppearanceSetting.label(for: value)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // Every choice as wide, whatever its name's length.
            .frame(width: 100)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackStyle())
        .onHover { isHovered = $0 }
        .animation(.spring(response: Motion.hover.response, dampingFraction: Motion.hover.damping), value: isHovered)
        .accessibilityLabel(AppearanceSetting.label(for: value))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small window of `value`'s look: a title bar, a sidebar, lines of text and a control in the accent color. Match
/// System is half light, half dark.
private struct AppearanceThumbnail: View {
    let value: AppAppearance

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Group {
            switch value {
            case .dark: window(dark: true)
            case .light: window(dark: false)
            case .system:
                ZStack {
                    window(dark: false)
                    window(dark: true).mask(alignment: .trailing) {
                        GeometryReader { proxy in
                            Rectangle().frame(width: proxy.size.width / 2).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }

    /// Fixed colors on purpose: each draws a look, whatever the app's is now.
    private func window(dark: Bool) -> some View {
        let background = dark ? Color(white: 0.16) : Color(white: 0.97)
        let sidebar = dark ? Color(white: 0.23) : Color(white: 0.88)
        let line = dark ? Color(white: 0.38) : Color(white: 0.78)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(line).frame(width: 3, height: 3) }
                }
                .padding(.bottom, 2)
                Capsule().fill(Color.accentColor).frame(width: 14, height: 3)
                Capsule().fill(line).frame(width: 11, height: 3)
                Capsule().fill(line).frame(width: 13, height: 3)
                Spacer(minLength: 0)
            }
            .padding(5)
            .frame(width: 24)
            .frame(maxHeight: .infinity)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(line).frame(width: 26, height: 3)
                Capsule().fill(line).frame(width: 20, height: 3)
                Spacer(minLength: 0)
                Capsule().fill(Color.accentColor).frame(width: 14, height: 5)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(background)
    }
}

/// A press that answers at once: the control dims while the mouse is down on it.
private struct PressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
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
            ShortcutField(model: model, action: action, isWarned: message != nil)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                title
                if let message {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        message
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
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

/// A shortcut as a field of its own, every one as wide: its keys, "Type Shortcut" in the accent color while it waits
/// for them, or "No Shortcut"; the button that removes it inside, at its trailing end. Outlined in orange while the
/// row warns.
private struct ShortcutField: View {
    static let width: CGFloat = 160

    let model: SettingsModel
    let action: HotKeyAction
    let isWarned: Bool
    @State private var isHovered = false

    var body: some View {
        let isRecording = model.recording == action
        let combo = model.bindings.combos[action]
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button { model.startRecordingShortcut(for: action) } label: {
            Group {
                if isRecording {
                    Text("Type Shortcut").foregroundStyle(.tint)
                } else if let combo {
                    Text(verbatim: combo.shownString).fontWeight(.medium)
                } else {
                    Text("No Shortcut").foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            // Room for the remove button on both sides, so the keys stay centered.
            .padding(.horizontal, 24)
            .frame(width: Self.width, height: 26)
            .contentShape(shape)
        }
        .buttonStyle(PressFeedbackStyle())
        .background {
            shape.fill(
                isRecording
                    ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                    : isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary))
        }
        .overlay {
            shape.strokeBorder(
                isRecording
                    ? AnyShapeStyle(.tint)
                    : isWarned ? AnyShapeStyle(Color.orange.opacity(0.8)) : AnyShapeStyle(.separator),
                lineWidth: isRecording ? 1.5 : 1)
        }
        .overlay(alignment: .trailing) {
            if combo != nil {
                Button { model.clear(action) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressFeedbackStyle())
                .padding(.trailing, 3)
                .help(Text("Remove Shortcut"))
                .accessibilityLabel(Text("Remove Shortcut"))
            }
        }
        .onHover { isHovered = $0 }
        .animation(.spring(response: Motion.hover.response, dampingFraction: Motion.hover.damping), value: isHovered)
    }
}
