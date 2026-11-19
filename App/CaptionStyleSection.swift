// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// The Captions tab's Style (design §5.2 and §5.3), folded under its title until opened (remembered for every editor):
/// whether the captions show, their look as three tiles (Classic, Highlight, Minimal), their size and place, uppercase,
/// and the spoken word's highlight with its colour. Each control is one step (`VoiceCommands`); the colour of the
/// system's panel is a gesture of the model, one step when it rests.
struct CaptionStyleSection: View {
    let model: EditorModel
    let captions: CaptionPlan

    @AppStorage("captionsStyleExpanded") private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var style: CaptionStyle { captions.style }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.panel(Motion.panelSwap, reduceMotion: reduceMotion)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Style")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !isExpanded {
                        Text(captions.show ? presetName(style.preset) : "Not Shown")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Style"))
            .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))
            .accessibilityAddTraits(.isHeader)
            if isExpanded {
                controls
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -Motion.panelSwapRise)))
            }
        }
    }

    private var isExpanded: Bool {
        #if DEBUG
        if CaptionsShowcase.variant == "style" { return true }
        #endif
        return expanded
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Show Captions", isOn: Binding(get: { captions.show }, set: { model.setCaptionsShow($0) }))
            Group {
                CaptionPresetTiles(selected: style.preset, highlightColor: style.highlightColor) { model.setCaptionPreset($0) }
                Picker("Size", selection: Binding(get: { style.size }, set: { size in model.changeCaptionStyle { $0.size = size } })) {
                    Text("captions.size.small").tag(OverlaySize.small)
                    Text("captions.size.medium").tag(OverlaySize.medium)
                    Text("captions.size.large").tag(OverlaySize.large)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                .panelTitled("Size")
                Picker(
                    "Position",
                    selection: Binding(get: { style.position }, set: { position in model.changeCaptionStyle { $0.position = position } })
                ) {
                    Text("Bottom").tag(CaptionPosition.bottom)
                    Text("Top").tag(CaptionPosition.top)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                .panelTitled("Position")
                Toggle("Uppercase", isOn: Binding(get: { style.uppercase }, set: { on in model.changeCaptionStyle { $0.uppercase = on } }))
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Highlight the Word Being Said",
                        isOn: Binding(get: { style.highlight }, set: { on in model.changeCaptionStyle { $0.highlight = on } }))
                    HighlightColorRow(model: model, color: style.highlightColor)
                        .disabled(!style.highlight)
                }
            }
            .disabled(!captions.show)
        }
    }

    private func presetName(_ preset: CaptionPreset) -> LocalizedStringKey {
        switch preset {
        case .classic: "Classic"
        case .bold: "Highlight"
        case .minimal: "Minimal"
        }
    }
}

