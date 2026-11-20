// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Observation
import SwiftUI

/// "Follow Keyboard Focus" (`RecorderSettings.recordFocus`, design §5.3), with Accessibility as macOS says now: the
/// takes record where the focused field and the text cursor are only with both. Turning it on is where Accessibility is
/// asked for (a take never asks): the system's prompt if it was never asked for, System Settings after that (plan
/// decision 27). The take reads the saved value at every start.
@MainActor @Observable
final class KeyboardFocusSetting {
    private(set) var isOn: Bool
    /// Read when the settings window opens, becomes key and after asking.
    private(set) var accessibility: PermissionState

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var probe: any PermissionProbe

    init(store: SettingsStore, probe: any PermissionProbe) {
        self.store = store
        self.probe = probe
        isOn = store.settings.recordFocus
        accessibility = probe.state(of: .accessibility)
    }

    /// Saved at once; turned on with Accessibility never asked for, the system's prompt.
    func set(_ isOn: Bool) {
        self.isOn = isOn
        var settings = store.settings
        settings.recordFocus = isOn
        store.settings = settings
        refresh()
        if isOn, accessibility == .notDetermined { ask() }
    }

    /// On and Accessibility not allowed: the system's prompt if it was never asked for, System Settings after that
    /// (asked again first, in case macOS forgot Toma; `PermissionSettingsOpener`).
    func allow() {
        switch PermissionAction(for: accessibility) {
        case nil: break
        case .prompt: ask()
        case .openSettings:
            Task {
                await PermissionSettingsOpener.live(probe: probe).open(.accessibility)
                refresh()
            }
        }
    }

    func refresh() {
        let state = probe.state(of: .accessibility)
        if accessibility != state { accessibility = state }
    }

    private func ask() {
        Task {
            _ = await probe.request(.accessibility)
            refresh()
        }
    }

    #if DEBUG
    /// `-TomaShowcase settings recording-focus`: on, and Accessibility asked for and not allowed, made up (nothing is
    /// saved or asked).
    func showcaseNotAllowed() {
        probe = NotAllowedProbe()
        isOn = true
        accessibility = .denied
    }

    /// Every permission asked for and not allowed; asking changes nothing.
    private struct NotAllowedProbe: PermissionProbe {
        func state(of kind: PermissionKind) -> PermissionState { .denied }
        func request(_ kind: PermissionKind) async -> PermissionState { .denied }
    }
    #endif
}

/// Settings ▸ Recording's "Follow Keyboard Focus" with what it is for, and under it, while Accessibility is not allowed,
/// the permission's row (the takes record no focus until it is): the permissions window's words, its name, its state,
/// and Allow… the first time or System Settings after.
struct KeyboardFocusRows: View {
    let setting: KeyboardFocusSetting

    var body: some View {
        Toggle(isOn: Binding(get: { setting.isOn }, set: { setting.set($0) })) {
            Text("Follow Keyboard Focus", comment: "A setting: a take records where the focused field and the text cursor are")
            Text(
                "For the zoom that follows what's typed. Needs Accessibility permission. Only where the focused field and the text cursor are is recorded, never what they say; in password fields, only the field.",
                comment: "Under the setting that records where the keyboard focus is")
        }
        if setting.isOn, setting.accessibility != .granted {
            LabeledContent {
                HStack(spacing: 8) {
                    if setting.accessibility == .denied {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                    }
                    Button { setting.allow() } label: {
                        if PermissionAction(for: setting.accessibility) == .prompt {
                            Text("Allow…")
                        } else {
                            Text("Open System Settings")
                        }
                    }
                }
            } label: {
                Text("Accessibility")
                if setting.accessibility == .denied {
                    Text("Not allowed", comment: "The state of a permission")
                } else {
                    Text("Not requested yet", comment: "The state of a permission that was never asked for")
                }
            }
        }
    }
}
