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

    func openSettings(for kind: PermissionKind) {
        if kind == .screenRecording { askedForScreenRecording = true }
        NSWorkspace.shared.open(PermissionSettings.url(for: kind))
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
}

/// The permissions window, one at a time.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let model: PermissionsModel
    private let onClose: () -> Void

    init(probe: any PermissionProbe, onClose: @escaping () -> Void) {
        model = PermissionsModel(probe: probe)
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "Permissions")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

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

struct OnboardingView: View {
    let model: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Screen recording permission is required to record. The microphone is optional.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                PermissionRow(kind: kind, state: model.state(of: kind), model: model)
            }
            if model.suggestsReopening {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If screen recording is already allowed in System Settings, macOS applies it after reopening the app.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Quit & Reopen") { model.quitAndReopen() }
                }
            }
            Divider()
            Text("macOS may ask you again every month to allow screen recording. That's normal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// A permission with its state and what to do about it. The microphone and the camera are optional (the camera
/// is also asked for when it is turned on in the island). Accessibility is optional, with a note: its button
/// is the island's "Give Permission…", the prompt the first time and System Settings after (plan decision 27).
private struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let model: PermissionsModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.headline)
                if kind == .accessibility {
                    Text("Optional: only to switch desktops from the notch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                status
            }
            Spacer()
            if let action = PermissionAction(for: state) {
                Button { perform(action) } label: { buttonTitle(action) }
            }
        }
    }

    private func perform(_ action: PermissionAction) {
        switch action {
        case .prompt: Task { await model.request(kind) }
        case .openSettings: model.openSettings(for: kind)
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
        case .screenRecording: "display"
        case .microphone: "mic"
        case .camera: "video"
        case .accessibility: "accessibility"
        }
    }

    private var title: Text {
        switch kind {
        case .screenRecording: Text("Screen Recording")
        case .microphone: Text("Microphone")
        case .camera: Text("Camera")
        case .accessibility: Text("Accessibility")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .granted:
            Label {
                Text("Allowed", comment: "The state of a permission")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)
        case .denied:
            Label {
                Text("Not allowed", comment: "The state of a permission")
            } icon: {
                Image(systemName: "xmark.circle.fill")
            }
            .foregroundStyle(.red)
        case .notDetermined:
            Label {
                Text("Not requested yet", comment: "The state of a permission that was never asked for")
            } icon: {
                Image(systemName: "questionmark.circle")
            }
            .foregroundStyle(.secondary)
        }
    }
}
