// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import AppSupport
import Observation
import SwiftUI
import os

/// The state of each permission, read again whenever the app becomes active (for example, back from
/// System Settings).
@MainActor @Observable
final class PermissionsModel {
    private(set) var states: [PermissionKind: PermissionState] = [:]
    /// Screen recording was asked for or its settings opened, and it is still not granted on coming back:
    /// macOS may only apply it once the app is opened again.
    private(set) var suggestsReopening = false

    @ObservationIgnored private let probe: any PermissionProbe
    @ObservationIgnored private var askedForScreenRecording = false
    @ObservationIgnored private var activation: (any NSObjectProtocol)?

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Permissions")

    init(probe: any PermissionProbe) {
        self.probe = probe
        refresh()
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
    }

    /// Whether to show the permissions at launch: screen recording is not granted, or a microphone the
    /// Mac has was never asked for.
    static func needsAttention(probe: any PermissionProbe) -> Bool {
        let hasMicrophone = AVCaptureDevice.default(for: .audio) != nil
        let preflight = RecordingPreflight.evaluate(
            probe: probe, wanted: hasMicrophone ? [.screenRecording, .microphone] : [.screenRecording])
        return !preflight.canRecord || (hasMicrophone && probe.state(of: .microphone) == .notDetermined)
    }

    func state(of kind: PermissionKind) -> PermissionState {
        states[kind] ?? .notDetermined
    }

    func request(_ kind: PermissionKind) async {
        if kind == .screenRecording { askedForScreenRecording = true }
        _ = await probe.request(kind)
        refresh()
    }

    /// Asks again first when macOS may have forgotten Toma, so it is back in the list (`PermissionSettingsOpener`).
    func openSettings(for kind: PermissionKind) async {
        if kind == .screenRecording { askedForScreenRecording = true }
        await PermissionSettingsOpener.live(probe: probe).open(kind)
        refresh()
    }

    /// Opens a new instance of the app and quits this one.
    func quitAndReopen() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    Self.logger.error("Cannot reopen the app: \(String(describing: error), privacy: .public)")
                    NSAlert(error: error).runModal()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Stops following activation; called when the window closes.
    func stopObserving() {
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
    }

    private func becameActive() {
        refresh()
        if askedForScreenRecording, state(of: .screenRecording) != .granted { suggestsReopening = true }
    }

    private func refresh() {
        for kind in PermissionKind.allCases {
            let state = probe.state(of: kind)
            if states[kind] != state { states[kind] = state }
        }
        if state(of: .screenRecording) == .granted { suggestsReopening = false }
    }

    #if DEBUG
    /// `-TomaShowcase onboarding mixed`: the notice to quit and reopen, without asking first.
    func showcaseSuggestsReopening() {
        suggestsReopening = true
    }
    #endif
}

/// The permissions window, one at a time: the app's welcome, with its content under a transparent title bar.
/// `openSettings` opens the settings window, where the Do Not Disturb shortcut is chosen.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let model: PermissionsModel
    private let onClose: () -> Void

    init(probe: any PermissionProbe, openSettings: @escaping () -> Void, onClose: @escaping () -> Void) {
        model = PermissionsModel(probe: probe)
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OnboardingView.width, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        // The title stays for the Window menu and VoiceOver; the welcome's own header names the app.
        window.title = String(localized: "Permissions")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(model: model, openSettings: openSettings))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    #if DEBUG
    /// `-TomaShowcase onboarding <new|mixed|done>`: the window over made-up permissions, to look at its states.
    convenience init(showcase: String) {
        self.init(probe: ShowcasePermissionProbe(preset: showcase), openSettings: {}, onClose: {})
        if showcase == "mixed" { model.showcaseSuggestsReopening() }
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        model.stopObserving()
        // On the next turn: the window is still closing, and dropping this controller releases it.
        Task { self.onClose() }
    }
}

#if DEBUG
/// Permissions that are made up, for `OnboardingWindowController(showcase:)`: asking changes nothing.
private struct ShowcasePermissionProbe: PermissionProbe {
    let states: [PermissionKind: PermissionState]

