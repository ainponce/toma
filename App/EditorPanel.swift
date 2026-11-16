// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import SwiftUI

/// The panel's tabs, in the mockup's order (design §5.4): ⌘1 to ⌘6.
enum EditorPanelTab: Int, CaseIterable, Identifiable {
    case background, frame, camera, cursor, zoom, audio

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .background: "Background"
        case .frame: "Frame"
        case .camera: "Camera"
        case .cursor: "Cursor"
        case .zoom: "Zoom"
        case .audio: "Audio"
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
        }
    }

    /// The tab the selection asks for (design §5.4: the panel shows what is selected): a zoom block, Zoom; a camera change,
    /// Camera.
    static func tab(for selection: EditorSelection?) -> EditorPanelTab? {
        switch selection {
        case .zooms?: .zoom
        case .cameraChange?: .camera
        case .clips?, .screenChange?, nil: nil
        }
    }
}

/// The editor's panel, the content of the system's inspector (`NSSplitViewItem(inspectorWithViewController:)`, decision 31):
/// the tabs on top, with an indicator that moves by `Motion.selector`, and under them the tab's controls, which change with
/// `Motion.panelSwap` (a fade with a rise of 6 pt; with "Reduce motion", a fade). It shows what is selected: a zoom, Zoom; a
/// change of the camera, Camera.
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
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                        .background {
                            if tab == item {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "indicator", in: indicator)
                            }
                        }
                }
                .buttonStyle(.plain)
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
            }
        }
    }
}
