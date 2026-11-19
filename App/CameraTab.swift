// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
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

    /// The shape drawn, as the Shape control shows it.
    static func shapeSymbol(_ shape: CameraShape) -> String {
        switch shape {
        case .circle: "circle"
        case .roundedSquare: "app"
        case .portrait: "rectangle.portrait"
        case .landscape: "rectangle"
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

/// The Camera tab (design §5.6), only with a camera. From the top: the selected layout block, if there is one; whether the
/// camera shows; Disposición, with its five tiles and what its controls edit; the split's side and size; the bubble's shape,
/// size and place (for a Bubble layout) with a line saying which style that is; the list of changes of the recording; and the
/// camera's look. The rules (which block or style each control edits, the hidden changes) are `CameraTabTargets` and
/// `CameraChangeList`; this view only draws them.
struct CameraTab: View {
    let model: EditorModel
    let document: EditDocument

    var body: some View {
        let map = TimeMap(sequence: document.sequence)
        let now = model.playheadNanoseconds
        let layoutTarget = CameraTabTargets.layout(document, selectedBlock: model.selectedLayoutBlock, timeMap: map)
        let bubbleTarget = CameraTabTargets.bubble(document, selectedBlock: model.selectedLayoutBlock, atOutput: now, timeMap: map)
        let block = Self.block(of: layoutTarget, in: document)
        let kind = block?.kind ?? document.camera.layout.kind
        let split = block?.split ?? (block == nil ? document.camera.layout.split : nil)
        let output = StageLayout.outputSize(aspect: document.aspect, shortSide: 1080, contentRatio: model.contentRatio(of: document))
        let outputSize = SIMD2(Double(output.x), Double(output.y))
        VStack(alignment: .leading, spacing: 18) {
            if let block {
                selectedBlock(block, map: map)
                Divider()
            }
            PanelSection {
                Toggle("Show Camera", isOn: Binding(get: { document.camera.show }, set: { model.setCameraShow($0) }))
            }
            PanelSection("Layout") {
                editing(layoutTarget)
                LayoutTiles(
                    output: outputSize, padding: document.style.padding, cornerRadius: document.style.cornerRadius, selected: kind,
                    split: split
                ) { model.setLayoutKind($0, target: layoutTarget) }
                if kind == .split {
                    splitControls(split, id: block?.id, orientation: CameraLayoutGeometry.orientation(output: outputSize))
                }
            }
            if kind == .bubble {
                bubbleControls(bubbleTarget, map: map, now: now)
            }
            Divider()
            PanelSection("Changes During the Recording") {
                changes(document, map: map, now: now)
            }
            Divider()
            look
        }
    }

    private static func block(of target: LayoutEditTarget, in document: EditDocument) -> LayoutBlock? {
        guard case let .block(id, _) = target else { return nil }
        return document.camera.layouts.first { $0.id == id }
    }

    // MARK: - The selected block

    @ViewBuilder
    private func selectedBlock(_ block: LayoutBlock, map: TimeMap) -> some View {
        let index = document.camera.layouts.firstIndex { $0.id == block.id }
        let range = index.flatMap { LayoutTimeline.blockOutputs(of: document, timeMap: map)[$0] }
        PanelSection("Selected Block") {
            if let range {
                Text(
                    verbatim: String(
                        format: String(localized: "From %1$@ to %2$@"), Self.precise(range.lowerBound, map), Self.precise(range.upperBound, map))
                )
                .monospacedDigit()
            }
            Picker(
                "Transition",
                selection: Binding(get: { block.instant }, set: { model.setLayoutInstant(block.id, $0) })
            ) {
                Text("Smooth").tag(false)
                Text("Instant").tag(true)
            }
            .pickerStyle(.segmented)
            .panelTitled("Transition")
            Button("Delete Block", role: .destructive) { model.deleteLayoutBlock(block.id) }
        }
    }

    private static func precise(_ output: Int64, _ map: TimeMap) -> String {
        Timecode.precise(Double(output) / 1e9, total: map.durationSeconds, locale: .current)
    }

    // MARK: - Disposición

    @ViewBuilder
    private func editing(_ target: LayoutEditTarget) -> some View {
        switch target {
        case let .block(_, output):
            Text("Editing: the block at \(CameraNames.time(output))").font(.callout.weight(.medium))
        case .project:
            Text("Editing: the project layout").font(.callout.weight(.medium))
        }
    }

    @ViewBuilder
    private func splitControls(_ split: SplitLayout?, id: String?, orientation: SplitOrientation) -> some View {
        let side = split?.side ?? .end
        Picker("Camera Side", selection: Binding(get: { side }, set: { model.setSplitSide($0, id: id) })) {
            switch orientation {
            case .beside:
                Text("Left").tag(CameraSide.start)
                Text("Right").tag(CameraSide.end)
            case .stacked:
                Text("Top").tag(CameraSide.start)
                Text("Bottom").tag(CameraSide.end)
            }
        }
        .pickerStyle(.segmented)
        .panelTitled("Camera Side")
        let share = split?.share
        Toggle("Automatic", isOn: Binding(get: { share == nil }, set: { model.setSplitShare(percent: $0 ? nil : Self.manualShare, id: id) }))
        PanelSlider(
            title: "Camera Size", model: model, value: PanelValues.percent(splitShare: share ?? Double(Self.manualShare) / 100),
            range: PanelValues.splitShareRange, unit: " %"
        ) { model.setSplitShare(percent: $0, id: id) }
        .disabled(share == nil)
    }

    /// Where the bar starts when Automático is turned off.
    private static let manualShare = 40

    // MARK: - The bubble

    @ViewBuilder
    private func bubbleControls(_ target: BubbleEditTarget, map: TimeMap, now: Int64) -> some View {
        let ruling = TrackCommands.rulingCameraStyle(document, atOutput: now, timeMap: map).style
        let style: CameraStyle = {
            if case let .block(id, _) = target, let own = document.camera.layouts.first(where: { $0.id == id })?.bubble?.style { return own }
            return ruling
        }()
        PanelSection {
            switch target {
            case .initial:
                Text("Editing: the initial style").font(.callout.weight(.medium))
            case let .change(_, output):
                Text("Editing: the change at \(CameraNames.time(output))").font(.callout.weight(.medium))
            case let .block(_, output):
                Text("Editing: the block at \(CameraNames.time(output))").font(.callout.weight(.medium))
            }
            Picker(
                "Shape",
                selection: Binding(
                    get: { style.shape }, set: { new in var next = style; next.shape = new; model.setBubbleStyle(next, target: target) })
            ) {
                // The shapes drawn: their four names side by side do not fit in the panel.
                ForEach(CameraShape.allCases, id: \.self) { shape in
                    Label(CameraNames.shape(shape), systemImage: CameraNames.shapeSymbol(shape))
                        .labelStyle(.iconOnly)
                        .tag(shape)
                }
            }
            .pickerStyle(.segmented)
            .panelTitled("Shape")
            .help(Text(CameraNames.shape(style.shape)))
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
                        model.setBubbleStyle(next, target: target)
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
                model.setBubbleStyle(next, target: target)
            }
        }
        PanelSection("Position") {
            AnchorGrid(anchor: style.anchor) { anchor in
                var next = style
                next.anchor = anchor
                model.setBubbleStyle(next, target: target)
            }
            Text("Drag the bubble in the preview to place it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The changes

    @ViewBuilder
    private func changes(_ document: EditDocument, map: TimeMap, now: Int64) -> some View {
        let rows = CameraChangeList.rows(document, timeMap: map, layouts: model.layoutTimeline)
        let selected: String? = if case let .cameraChange(id)? = model.selection { id } else { nil }
        VStack(spacing: 2) {
            ForEach(rows, id: \.id) { row in
                Button {
                    model.selectCameraChange(row.id, output: row.output)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(CameraNames.time(row.output)) · \(CameraNames.description(row.style))")
                        if let hidden = row.hiddenBy {
                            Text(verbatim: String(
                                format: String(localized: "hidden by the “%1$@” block at %2$@"), LayoutNames.name(hidden.kind),
                                CameraNames.time(hidden.output)))
                            .font(.caption)
                        }
                    }
                    .opacity(row.hiddenBy == nil ? 1 : 0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                    .background(selected == row.id ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(
                    row.hiddenBy.map {
                        Text(verbatim: String(format: String(localized: "Not shown while the “%@” block rules; it still counts afterwards."), LayoutNames.name($0.kind)))
                    } ?? Text(verbatim: ""))
                .accessibilityAddTraits(selected == row.id ? .isSelected : [])
            }
        }
        if !document.camera.layouts.isEmpty {
            Text("The recording's changes only show outside blocks, with the Bubble layout; those inside still count afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Side by side if they fit in the panel, else one under the other.
        let deleteChange = Button("Delete Change") {
            if let selected { model.deleteCameraChange(selected) }
        }
        .disabled(selected == nil || !rows.contains { $0.id == selected })
        ViewThatFits(in: .horizontal) {
            HStack {
                Button("Add Change at Playhead") { model.addCameraChange() }
                deleteChange
            }
            VStack(alignment: .leading) {
                Button("Add Change at Playhead") { model.addCameraChange() }
                deleteChange
            }
        }
        Button("Delete All Changes") { model.deleteAllCameraChanges() }
            .disabled(document.camera.changes.isEmpty)
    }

    // MARK: - The look

    private var look: some View {
        let camera = document.camera
        return PanelSection("Camera Look") {
            Toggle("Mirror", isOn: Binding(get: { camera.mirror }, set: { model.setCameraMirror($0) }))
            PanelSlider(title: "Border", model: model, value: PanelValues.slider(cameraBorder: camera.border.width)) {
                model.setCameraBorder(slider: $0)
            }
            // The title above the swatches: beside them, the row is wider than the panel.
            Text("Border Color")
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                ForEach(Array(CameraLookCommands.borderSwatches.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        model.setCameraBorderColor(swatch)
                    } label: {
                        Circle()
                            .fill(Color(swatch))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                            .overlay {
                                if camera.border.color == swatch { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-3) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(camera.border.color == swatch ? .isSelected : [])
                    .accessibilityLabel(Text(verbatim: Self.swatchName(swatch)))
                }
                Spacer(minLength: 8)
                ColorPicker(
                    "Border Color",
                    selection: Binding(get: { Color(camera.border.color) }, set: { model.setCameraBorderColor($0.rgba) }),
                    supportsOpacity: false
                )
                .labelsHidden()
            }
            PanelSlider(title: "Shadow", model: model, value: PanelValues.slider(cameraShadow: camera.shadow)) {
                model.setCameraShadow(slider: $0)
            }
        }
    }

    private static func swatchName(_ swatch: RGBA) -> String {
        switch CameraLookCommands.borderSwatches.firstIndex(of: swatch) {
        case 0: String(localized: "White")
        case 1: String(localized: "Black")
        case 2: String(localized: "Gray")
        case 3: String(localized: "Violet")
        case 4: String(localized: "Turquoise")
        default: String(localized: "Coral")
        }
    }
}

private extension Color {
    init(_ rgba: RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    /// The colour as sRGB components, which the document keeps as they are.
    var rgba: RGBA {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return RGBA(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), 1)
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