    init(preset: String) {
        switch preset {
        case "mixed":
            states = [.screenRecording: .denied, .microphone: .granted, .camera: .denied, .systemAudio: .granted]
        case "done":
            states = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .granted) })
        default:
            states = [:]
        }
    }

    func state(of kind: PermissionKind) -> PermissionState {
        states[kind] ?? .notDetermined
    }

    func request(_ kind: PermissionKind) async -> PermissionState {
        state(of: kind)
    }
}
#endif

/// The welcome: the app's icon and name, screen recording (the one permission a take needs) on its own with a
/// prominent action, and the optional ones grouped under it, quieter.
struct OnboardingView: View {
    static let width: CGFloat = 560

    let model: PermissionsModel
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 24) {
                PermissionCard {
                    PermissionRow(kind: .screenRecording, state: model.state(of: .screenRecording), model: model)
                    if model.suggestsReopening { ReopenNotice(model: model) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Optional", comment: "The header of the permissions a take can do without")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, PermissionLayout.inset)
                        .accessibilityAddTraits(.isHeader)
                    PermissionCard {
                        ForEach(PermissionKind.allCases.filter { $0 != .screenRecording }, id: \.self) { kind in
                            PermissionRow(kind: kind, state: model.state(of: kind), model: model)
                            RowSeparator()
                        }
                        FocusShortcutRow(openSettings: openSettings)
                    }
                }
            }
            Text("macOS may ask you again every month to allow screen recording. That's normal.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
        }
        .padding(.horizontal, 32)
        // Under the title bar's height, which the content runs beneath.
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: Self.width)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text(verbatim: AppIdentity.name)
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Toma needs permission to record the screen. Everything else is optional.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The welcome's measures, shared by its cards and rows.
private enum PermissionLayout {
    /// From a card's edge to a row's icon.
    static let inset: CGFloat = 12
    /// Between a row's icon, its text and its trailing edge.
    static let spacing: CGFloat = 12
}

/// A group of rows on a rounded card, as System Settings draws them.
private struct PermissionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(.quinary, in: shape)
        // A notice inside it is tinted to its corners.
        .clipShape(shape)
        .overlay { shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
    }
}

/// Between two rows of a card, from where their text starts, as System Settings does.
private struct RowSeparator: View {
    var prominent = false

    var body: some View {
        Divider()
            .padding(
                .leading, PermissionLayout.inset + PermissionIcon.size(prominent: prominent) + PermissionLayout.spacing)
            .padding(.trailing, PermissionLayout.inset)
    }
}

/// A permission's symbol on a tinted rounded square, as in System Settings.
private struct PermissionIcon: View {
    let symbol: String
    let tint: Color
    var prominent = false

    static func size(prominent: Bool) -> CGFloat { prominent ? 36 : 28 }

    var body: some View {
        let size = Self.size(prominent: prominent)
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row's title and description, and at its trailing edge its state or its action.
private struct PermissionRowLayout<Trailing: View>: View {
    let symbol: String
    let tint: Color
    var prominent = false
    let title: Text
    let description: Text
    /// What VoiceOver reads after the title and description: the state, which only shows as a pill or a symbol.
    var accessibilityState: Text?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: PermissionLayout.spacing) {
            PermissionIcon(symbol: symbol, tint: tint, prominent: prominent)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(prominent ? .headline : .body)
                description
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(accessibilityState ?? Text(verbatim: ""))
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, PermissionLayout.inset)
        .padding(.vertical, prominent ? 14 : 10)
    }
}

/// Do Not Disturb, optional and not a permission: a shortcut of the user's turns it on around each take, chosen in
/// Settings ("Turn on Do Not Disturb with a shortcut").
private struct FocusShortcutRow: View {
    let openSettings: () -> Void

    var body: some View {
        PermissionRowLayout(
            symbol: "moon.fill", tint: .indigo, title: Text("Do Not Disturb"),
            description: Text(
                "A shortcut you make in Shortcuts turns it on while recording, so notifications don't sound. They never appear in the video.",
                comment: "Under Do Not Disturb in the permissions window")
        ) {
            Button { openSettings() } label: { Text("Settings…") }
        }
    }
}

