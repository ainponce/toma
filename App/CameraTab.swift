// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// The words of the camera's style (design §5.4 and §5.11).
enum CameraNames {
    static func shape(_ shape: CameraShape) -> LocalizedStringKey {
        switch shape {
        case .circle: "Circle"
        case .roundedSquare: "Square"
        case .portrait: "Vertical"
        case .landscape: "Horizontal"
        }
    }

    static func shapeText(_ shape: CameraShape) -> String {
        switch shape {
        case .circle: String(localized: "Circle")
        case .roundedSquare: String(localized: "Square")
        case .portrait: String(localized: "Vertical")
        case .landscape: String(localized: "Horizontal")
        }
    }

    /// Small, Medium or Large when the size is one of them, and its percentage of the height if not.
    static func sizeText(_ size: Double) -> String {
        switch size {
        case CameraStyle.small: String(localized: "Small")
        case CameraStyle.medium: String(localized: "Medium")
        case CameraStyle.large: String(localized: "Large")
        default: "\(PanelValues.percent(cameraSize: size)) %"
        }
    }

    static func anchorText(_ anchor: CameraAnchor) -> String {
        switch anchor {
        case .topLeading: String(localized: "Top Left")
        case .top: String(localized: "Top")
        case .topTrailing: String(localized: "Top Right")
        case .leading: String(localized: "Left")
        case .trailing: String(localized: "Right")
        case .bottomLeading: String(localized: "Bottom Left")
        case .bottom: String(localized: "Bottom")
        case .bottomTrailing: String(localized: "Bottom Right")
        }
    }

    /// "Circle, medium, top left".
    static func description(_ style: CameraStyle) -> String {
        "\(shapeText(style.shape)), \(sizeText(style.size).lowercased()), \(anchorText(style.anchor).lowercased())"
    }

    static func time(_ output: Int64) -> String {
        Timecode.duration(Double(output) / 1e9)
    }
}

/// The Camera tab (design §5.4), only with a camera: whether it shows, and the style that rules at the playhead (its shape,
/// size and place) with a line saying which one that is, and the list of the changes of the recording.
struct CameraTab: View {
    let model: EditorModel
    let document: EditDocument

    var body: some View {
        let map = TimeMap(sequence: document.sequence)
        let now = model.playheadNanoseconds
        let style = TrackCommands.rulingCameraStyle(document, atOutput: now, timeMap: map).style
        VStack(alignment: .leading, spacing: 18) {
            PanelSection {
                Toggle("Show Camera", isOn: Binding(get: { document.camera.show }, set: { model.setCameraShow($0) }))
            }
            PanelSection {
                switch CameraChangeList.editing(document, atOutput: now, timeMap: map) {
                case .initial:
                    Text("Editing: the initial style")
                        .font(.callout.weight(.medium))
                case let .change(_, output):
                    Text("Editing: the change at \(CameraNames.time(output))")
                        .font(.callout.weight(.medium))
                }
                Picker(
                    "Shape",
                    selection: Binding(
                        get: { style.shape }, set: { new in var next = style; next.shape = new; model.setCameraStyle(next) })
                ) {
                    ForEach(CameraShape.allCases, id: \.self) { shape in
                        Text(CameraNames.shape(shape)).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
            }
            PanelSection {
                Picker(
                    "Size",
                    selection: Binding<Double?>(
                        get: { [CameraStyle.small, CameraStyle.medium, CameraStyle.large].first { $0 == style.size } },
                        set: { new in
                            guard let new else { return }
                            var next = style
                            next.size = new
                            model.setCameraStyle(next)
                        })
                ) {
                    Text("Small").tag(Double?.some(CameraStyle.small))
                    Text("Medium").tag(Double?.some(CameraStyle.medium))
                    Text("Large").tag(Double?.some(CameraStyle.large))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                PanelSlider(
                    title: "Size", model: model, value: PanelValues.percent(cameraSize: style.size), range: PanelValues.cameraSizeRange,
                    unit: " %"
                ) { percent in
                    var next = style
                    next.size = PanelValues.cameraSize(percent: percent)
                    model.setCameraStyle(next)
                }
            }
            PanelSection("Position") {
                AnchorGrid(anchor: style.anchor) { anchor in
                    var next = style
                    next.anchor = anchor
                    model.setCameraStyle(next)
                }
                Text("Drag the bubble in the preview to place it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            PanelSection("Changes During the Recording") {
                changes(document, map: map, now: now)
            }
        }
    }

    @ViewBuilder
    private func changes(_ document: EditDocument, map: TimeMap, now: Int64) -> some View {
        let rows = CameraChangeList.rows(document, timeMap: map)
        let selected: String? = if case let .cameraChange(id)? = model.selection { id } else { nil }
        VStack(spacing: 2) {
            ForEach(rows, id: \.id) { row in
                Button {
                    model.selectCameraChange(row.id, output: row.output)
                } label: {
                    Text(verbatim: "\(CameraNames.time(row.output)) · \(CameraNames.description(row.style))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .background(selected == row.id ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == row.id ? .isSelected : [])
            }
        }
        HStack {
            Button("Add Change at Playhead") { model.addCameraChange() }
            Button("Delete Change") {
                if let selected { model.deleteCameraChange(selected) }
            }
            .disabled(selected == nil || !rows.contains { $0.id == selected })
        }
    }
}

/// The 3×3 grid of places (design §5.4): the 8 anchors, with the centre off. With the grid focused, the arrow keys take the
/// bubble to the neighbouring place.
private struct AnchorGrid: View {
    let anchor: CameraAnchor
    let choose: (CameraAnchor) -> Void

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(CameraAnchorGrid.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(CameraAnchorGrid.rows[row].indices, id: \.self) { column in
                        cell(CameraAnchorGrid.rows[row][column])
                    }
                }
            }
        }
        .frame(maxWidth: 150)
        .focusable()
        .onKeyPress(.leftArrow) { move(-1, 0) }
        .onKeyPress(.rightArrow) { move(1, 0) }
        .onKeyPress(.upArrow) { move(0, -1) }
        .onKeyPress(.downArrow) { move(0, 1) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func cell(_ place: CameraAnchor?) -> some View {
        if let place {
            Button {
                choose(place)
            } label: {
                RoundedRectangle(cornerRadius: 5)
                    .fill(place == anchor ? Color.accentColor : Color.primary.opacity(0.12))
                    .aspectRatio(16.0 / 10, contentMode: .fit)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: CameraNames.anchorText(place)))
            .accessibilityLabel(Text(verbatim: CameraNames.anchorText(place)))
            .accessibilityAddTraits(place == anchor ? .isSelected : [])
        } else {
            Color.clear
                .aspectRatio(16.0 / 10, contentMode: .fit)
                .accessibilityHidden(true)
        }
    }

    private func move(_ dx: Int, _ dy: Int) -> KeyPress.Result {
        let next = CameraAnchorGrid.neighbor(of: anchor, dx: dx, dy: dy)
        if next != anchor { choose(next) }
        return .handled
    }
}