/// The three looks as tiles of a dark frame with "Aa" drawn in each (design §5.2): Classic on its box, Highlight heavy
/// and outlined with its second letter in the highlight colour, Minimal plain with a soft shadow. VoiceOver reads
/// "Highlight, selected".
private struct CaptionPresetTiles: View {
    let selected: CaptionPreset
    let highlightColor: RGBA
    let choose: (CaptionPreset) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CaptionPreset.allCases, id: \.self) { preset in
                VStack(spacing: 4) {
                    PanelTile(name: name(preset), isSelected: selected == preset) {
                        choose(preset)
                    } swatch: {
                        sample(preset)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(
                                LinearGradient(
                                    colors: [Color(white: 0.30), Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    Text(name(preset))
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(selected == preset ? .primary : .secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Look"))
    }

    @ViewBuilder
    private func sample(_ preset: CaptionPreset) -> some View {
        switch preset {
        case .classic:
            Text(verbatim: "Aa")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.6)))
        case .bold:
            (Text(verbatim: "A").foregroundStyle(.white) + Text(verbatim: "a").foregroundStyle(highlightColor.color))
                .font(.system(size: 17, weight: .heavy))
                .shadow(color: .black, radius: 0, x: 1, y: 0)
                .shadow(color: .black, radius: 0, x: -1, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: 1)
                .shadow(color: .black, radius: 0, x: 0, y: -1)
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        case .minimal:
            Text(verbatim: "Aa")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        }
    }

    private func name(_ preset: CaptionPreset) -> LocalizedStringKey {
        switch preset {
        case .classic: "Classic"
        case .bold: "Highlight"
        case .minimal: "Minimal"
        }
    }
}

/// The highlight's colour: six swatches, and the system's colour panel, whose dragging is one gesture of the model (the
/// preview follows; one step once it rests for a moment, or when the tab goes away).
private struct HighlightColorRow: View {
    let model: EditorModel
    let color: RGBA

    /// Whether the gesture under way is this row's.
    @State private var gesturing = false
    @State private var rest: Task<Void, Never>?

    /// Yellow (the default), orange, coral, violet, turquoise and green.
    static let swatches: [RGBA] = [
        RGBA(1, 214.0 / 255, 10.0 / 255, 1), RGBA(1, 159.0 / 255, 10.0 / 255, 1), RGBA(1, 55.0 / 255, 95.0 / 255, 1),
        RGBA(191.0 / 255, 90.0 / 255, 242.0 / 255, 1), RGBA(100.0 / 255, 210.0 / 255, 1, 1), RGBA(48.0 / 255, 209.0 / 255, 88.0 / 255, 1),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Highlight Color")
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                ForEach(Array(Self.swatches.enumerated()), id: \.offset) { index, swatch in
                    Button {
                        model.changeCaptionStyle { $0.highlightColor = swatch }
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                            .overlay {
                                if color == swatch { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-3) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(Self.swatchName(index)))
                    .accessibilityAddTraits(color == swatch ? .isSelected : [])
                }
                Spacer(minLength: 8)
                ColorPicker(
                    "Highlight Color", selection: Binding(get: { color.color }, set: { changed(RGBA($0)) }), supportsOpacity: false
                )
                .labelsHidden()
            }
        }
        .onDisappear(perform: finish)
    }

    private static func swatchName(_ index: Int) -> LocalizedStringKey {
        switch index {
        case 0: "Yellow"
        case 1: "Orange"
        case 2: "Coral"
        case 3: "Violet"
        case 4: "Turquoise"
        default: "Green"
        }
    }

    /// A colour from the panel: the gesture starts (unless another one is under way) or goes on, and ends once the panel
    /// rests for 0.6 s.
    private func changed(_ new: RGBA) {
        guard new != color || gesturing else { return }
        if !gesturing {
            guard model.canEdit, !model.isGesturing else { return }
            model.beginGesture()
            gesturing = true
        }
        model.updateGesture(model.captionStyleStep { $0.highlightColor = new })
        rest?.cancel()
        rest = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            finish()
        }
    }

    private func finish() {
        rest?.cancel()
        rest = nil
        guard gesturing else { return }
        gesturing = false
        model.endGesture()
    }
}

// MARK: - The commands of the style

extension EditorModel {
    /// "Show Captions".
    func setCaptionsShow(_ show: Bool) {
        guard canEdit, let document, let step = VoiceCommands.setCaptionsShow(document, show) else { return }
        perform(step)
    }

    /// A look of the captions; the spoken word's highlight goes with it (on in Highlight).
    func setCaptionPreset(_ preset: CaptionPreset) {
        guard canEdit, let document, let step = VoiceCommands.setCaptionPreset(document, preset) else { return }
        perform(step)
    }

    /// The captions' style changed by `edit`, in one step.
    func changeCaptionStyle(_ edit: (inout CaptionStyle) -> Void) {
        guard canEdit, let step = captionStyleStep(edit) else { return }
        perform(step)
    }

    /// The step that changes the captions' style of the document by `edit`; `nil` if it changes nothing.
    func captionStyleStep(_ edit: (inout CaptionStyle) -> Void) -> EditStep? {
        guard let document else { return nil }
        var style = document.captions.style
        edit(&style)
        return VoiceCommands.setCaptionStyle(document, style)
    }
}