/// A permission with its state and what to do about it. The microphone and the camera are optional (the camera
/// is also asked for when it is turned on in the island). System audio is optional, and macOS never says whether
/// it was allowed: once asked for it reads "Requested", with a note on where to change it. Accessibility is
/// optional, with a note: its button is the island's "Give Permission…", the prompt the first time and System
/// Settings after (plan decision 27).
private struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let model: PermissionsModel

    var body: some View {
        PermissionRowLayout(
            symbol: symbol, tint: tint, prominent: kind == .screenRecording, title: title, description: description,
            accessibilityState: stateText
        ) {
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let action = PermissionAction(for: state) {
            HStack(spacing: 8) {
                if state == .denied {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .help(stateText)
                        .accessibilityHidden(true)
                }
                if kind == .screenRecording {
                    Button { perform(action) } label: { buttonTitle(action) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button { perform(action) } label: { buttonTitle(action) }
                }
            }
        } else if kind == .systemAudio {
            // "Allowed" would claim more than macOS says: only that it was asked for.
            StatePill(title: stateText, symbol: "checkmark", tint: .secondary)
        } else {
            StatePill(title: stateText, symbol: "checkmark", tint: .green)
        }
    }

    private func perform(_ action: PermissionAction) {
        switch action {
        case .prompt: Task { await model.request(kind) }
        case .openSettings: Task { await model.openSettings(for: kind) }
        }
    }

    private func buttonTitle(_ action: PermissionAction) -> Text {
        switch (kind, action) {
        case (.accessibility, _): Text("Give Permission…")
        case (_, .prompt): Text("Allow…")
        case (_, .openSettings): Text("Open System Settings")
        }
    }

    private var symbol: String {
        switch kind {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .microphone: "mic.fill"
        case .camera: "video.fill"
        case .systemAudio: "speaker.wave.2.fill"
        case .accessibility: "accessibility"
        }
    }

    private var tint: Color {
        switch kind {
        case .screenRecording: .accentColor
        case .microphone: .orange
        case .camera: .green
        case .systemAudio: .pink
        case .accessibility: .blue
        }
    }

    private var title: Text {
        switch kind {
        case .screenRecording: Text("Screen Recording")
        case .microphone: Text("Microphone")
        case .camera: Text("Camera")
        case .systemAudio: Text("System Audio")
        case .accessibility: Text("Accessibility")
        }
    }

    private var description: Text {
        switch kind {
        case .screenRecording:
            Text(
                "Required to record the screen or a window.", comment: "Under screen recording in the permissions window")
        case .microphone:
            Text(
                "To record your voice, on a track of its own.", comment: "Under the microphone in the permissions window")
        case .camera:
            Text("For the camera bubble over the recording.", comment: "Under the camera in the permissions window")
        case .systemAudio where state == .granted:
            Text(
                "If you denied it, the system audio track will be silent. You can change it in System Settings → Privacy & Security → Screen & System Audio Recording.",
                comment: "Under the system audio permission once it was asked for: macOS doesn't say whether it was allowed")
        case .systemAudio:
            Text(
                "The sound of the apps, on a track of its own.", comment: "Under system audio in the permissions window")
        case .accessibility:
            Text("Only to switch desktops from the notch.", comment: "Under Accessibility in the permissions window")
        }
    }

    private var stateText: Text {
        switch state {
        case .granted where kind == .systemAudio:
            Text("Requested", comment: "The state of the system audio permission once it was asked for")
        case .granted: Text("Allowed", comment: "The state of a permission")
        case .denied: Text("Not allowed", comment: "The state of a permission")
        case .notDetermined: Text("Not requested yet", comment: "The state of a permission that was never asked for")
        }
    }
}

/// A permission's state at a row's trailing edge: a symbol and a word on a capsule of its tint.
private struct StatePill<Tint: ShapeStyle>: View {
    let title: Text
    let symbol: String
    let tint: Tint

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
            title
                .font(.callout.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
        // The row's text already reads the state.
        .accessibilityHidden(true)
    }
}

/// Screen recording was asked for and is still not granted on coming back: macOS may only apply it once the app is
/// opened again. Inside the screen recording card, under its row.
private struct ReopenNotice: View {
    let model: PermissionsModel

    var body: some View {
        HStack(spacing: PermissionLayout.spacing) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: PermissionIcon.size(prominent: true))
                .accessibilityHidden(true)
            Text("If screen recording is already allowed in System Settings, macOS applies it after reopening the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Quit & Reopen") { model.quitAndReopen() }
        }
        .padding(.horizontal, PermissionLayout.inset)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.1))
    }
}
