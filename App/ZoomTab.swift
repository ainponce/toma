// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import SwiftUI

/// The Zoom tab (design §5.4): above, the card of the selected zoom if one is selected; then whether zooms show, the
/// automatic zoom's settings (a change of any plans the automatic zooms again, in one step; their mode, phase 3 design §6,
/// is a step of its own), the zoom's speed and its motion blur, and the button that plans them again.
struct ZoomTab: View {
    let model: EditorModel
    let document: EditDocument

    private static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    private static func depth(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + "×"
    }

    var body: some View {
        let auto = model.autoZoomSettings ?? document.zoom.auto
        VStack(alignment: .leading, spacing: 18) {
            if case let .zooms(ids)? = model.selection, ids.count == 1, let region = document.zoom.regions.first(where: { ids.contains($0.id) }) {
                SelectedZoomCard(model: model, region: region, projectDepth: auto.depth, mode: region.resolvedMode(auto: document.zoom.auto))
                Divider()
            }
            PanelSection {
                Toggle("Show Zooms", isOn: Binding(get: { document.zoom.show }, set: { model.setZoomShow($0) }))
                Toggle("Automatic Zoom", isOn: Binding(get: { auto.enabled }, set: { on in model.changeAutoZoom { $0.enabled = on } }))
                if !model.hasClicks {
                    Text("This recording has no clicks to make zooms from. Zooms can be added by hand on the Zoom track.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            PanelSection {
                ZoomModePicker(selection: auto.mode) { model.setAutoZoomMode($0) }
                    .help(Text("The mode of the automatic zooms nobody changed."))
                Picker(
                    "Zoom On",
                    selection: Binding(get: { auto.triggers }, set: { new in model.changeAutoZoom { $0.triggers = new } })
                ) {
                    Text("Clicks").tag(ZoomTriggers.clicks)
                    Text("Clicks and Cursor Pauses").tag(ZoomTriggers.clicksAndPauses)
                }
                Toggle(
                    "Hold While Typing",
                    isOn: Binding(get: { auto.holdWhileTyping }, set: { on in model.changeAutoZoom { $0.holdWhileTyping = on } })
                )
                .disabled(!model.canHoldWhileTyping)
                if !model.canHoldWhileTyping {
                    Text("This recording didn't note when keys were typed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PanelStepSlider(
                    title: "Depth", value: auto.depth, range: ZoomPanelRules.depthRange, step: ZoomPanelRules.depthStep, format: Self.depth
                ) { new in model.changeAutoZoom { $0.depth = new } }
            }
            .disabled(!auto.enabled)
            PanelSection {
                Picker(
                    "Speed",
                    selection: Binding<ZoomSpeed?>(
                        get: { ZoomSpeed(document.zoom.spring) }, set: { if let new = $0 { model.setZoomSpeed(new) } })
                ) {
                    Text("zoom.speed.slow").tag(ZoomSpeed?.some(.slow))
                    Text("zoom.speed.medium").tag(ZoomSpeed?.some(.medium))
                    Text("zoom.speed.fast").tag(ZoomSpeed?.some(.fast))
                }
            }
            PanelSection {
                PanelStepSlider(
                    title: "Group Clicks Within", value: auto.groupGap, range: ZoomPanelRules.groupGapRange,
                    step: ZoomPanelRules.secondsStep, format: Self.seconds
                ) { new in model.changeAutoZoom { $0.groupGap = new } }
                PanelStepSlider(
                    title: "Before the Click", value: auto.leadIn, range: ZoomPanelRules.leadInRange, step: ZoomPanelRules.secondsStep,
                    format: Self.seconds
                ) { new in model.changeAutoZoom { $0.leadIn = new } }
                PanelStepSlider(
                    title: "After the Click", value: auto.leadOut, range: ZoomPanelRules.leadOutRange, step: ZoomPanelRules.secondsStep,
                    format: Self.seconds
                ) { new in model.changeAutoZoom { $0.leadOut = new } }
                Toggle(
                    "Follow the Cursor Inside the Zoom",
                    isOn: Binding(get: { auto.follow }, set: { on in model.changeAutoZoom { $0.follow = on } }))
            }
            .disabled(!auto.enabled)
            PanelSection {
                PanelSlider(title: "Motion Blur", model: model, value: PanelValues.slider(motionBlur: document.zoom.motionBlur)) {
                    model.setZoomMotionBlur(slider: $0)
                }
            }
            PanelSection {
                Button("Regenerate Automatic Zooms") { model.regenerateAutoZoom() }
                    .disabled(!auto.enabled)
                Text("Replaces the automatic zooms that weren't changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "Selected Zoom" (design §5.4): the block's mode (phase 3 design §6) and, in Loupe, the lens's size and shape; its depth
/// (the project's, for an automatic one nobody touched), where it looks, how it moves, and Delete Zoom. Touching any of
/// it makes an automatic block the user's, with the mode it shows.
private struct SelectedZoomCard: View {
    let model: EditorModel
    let region: ZoomRegion
    let projectDepth: Double
    /// The mode the block is drawn in (`ZoomRegion.resolvedMode(auto:)` with the document's settings).
    let mode: ZoomMode

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFixed: Bool {
        if case .fixed = region.focus { true } else { false }
    }

    /// "16 %": the lens's radius in % of the output's short side.
    private static func percent(_ radius: Double) -> String {
        Int((radius * 100).rounded()).formatted() + " %"
    }

    var body: some View {
        PanelSection("Selected Zoom") {
            ZoomModePicker(selection: mode) { model.setZoomMode(region.id, $0) }
            if mode == .loupe {
                loupe
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -Motion.panelSwapRise)))
            }
            Toggle(
                "Use the Project's",
                isOn: Binding(
                    get: { region.depth == nil },
                    set: { model.changeZoom(region.id, depth: .some($0 ? nil : projectDepth)) }))
            PanelStepSlider(
                title: "Depth", value: region.depth ?? projectDepth, range: ZoomPanelRules.depthRange, step: ZoomPanelRules.depthStep,
                format: { $0.formatted(.number.precision(.fractionLength(2))) + "×" }
            ) { model.changeZoom(region.id, depth: .some($0)) }
            .disabled(region.depth == nil)
            Picker(
                "Focus",
                selection: Binding(
                    get: { isFixed },
                    set: { model.changeZoom(region.id, focus: $0 ? .fixed(x: 0.5, y: 0.5) : .follow) })
            ) {
                Text("Follow the Cursor").tag(false)
                Text("Fixed Point").tag(true)
            }
            if isFixed {
                Text("Drag the box in the preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker(
                "Animation",
                selection: Binding(get: { region.instant }, set: { model.changeZoom(region.id, instant: $0) })
            ) {
                Text("Smooth").tag(false)
                Text("Instant").tag(true)
            }
            .pickerStyle(.segmented)
            .panelTitled("Animation")
            Button("Delete Zoom", role: .destructive) { model.deleteZoom(region.id) }
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: mode == .loupe)
    }

    /// "Loupe Size" and "Shape" (plan 3b decision 2): a lens equal to the default one is not written.
    private var loupe: some View {
        let style = region.resolvedLoupe
        return VStack(alignment: .leading, spacing: 8) {
            PanelStepSlider(
                title: "Loupe Size", value: style.radius, range: ZoomPanelRules.loupeRadiusRange, step: ZoomPanelRules.loupeRadiusStep,
                format: Self.percent
            ) { model.setLoupe(region.id, radius: $0) }
            // Its title above it: "Rectángulo redondeado" beside "Forma" would be cut in the panel's width.
            Picker("Shape", selection: Binding(get: { style.shape }, set: { model.setLoupe(region.id, shape: $0) })) {
                Label("Circle", systemImage: "circle").tag(LoupeShape.circle)
                Label("Rounded Rectangle", systemImage: "rectangle").tag(LoupeShape.roundedRect)
            }
            .panelTitled("Shape")
        }
    }
}

/// "Mode" (phase 3 design §6): a menu of the four modes, each with its symbol and its name.
private struct ZoomModePicker: View {
    let selection: ZoomMode
    let choose: @MainActor @Sendable (ZoomMode) -> Void

    var body: some View {
        Picker("Mode", selection: Binding(get: { selection }, set: choose)) {
            ForEach(ZoomMode.allCases, id: \.self) { mode in
                Label(ZoomModeNames.title(mode), systemImage: ZoomPanelRules.symbol(mode)).tag(mode)
            }
        }
    }
}

/// The names of the zoom's modes: their own keys (`zoom.mode.*`), since "Classic" and "Highlight" are also looks of the
/// captions, with other words in Spanish.
enum ZoomModeNames {
    static func title(_ mode: ZoomMode) -> LocalizedStringKey {
        switch mode {
        case .classic: "zoom.mode.classic"
        case .highlight: "zoom.mode.highlight"
        case .dim: "zoom.mode.dim"
        case .loupe: "zoom.mode.loupe"
        }
    }

    /// The same name as a string (VoiceOver's label of a block).
    static func text(_ mode: ZoomMode) -> String {
        switch mode {
        case .classic: String(localized: "zoom.mode.classic", comment: "A zoom mode: the camera moves in, as before")
        case .highlight: String(localized: "zoom.mode.highlight", comment: "A zoom mode: a ring around the focus and the rest a little darker")
        case .dim: String(localized: "zoom.mode.dim", comment: "A zoom mode: outside the focus darker and blurred")
        case .loupe: String(localized: "zoom.mode.loupe", comment: "A zoom mode: a lens over the focus that shows it bigger")
        }
    }
}
