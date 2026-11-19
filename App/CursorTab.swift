// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import SwiftUI

/// The Cursor tab (design §5.4): whether it shows, its look, size and smoothing, hiding it when it is still, the click's
/// effect and sound, and the motion blur. Every control is a step of `StyleCommands.set` on `/cursor/…`; the click effect
/// is part of the cursor (design §7.5), so it is off with the cursor hidden.
struct CursorTab: View {
    let model: EditorModel
    let cursor: CursorStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelSection {
                Toggle("Show Cursor", isOn: Binding(get: { cursor.show }, set: { set("show", $0) }))
            }
            PanelSection {
                Picker("Style", selection: Binding(get: { cursor.style }, set: { set("style", $0) })) {
                    Text("macOS (as recorded)").tag(CursorLook.system)
                    Text("Toma").tag(CursorLook.toma)
                }
                .pickerStyle(.segmented)
                .panelTitled("Style")
                if !model.hasCursorImages {
                    Text("This recording didn't save the cursor's shape: Toma's arrow is used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PanelSlider(
                    title: "Size", model: model, value: PanelValues.percent(cursorScale: cursor.scale), range: PanelValues.cursorScaleRange,
                    unit: " %"
                ) { set("scale", PanelValues.cursorScale(percent: $0)) }
                Picker(
                    "Smoothing",
                    selection: Binding<CursorSmoothingPreset?>(
                        get: { CursorSmoothingPreset(cursor.smoothing) },
                        set: { if let new = $0 { set("smoothing", new.smoothing) } })
                ) {
                    Text("Off").tag(CursorSmoothingPreset?.some(.off))
                    Text("Fast").tag(CursorSmoothingPreset?.some(.fast))
                    Text("smoothing.medium").tag(CursorSmoothingPreset?.some(.medium))
                    Text("Smooth").tag(CursorSmoothingPreset?.some(.smooth))
                }
            }
            PanelSection {
                Toggle("Hide When Still", isOn: Binding(get: { cursor.hideWhenIdle }, set: { set("hideWhenIdle", $0) }))
                Stepper(
                    value: Binding(get: { cursor.idleDelay }, set: { set("idleDelay", $0) }),
                    in: PanelValues.idleDelayRange, step: PanelValues.idleDelayStep
                ) {
                    Text("After \(cursor.idleDelay.formatted(.number.precision(.fractionLength(0...1)))) s")
                        .monospacedDigit()
                }
                .disabled(!cursor.hideWhenIdle)
            }
            PanelSection {
                Picker("Click Effect", selection: Binding(get: { cursor.clickEffect }, set: { set("clickEffect", $0) })) {
                    Text("cursor.none").tag("none")
                    Text("Ripple").tag("ripple-1")
                    Text("Circle").tag("circle-1")
                }
                .disabled(!cursor.show)
                Picker("Click Sound", selection: Binding(get: { cursor.clickSound }, set: { set("clickSound", $0) })) {
                    Text("cursor.none").tag("none")
                    Text("Soft").tag("soft-1")
                    Text("Mechanical").tag("mechanical-1")
                }
                PanelSlider(
                    title: "Volume", model: model, value: PanelValues.percent(clickSoundGain: cursor.clickSoundGain), unit: " %"
                ) { set("clickSoundGain", PanelValues.clickSoundGain(percent: $0)) }
                .disabled(cursor.clickSound == "none")
            }
            PanelSection {
                PanelSlider(title: "Motion Blur", model: model, value: PanelValues.slider(motionBlur: cursor.motionBlur)) {
                    set("motionBlur", PanelValues.motionBlur(slider: $0))
                }
            }
            KeysOnScreenSection(model: model)
        }
    }

    private func set(_ key: String, _ value: some Encodable) {
        model.setStyle("/cursor/\(key)", value, label: .cursor)
    }
}
