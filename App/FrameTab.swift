// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import SwiftUI

/// The Frame tab (design §5.4): none, or a generic macOS window around the screen with its appearance, title and buttons.
struct FrameTab: View {
    let model: EditorModel
    let style: StageStyle

    private var isWindow: Bool {
        if case .macWindow = style.frame { true } else { false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Frame", selection: Binding(get: { isWindow }, set: setWindow)) {
                Text("frame.none").tag(false)
                Text("macOS Window").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if case let .macWindow(appearance, title, buttons) = style.frame {
                Picker(
                    "Appearance",
                    selection: Binding(get: { appearance }, set: { set(.macWindow(appearance: $0, title: title, buttons: buttons)) })
                ) {
                    Text("Light").tag(FrameAppearance.light)
                    Text("Dark").tag(FrameAppearance.dark)
                }
                .pickerStyle(.segmented)
                TextField(
                    "Title", text: Binding(get: { title }, set: { set(.macWindow(appearance: appearance, title: $0, buttons: buttons)) })
                )
                .textFieldStyle(.roundedBorder)
                Toggle(
                    "Window Buttons",
                    isOn: Binding(get: { buttons }, set: { set(.macWindow(appearance: appearance, title: title, buttons: $0)) }))
            }
        }
    }

    private func setWindow(_ window: Bool) {
        // The new window: dark, without a title, with its buttons (design §5.4).
        set(window ? .macWindow(appearance: .dark, title: "", buttons: true) : .none)
    }

    private func set(_ frame: WindowFrame) {
        model.setStyle("/style/frame", frame, label: .frame)
    }
}
