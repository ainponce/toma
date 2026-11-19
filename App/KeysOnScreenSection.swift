// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Editing
import ProjectFormat
import SwiftUI

/// The "Keys on Screen" section of the Cursor tab (phase 2 design §7.4): which keys show (none, the shortcuts, or all), where
/// and how big. Each control is one step of `KeyOverlayCommands.set`. A take without key presses says how to record them and
/// leaves the controls disabled; with "No" the position and the size are disabled too.
struct KeysOnScreenSection: View {
    let model: EditorModel

    private var keys: KeyOverlayPlan { model.document?.keys ?? .legacy }

    var body: some View {
        let keys = keys
        let hasKeys = model.hasKeyPresses
        PanelSection("Keys on Screen") {
            Picker("Show Keys", selection: Binding(get: { keys.mode }, set: { set(mode: $0) })) {
                Text("keys.mode.off").tag(KeyOverlayMode.off)
                Text("Shortcuts").tag(KeyOverlayMode.shortcuts)
                Text("keys.mode.all").tag(KeyOverlayMode.all)
            }
            .pickerStyle(.segmented)
            .panelTitled("Show")
            .disabled(!hasKeys)
            Picker("Position", selection: Binding(get: { keys.position }, set: { set(position: $0) })) {
                Text("Bottom Center").tag(KeyOverlayPosition.bottomCenter)
                Text("Bottom Left").tag(KeyOverlayPosition.bottomLeading)
                Text("Bottom Right").tag(KeyOverlayPosition.bottomTrailing)
                Text("Top").tag(KeyOverlayPosition.top)
            }
            .pickerStyle(.menu)
            .disabled(!hasKeys || keys.mode == .off)
            Picker("Size", selection: Binding(get: { keys.size }, set: { set(size: $0) })) {
                Text("keys.size.small").tag(OverlaySize.small)
                Text("keys.size.medium").tag(OverlaySize.medium)
                Text("keys.size.large").tag(OverlaySize.large)
            }
            .pickerStyle(.segmented)
            .panelTitled("Size")
            .disabled(!hasKeys || keys.mode == .off)
            if !hasKeys {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "This recording has no keys. To record them, turn on Settings ▸ Recording ▸ Record Keys to Show Them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Open Recording Settings") { model.openRecordingSettings() }
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func set(mode: KeyOverlayMode? = nil, position: KeyOverlayPosition? = nil, size: OverlaySize? = nil) {
        model.setKeyOverlay(mode: mode, position: position, size: size)
    }
}

extension EditorModel {
    /// One step of `KeyOverlayCommands.set` for the Keys on Screen section.
    func setKeyOverlay(mode: KeyOverlayMode? = nil, position: KeyOverlayPosition? = nil, size: OverlaySize? = nil) {
        guard let document, let step = KeyOverlayCommands.set(document, mode: mode, position: position, size: size) else { return }
        perform(step)
    }

    /// Opens Settings on the Recording pane, where "Record Keys to Show Them" is.
    func openRecordingSettings() {
        (NSApp.delegate as? AppDelegate)?.showRecordingSettings()
    }
}
