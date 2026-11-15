// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Recording
import SwiftUI

extension OpenPanelModel {
    /// 30 and 60 frames a second, for the window and the camera.
    static let framesPerSecondOptions = [30, 60]

    /// 30, and 60 when the display reaches it.
    func framesPerSecondOptions(for display: DisplayChoice) -> [Int] {
        display.info.maximumFramesPerSecond >= 60 ? [30, 60] : [30]
    }

    /// The frame rate the display records at, among the ones it offers.
    func framesPerSecond(for display: DisplayChoice) -> Int {
        let chosen = quick.framesPerSecond(display: display.id)
        let options = framesPerSecondOptions(for: display)
        return options.contains(chosen) ? chosen : options[0]
    }

    func setFramesPerSecond(_ value: Int, for display: DisplayChoice) {
        quick.framesPerSecondByDisplay[display.id] = value
    }

    /// One of `framesPerSecondOptions`: what was saved if it is one, otherwise 30.
    static func offered(_ framesPerSecond: Int) -> Int {
        framesPerSecondOptions.contains(framesPerSecond) ? framesPerSecond : framesPerSecondOptions[0]
    }
}

/// The settings card (notch design §5.2): on the left, what the take records at — the frame rate of each display
/// it records (or of the window), one resolution for all, and the camera's quality and frame rate while it is on;
/// on the right, the countdown, what a stop does, Do Not Disturb and what is coming; at the bottom the encoder's load,
/// with what would lighten it.
struct SettingsCard: View {
    @Bindable var panel: OpenPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                capture.frame(width: 262, alignment: .topLeading)
                Divider().overlay(Color.white.opacity(0.12))
                takeSettings.frame(width: 250, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Color.white.opacity(0.12))
            LoadSettingsSection(panel: panel, verdict: panel.load)
        }
        .font(.system(size: 12.5))
        .padding(12)
        .frame(width: 560, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(white: 0.1).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.16)))
        }
        // Clicks on the card stay on it.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    @ViewBuilder
    private var capture: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(panel.recordedDisplays) { display in
                SettingsRow(title: Text(verbatim: display.name)) {
                    GlassSegmented(
                        items: panel.framesPerSecondOptions(for: display).map { .init(value: $0, title: Self.rate($0)) },
                        selection: Binding(
                            get: { panel.framesPerSecond(for: display) },
                            set: { panel.setFramesPerSecond($0, for: display) }),
                        compact: true)
                }
            }
            if panel.selection.mode == .window {
                SettingsRow(title: Text("Window", comment: "What to record: one window")) {
                    GlassSegmented(
                        items: OpenPanelModel.framesPerSecondOptions.map { .init(value: $0, title: Self.rate($0)) },
                        selection: Binding(
                            get: { OpenPanelModel.offered(panel.quick.windowFramesPerSecond) },
                            set: { panel.quick.windowFramesPerSecond = $0 }),
                        compact: true)
                }
            }
            // Native or Points, for the displays and the window alike.
            HStack {
                Spacer(minLength: 0)
                GlassSegmented(
                    items: [
                        .init(value: CaptureScale.native, title: Text("Native", comment: "Display resolution: the display's own pixels")),
                        .init(value: CaptureScale.points, title: Text("Points", comment: "Display resolution: one pixel per point")),
                    ],
                    selection: $panel.quick.displayScale,
                    compact: true)
            }
            if panel.isCameraOn {
                SettingsRow(title: Text("Camera")) {
                    GlassSegmented(
                        items: CameraPreset.allCases.map { .init(value: $0, title: Text(verbatim: $0.label)) },
                        selection: $panel.quick.cameraPreset,
                        compact: true)
                }
                HStack {
                    Spacer(minLength: 0)
                    GlassSegmented(
                        items: OpenPanelModel.framesPerSecondOptions.map { .init(value: $0, title: Self.rate($0)) },
                        selection: Binding(
                            get: { OpenPanelModel.offered(panel.quick.cameraFramesPerSecond) },
                            set: { panel.quick.cameraFramesPerSecond = $0 }),
                        compact: true)
                }
            }
        }
    }

    @ViewBuilder
    private var takeSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(title: Text("Countdown")) {
                GlassSegmented(
                    items: RecorderSettings.countdownOptions.map { .init(value: $0, title: CountdownSetting.label(for: $0)) },
                    selection: Binding(get: { panel.countdown.seconds }, set: { panel.countdown.set($0) }),
                    compact: true)
            }
            SettingsRow(title: Text("When Recording Stops")) {
                // A menu, as the microphone's: it opens without activating the app.
                Picker(selection: Binding(get: { panel.afterStop.value }, set: { panel.afterStop.set($0) })) {
                    ForEach(AfterStop.allCases, id: \.self) { value in
                        AfterStopSetting.label(for: value).tag(value)
                    }
                } label: {
                    Text("When Recording Stops")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            FocusShortcutToggle(setting: panel.focusShortcut)
            SettingsToggle(title: Text("Hide Desktop Icons"), icon: "eye.slash").upcoming(.hideDesktopIcons)
        }
    }

    private static func rate(_ framesPerSecond: Int) -> Text {
        Text(verbatim: "\(framesPerSecond) fps")
    }
}

/// A setting's name on the left, its control on the right.
private struct SettingsRow<Control: View>: View {
    let title: Text
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 8) {
            title.opacity(0.75).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            control
        }
    }
}

/// Do Not Disturb (`FocusShortcutSetting`): on while a shortcut of the user's turns it on around each take. Turning it
/// on lists the user's shortcuts, the settings window's list, to choose one; turning it off forgets the one chosen.
private struct FocusShortcutToggle: View {
    let setting: FocusShortcutSetting
    /// Turned on, and no shortcut chosen yet.
    @State private var isChoosing = false

    /// Rows shown at once; more scroll.
    private static let visibleRows = 4.0
    private static let rowHeight = 30.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { setting.identifier != nil || isChoosing }, set: turn)) {
                Label { Text("Do Not Disturb") } icon: { Image(systemName: "moon.fill").symbolRenderingMode(.hierarchical) }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            if isChoosing { choices }
        }
    }

    private func turn(on: Bool) {
        isChoosing = on
        if on {
            setting.refreshShortcuts()
        } else {
            setting.set(nil)
        }
    }

    @ViewBuilder
    private var choices: some View {
        if let shortcuts = setting.shortcuts {
            if shortcuts.isEmpty {
                Text("No shortcuts found.")
                    .font(.system(size: 11))
                    .opacity(0.62)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(shortcuts, id: \.identifier) { shortcut in
                            ChoiceRow(
                                title: Text(verbatim: shortcut.name), isChosen: false,
                                choose: {
                                    setting.set(shortcut.identifier)
                                    isChoosing = false
                                })
                        }
                    }
                }
                .frame(height: min(Double(shortcuts.count), Self.visibleRows) * Self.rowHeight)
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

/// A switch with an icon and a title, for what is not in this version yet (no field to bind to).
private struct SettingsToggle: View {
    let title: Text
    let icon: String

    var body: some View {
        Toggle(isOn: .constant(false)) {
            Label { title } icon: { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}
