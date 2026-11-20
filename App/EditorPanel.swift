// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import SwiftUI

/// The panel's tabs, in the mockup's order (design §5.4): ⌘1 to ⌘8, and Annotations, ⌘9 (phase 3 design §5.6).
enum EditorPanelTab: Int, CaseIterable, Identifiable {
    case background, frame, camera, cursor, zoom, audio, captions, privacy, annotations

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .background: "Background"
        case .frame: "Frame"
        case .camera: "Camera"
        case .cursor: "Cursor"
        case .zoom: "Zoom"
        case .audio: "Audio"
        case .captions: "Captions"
        case .privacy: "Privacy"
        case .annotations: "Annotations"
        }
    }

    var symbol: String {
        switch self {
        case .background: "photo.artframe"
        case .frame: "macwindow"
        case .camera: "web.camera"
        case .cursor: "cursorarrow"
        case .zoom: "plus.magnifyingglass"
        case .audio: "waveform"
        case .captions: "captions.bubble"
        case .privacy: "eye.slash"
        case .annotations: "scribble.variable"
        }
    }

    /// The tab the selection asks for (design §5.4: the panel shows what is selected): a zoom block, Zoom; a camera change,
    /// Camera.
    static func tab(for selection: EditorSelection?) -> EditorPanelTab? {
        switch selection {
        case .zooms?: .zoom
        case .cameraChange?, .layoutBlock?: .camera
        case .privacyBlocks?: .privacy
        case .annotations?: .annotations
        case .gainRange?: .audio
        case .clips?, .screenChange?, nil: nil
        }
    }
}

/// The editor's panel, the content of the system's inspector (`NSSplitViewItem(inspectorWithViewController:)`, decision 31):
/// the row Style on top (1c design §8, `StyleRow`), then the tabs, with an indicator that moves by `Motion.selector`, and
/// under them the tab's controls, which change with `Motion.panelSwap` (a fade with a rise of 6 pt; with "Reduce motion",
/// a fade). It shows what is selected: a zoom, Zoom; a change of the camera, Camera.
struct EditorPanel: View {
    let model: EditorModel

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tab shown: the model's, remembered with the window's state.
    private var tab: EditorPanelTab { model.panelTab }

    private var tabs: [EditorPanelTab] {
        EditorPanelTab.allCases.filter { $0 != .camera || model.hasCamera }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let document = model.document {
                StyleRow(model: model, document: document)
                Divider()
            }
            tabBar
            Divider()
            ScrollView {
                content
                    .id(tab)
                    .transition(
                        reduceMotion
                            ? .opacity : .opacity.combined(with: .offset(y: Motion.panelSwapRise)))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.canEdit)
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: tab)
        .onChange(of: model.selection) { _, selection in
            if let wanted = EditorPanelTab.tab(for: selection), tabs.contains(wanted) { model.panelTab = wanted }
        }
        .onChange(of: model.hasCamera) { _, has in
            if !has, tab == .camera { model.panelTab = .background }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Panel"))
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { item in
                Button {
                    withAnimation(.panel(Motion.selector, reduceMotion: reduceMotion)) { model.panelTab = item }
                } label: {
                    Image(systemName: item.symbol)
                }
                .buttonStyle(PanelTabStyle(isSelected: tab == item, indicator: indicator))
                .keyboardShortcut(KeyEquivalent(Character(String(item.rawValue + 1))), modifiers: .command)
                .help(Text(item.title))
                .accessibilityLabel(Text(item.title))
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if let document = model.document {
            switch tab {
            case .background: BackgroundTab(model: model, style: document.style)
            case .frame: FrameTab(model: model, style: document.style)
            case .camera: CameraTab(model: model, document: document)
            case .cursor: CursorTab(model: model, cursor: document.cursor)
            case .zoom: ZoomTab(model: model, document: document)
            case .audio: AudioTab(model: model, audio: document.audio)
            case .captions: CaptionsTab(model: model)
            case .privacy: PrivacyTab(model: model)
            case .annotations: AnnotationsTab(model: model)
            }
        }
    }
}

/// A tab of the panel: its symbol, in the accent color on the indicator when it is the one shown (the indicator moves
/// between tabs by `Motion.selector`); the others secondary, with a wash while the mouse is over them or they are pressed.
private struct PanelTabStyle: ButtonStyle {
    let isSelected: Bool
    let indicator: Namespace.ID

    func makeBody(configuration: Configuration) -> some View {
        PanelTabLabel(configuration: configuration, isSelected: isSelected, indicator: indicator)
    }
}

private struct PanelTabLabel: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let indicator: Namespace.ID
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .matchedGeometryEffect(id: "indicator", in: indicator)
                } else if hovering || configuration.isPressed {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
                }
            }
            .onHover { hovering = $0 }
            .animation(.panel(Motion.hover, reduceMotion: reduceMotion), value: hovering)
    }
}
