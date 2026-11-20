// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// The inspector of the one annotation selected (phase 3 design §5.1 and §5.5, plan 3a decisions 2–6, 18 and 19): what
/// it is and when the output shows it; its anchor (Stick to the Recording, Whole Video; both off, it is fixed on the
/// output); what its kind has (a text's words, style, font, weight, size, colour, fill and alignment; an arrow's colour,
/// width, head and curve; a shape's kind, border, width and fill; a speech bubble's text; a step's colour; an image's fit,
/// corners and shadow; a clip's sound, corners and shadow); how it comes in and goes away; its opacity and rotation; the
/// order of its layer; and Delete Annotation. Each change is one step (`AnnotationCommands.change`); a slider being
/// dragged is a gesture, one step when it is let go. Colours come from the project's palette (`AnnotationPalette`) or
/// the system's colour panel.
struct AnnotationInspector: View {
    let model: EditorModel
    let annotation: Annotation
    let document: EditDocument

    private var id: String { annotation.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AnnotationHeader(annotation: annotation, document: document)
            AnchorSection(model: model, annotation: annotation, document: document)
            kindSection
            MotionSection(model: model, annotation: annotation)
            ArrangeSection(model: model)
            Button("Delete Annotation", role: .destructive) { model.deleteSelectedAnnotations() }
        }
    }

    @ViewBuilder
    private var kindSection: some View {
        let palette = AnnotationPalette.colors(of: document)
        switch annotation.kind {
        case let .text(text):
            TextSection(model: model, id: id, text: text, palette: palette, isCallout: false)
        case let .callout(callout):
            TextSection(model: model, id: id, text: callout.text, palette: palette, isCallout: true)
        case let .arrow(arrow):
            ArrowSection(model: model, id: id, arrow: arrow, palette: palette)
        case let .shape(shape):
            ShapeSection(model: model, id: id, shape: shape, palette: palette)
        case let .step(step):
            PanelSection {
                InspectorColorRow(title: "Color", color: step.color, palette: palette) { color in
                    model.changeAnnotation(id) { $0.kind = .step(StepAnnotation(color: color)) }
                }
                Text("Steps are numbered by themselves, in the order of the video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .image(image):
            ImageSection(model: model, id: id, image: image)
        case let .clip(clip):
            ClipSection(model: model, id: id, clip: clip)
        }
    }
}

// MARK: - What it is and when

/// Its kind's symbol and name ("Texto «Hola»", "Paso 2"), and when the output shows it.
private struct AnnotationHeader: View {
    let annotation: Annotation
    let document: EditDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(verbatim: name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: TimelineAnnotationItems.symbol(annotation.kind))
                    .foregroundStyle(.tint)
            }
            if let output = TimelineAnnotationItems.range(of: annotation.id, in: document) {
                Text("From \(Self.time(output.lowerBound)) to \(Self.time(output.upperBound))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("It isn't shown: its stretch was cut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var name: String {
        func quoted(_ string: String, _ kind: String) -> String {
            let line = string.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? kind : "\(kind) «\(line)»"
        }
        switch annotation.kind {
        case let .text(text):
            return quoted(text.string, String(localized: "Text"))
        case let .callout(callout):
            return quoted(callout.text.string, String(localized: "Callout"))
        case .arrow:
            return String(localized: "Arrow")
        case .shape:
            return String(localized: "Shape")
        case .step:
            let number = StepNumbering.numbers(in: document, timeMap: TimeMap(sequence: document.sequence))[annotation.id]
            return String(localized: "Step \(number ?? 1)", comment: "A step annotation and its number: a number in a circle")
        case .image:
            return String(localized: "Image")
        case .clip:
            return String(localized: "Clip")
        }
    }

    static func time(_ τ: Int64) -> String {
        Timecode.duration(Double(τ) / 1e9)
    }
}

/// Stick to the Recording and Whole Video (plan 3a decision 2): both off, the annotation is fixed on the output. A
/// change keeps it where it is seen (`EditorModel.setAnnotationAnchor`). A clip is only of the output; a stretch over two
/// takes or a clip with content cannot stick to the recording.
private struct AnchorSection: View {
    let model: EditorModel
    let annotation: Annotation
    let document: EditDocument

    private var isStuck: Bool {
        if case .content = annotation.anchor { true } else { false }
    }

    private var isWhole: Bool {
        if case .whole = annotation.anchor { true } else { false }
    }

    private var canStick: Bool {
        if case .clip = annotation.kind { return false }
        return isStuck || AnnotationCommands.setAnchor(document, id: annotation.id, to: .recording, rect: annotation.rect) != nil
    }

    var body: some View {
        let id = annotation.id
        PanelSection {
            Toggle(isOn: Binding(get: { isStuck }, set: { model.setAnnotationAnchor(id, to: $0 ? .recording : .output) })) {
                Label("Stick to the Recording", systemImage: "pin")
            }
            .disabled(!canStick)
            Toggle(isOn: Binding(get: { isWhole }, set: { model.setAnnotationAnchor(id, to: $0 ? .whole : .output) })) {
                Label("Whole Video", systemImage: "infinity")
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var note: LocalizedStringKey {
        if isStuck { return "It goes with the zoom, and away when its stretch is cut." }
        if isWhole { return "It's shown over the whole video." }
        if case .clip = annotation.kind { return "A clip always goes over the video, above the zoom." }
        return "It stays put over the video, above the zoom."
    }
}

// MARK: - Each kind

/// A text's or a speech bubble's words, style (not a bubble's: its shape is its own), font, weight, size, colour, fill and
/// alignment.
private struct TextSection: View {
    let model: EditorModel
    let id: String
    let text: TextAnnotation
    let palette: [RGBA]
    let isCallout: Bool

    private static let presets: [(TextPreset, LocalizedStringKey, String)] = [
        (.plain, "Plain", "character"), (.label, "Label", "capsule"), (.lowerThird, "Lower Third", "rectangle.bottomthird.inset.filled"),
        (.title, "Title", "textformat.size.larger"),
    ]
    private static let fonts: [(TextFont, LocalizedStringKey, Font.Design)] = [
        (.system, "System", .default), (.rounded, "Rounded", .rounded), (.serif, "Serif", .serif), (.mono, "Mono", .monospaced),
    ]

    var body: some View {
        PanelSection {
            TextField(
                "Text", text: Binding(get: { text.string }, set: { new in edit { $0.string = new } }), axis: .vertical
            )
            .lineLimit(1...5)
            .textFieldStyle(.roundedBorder)
            .panelTitled("Text")
            if !isCallout {
                InspectorTiles(title: "Style", selected: text.preset, choices: Self.presets.map { ($0.0, $0.1) }) { preset in
                    edit { $0 = AnnotationInspectorRules.restyled($0, to: preset) }
                } face: { preset, chosen in
                    Image(systemName: Self.presets.first { $0.0 == preset }?.2 ?? "character")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
            }
            InspectorTiles(title: "Font", selected: text.font, choices: Self.fonts.map { ($0.0, $0.1) }, nameLines: 1) { font in
                edit { $0.font = font }
            } face: { font, chosen in
                Text(verbatim: "Aa")
                    .font(.system(size: 15, weight: .semibold, design: Self.fonts.first { $0.0 == font }?.2 ?? .default))
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            Picker("Weight", selection: Binding(get: { text.weight }, set: { new in edit { $0.weight = new } })) {
                Text("Regular").tag(TextWeight.regular)
                Text("Semibold").tag(TextWeight.semibold)
                Text("Bold").tag(TextWeight.bold)
                Text("Heavy").tag(TextWeight.heavy)
            }
            .pickerStyle(.menu)
            InspectorSlider(
                title: "Size", model: model, value: text.size, range: 0.01...0.25, step: 0.005, format: InspectorFormat.percent
            ) { size in edit { $0.size = size } }
            InspectorColorRow(title: "Color", color: text.color, palette: palette) { color in edit { $0.color = color } }
            let defaultFill = TextAnnotation.defaultFill(for: isCallout ? .label : text.preset) ?? RGBA(0, 0, 0, 0.7)
            InspectorFillRow(fill: text.fill, palette: palette, whenOn: defaultFill) { fill in edit { $0.fill = fill } }
            Picker("Alignment", selection: Binding(get: { text.align }, set: { new in edit { $0.align = new } })) {
                Image(systemName: "text.alignleft").accessibilityLabel(Text("Left")).tag(TextAlign.leading)
                Image(systemName: "text.aligncenter").accessibilityLabel(Text("text.center")).tag(TextAlign.center)
                Image(systemName: "text.alignright").accessibilityLabel(Text("Right")).tag(TextAlign.trailing)
            }
            .pickerStyle(.segmented)
            .panelTitled("Alignment")
        }
    }

    /// `edit` made to the text of the annotation, a text's or a speech bubble's.
    private func edit(_ edit: (inout TextAnnotation) -> Void) {
        model.changeAnnotation(id) { annotation in
            switch annotation.kind {
            case var .text(text):
                edit(&text)
                annotation.kind = .text(text)
            case var .callout(callout):
                edit(&callout.text)
                annotation.kind = .callout(callout)
            default:
                break
            }
        }
    }
}

/// An arrow's colour, width, head and curve.
private struct ArrowSection: View {
    let model: EditorModel
    let id: String
    let arrow: ArrowAnnotation
    let palette: [RGBA]

    var body: some View {
        PanelSection {
            InspectorColorRow(title: "Color", color: arrow.color, palette: palette) { color in edit { $0.color = color } }
            InspectorSlider(
                title: "Width", model: model, value: arrow.width, range: 0.001...0.03, step: 0.0005, format: InspectorFormat.percent
            ) { width in edit { $0.width = width } }
            Picker("Head", selection: Binding(get: { arrow.head }, set: { head in edit { $0.head = head } })) {
                Text("head.filled").tag(ArrowHead.filled)
                Text("head.open").tag(ArrowHead.open)
                Text("head.none").tag(ArrowHead.none)
            }
            .pickerStyle(.segmented)
            .panelTitled("Head")
            InspectorSlider(
                title: "Curve", model: model, value: arrow.curve, range: -1...1, step: 0.05, format: InspectorFormat.signedPercent
            ) { curve in edit { $0.curve = curve } }
        }
    }

    private func edit(_ edit: (inout ArrowAnnotation) -> Void) {
        model.changeAnnotation(id) { annotation in
            guard case var .arrow(arrow) = annotation.kind else { return }
            edit(&arrow)
            annotation.kind = .arrow(arrow)
        }
    }
}

/// A shape's kind, border, width and fill.
private struct ShapeSection: View {
    let model: EditorModel
    let id: String
    let shape: ShapeAnnotation
    let palette: [RGBA]

    private static let shapes: [(AnnotationShape, LocalizedStringKey, String)] = [
        (.rect, "Rectangle", "rectangle"), (.roundedRect, "Rounded Rectangle", "app"), (.ellipse, "Ellipse", "circle"),
    ]

    var body: some View {
        PanelSection {
            InspectorTiles(title: "Shape", selected: shape.shape, choices: Self.shapes.map { ($0.0, $0.1) }) { kind in
                edit { $0.shape = kind }
            } face: { kind, chosen in
                Image(systemName: Self.shapes.first { $0.0 == kind }?.2 ?? "rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            InspectorColorRow(title: "Border", color: shape.stroke, palette: palette) { color in edit { $0.stroke = color } }
            InspectorSlider(
                title: "Width", model: model, value: shape.width, range: 0.001...0.03, step: 0.0005, format: InspectorFormat.percent
            ) { width in edit { $0.width = width } }
            InspectorFillRow(fill: shape.fill, palette: palette, whenOn: RGBA(shape.stroke.r, shape.stroke.g, shape.stroke.b, 0.25)) {
                fill in edit { $0.fill = fill }
            }
        }
    }

    private func edit(_ edit: (inout ShapeAnnotation) -> Void) {
        model.changeAnnotation(id) { annotation in
            guard case var .shape(shape) = annotation.kind else { return }
            edit(&shape)
            annotation.kind = .shape(shape)
        }
    }
}

/// An image's fit, corners and shadow.
private struct ImageSection: View {
    let model: EditorModel
    let id: String
    let image: ImageAnnotation

    var body: some View {
        PanelSection {
            Picker("Image Fit", selection: Binding(get: { image.fit }, set: { fit in edit { $0.fit = fit } })) {
                Text("fit.fit").tag(ImageFit.fit)
                Text("fit.fill").tag(ImageFit.fill)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            InspectorSlider(
                title: "Corners", model: model, value: image.corner, range: 0...0.5, step: 0.01, format: InspectorFormat.percent
            ) { corner in edit { $0.corner = corner } }
            Toggle("Shadow", isOn: Binding(get: { image.shadow }, set: { on in edit { $0.shadow = on } }))
        }
    }

    private func edit(_ edit: (inout ImageAnnotation) -> Void) {
        model.changeAnnotation(id) { annotation in
            guard case var .image(image) = annotation.kind else { return }
            edit(&image)
            annotation.kind = .image(image)
        }
    }
}

/// A clip's sound (its volume, Mute; a note when its file has none), corners and shadow.
private struct ClipSection: View {
    let model: EditorModel
    let id: String
    let clip: ClipAnnotation

    @State private var info: MediaInfo?

    var body: some View {
        let silent = info.map { !$0.hasAudio } ?? false
        PanelSection {
            InspectorSlider(
                title: "Volume", model: model, value: clip.volume, range: ContentClipCommands.volumeRange, step: 1,
                format: InspectorFormat.decibels
            ) { volume in edit { $0.volume = volume } }
            .disabled(clip.muted || silent)
            Toggle("Mute", isOn: Binding(get: { clip.muted }, set: { on in edit { $0.muted = on } }))
                .disabled(silent)
            if silent {
                PanelNote("This clip has no sound.", symbol: "speaker.slash")
            }
            InspectorSlider(
                title: "Corners", model: model, value: clip.corner, range: 0...0.5, step: 0.01, format: InspectorFormat.percent
            ) { corner in edit { $0.corner = corner } }
            Toggle("Shadow", isOn: Binding(get: { clip.shadow }, set: { on in edit { $0.shadow = on } }))
        }
        .task(id: clip.asset) { info = await model.mediaInfo(of: clip.asset) }
    }

    private func edit(_ edit: (inout ClipAnnotation) -> Void) {
        model.changeAnnotation(id) { annotation in
            guard case var .clip(clip) = annotation.kind else { return }
            edit(&clip)
            annotation.kind = .clip(clip)
        }
    }
}

// MARK: - Motion, look and order

/// How it comes in (None, Fade, Pop; Draw for an arrow or a shape) and goes away (None, Fade), its opacity and its
/// rotation (not an arrow's or a speech bubble's, which their points place).
private struct MotionSection: View {
    let model: EditorModel
    let annotation: Annotation

    var body: some View {
        let id = annotation.id
        let entrances = AnnotationInspectorRules.entrances(for: annotation.kind)
        PanelSection {
            HStack(alignment: .top, spacing: 10) {
                Picker("Entrance", selection: Binding(get: { annotation.enter }, set: { new in model.changeAnnotation(id) { $0.enter = new } })) {
                    ForEach(entrances, id: \.self) { enter in
                        Text(Self.name(enter)).tag(enter)
                    }
                }
                .pickerStyle(.menu)
                .panelTitled("Entrance")
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("Exit", selection: Binding(get: { annotation.exit }, set: { new in model.changeAnnotation(id) { $0.exit = new } })) {
                    Text("motion.none").tag(AnnotationExit.none)
                    Text("Fade").tag(AnnotationExit.fade)
                }
                .pickerStyle(.menu)
                .panelTitled("Exit")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            InspectorSlider(
                title: "Opacity", model: model, value: annotation.opacity, range: 0...1, step: 0.01, format: InspectorFormat.percent
            ) { opacity in model.changeAnnotation(id) { $0.opacity = opacity } }
            if AnnotationInspectorRules.rotates(annotation.kind) {
                InspectorSlider(
                    title: "Rotation", model: model, value: annotation.rotation, range: -180...180, step: 1, format: InspectorFormat.degrees
                ) { degrees in model.changeAnnotation(id) { $0.rotation = degrees } }
            }
        }
    }

    private static func name(_ enter: AnnotationEnter) -> LocalizedStringKey {
        switch enter {
        case .none: "motion.none"
        case .fade: "Fade"
        case .pop: "Pop"
        case .draw: "Draw"
        }
    }
}

/// Bring Forward, Send Backward, Bring to Front and Send to Back (⌘] ⌘[ ⌥⌘] ⌥⌘[), each off where it changes nothing.
private struct ArrangeSection: View {
    let model: EditorModel

    private static let moves: [(AnnotationCommands.LayerMove, LocalizedStringKey, String)] = [
        (.forward, "Bring Forward", "square.2.layers.3d.top.filled"), (.backward, "Send Backward", "square.2.layers.3d.bottom.filled"),
        (.front, "Bring to Front", "square.3.layers.3d.top.filled"), (.back, "Send to Back", "square.3.layers.3d.bottom.filled"),
    ]

    var body: some View {
        let possible = model.possibleLayerMoves
        PanelSection("Arrange") {
            HStack(spacing: 6) {
                ForEach(Self.moves, id: \.0) { move, title, symbol in
                    Button {
                        model.reorderSelectedAnnotation(move)
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, minHeight: 22)
                    }
                    .disabled(!possible.contains(move))
                    .help(Text(title))
                    .accessibilityLabel(Text(title))
                }
            }
        }
    }
}

// MARK: - The controls

/// How the inspector writes its numbers, in the user's language.
enum InspectorFormat {
    /// A fraction as a percentage with up to one decimal: "5 %", "0,6 %".
    static func percent(_ value: Double) -> String {
        (value * 100).formatted(.number.precision(.fractionLength(0...1))) + " %"
    }

    /// −1…1 as a percentage: "−40 %", "0 %", "+25 %".
    static func signedPercent(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
        return (percent > 0 ? "+" : "") + percent.formatted() + " %"
    }

    static func degrees(_ value: Double) -> String {
        Int(value.rounded()).formatted() + "°"
    }

    static func decibels(_ value: Double) -> String {
        let db = Int(value.rounded())
        return (db > 0 ? "+" : "") + db.formatted() + " dB"
    }

    /// "3 s", "2,5 s".
    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + " s"
    }
}

/// A slider over decimals whose value the document keeps (a size, a width, a curve): dragging it is a gesture of the
/// model (the preview follows, one step when it is let go); an arrow key is a step of its own, which the session joins
/// with the next ones of a burst into one undo. Its value snaps to `step` and reads as `format` says ("Tamaño, 5 %").
struct InspectorSlider: View {
    let title: LocalizedStringKey
    let model: EditorModel
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let set: (Double) -> Void

    @State private var dragged: Double?

    var body: some View {
        let shown = dragged ?? min(max(value, range.lowerBound), range.upperBound)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: format(shown))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { shown },
                    set: { new in
                        let snapped = min(max((new / step).rounded() * step, range.lowerBound), range.upperBound)
                        guard abs(snapped - shown) > step / 1000 else { return }
                        dragged = snapped
                        set(snapped)
                    }),
                in: range,
                onEditingChanged: { editing in
                    if editing {
                        model.beginGesture()
                    } else {
                        model.endGesture()
                        dragged = nil
                    }
                }
            )
            .labelsHidden()
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: format(shown)))
        }
        // A keyboard step is not a drag: once the document has it, the slider shows the document's.
        .onChange(of: value) { _, _ in
            if !model.isGesturing { dragged = nil }
        }
    }
}

/// A colour of the inspector (plan 3a decision 18): its title with the system's colour well, and the palette
/// (`AnnotationPalette.colors(of:)`: eight fixed ones, then those the project uses) as swatches, the one chosen ringed.
struct InspectorColorRow: View {
    let title: LocalizedStringKey
    let color: RGBA
    let palette: [RGBA]
    let set: (RGBA) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                ColorPicker(
                    title, selection: Binding(get: { color.color }, set: { set(RGBA(picked: $0, opacity: false)) }), supportsOpacity: false
                )
                .labelsHidden()
            }
            InspectorSwatches(chosen: color, palette: palette, title: title, set: set)
        }
    }
}

/// A fill that can be none (a text's background, a shape's inside): a switch with the colour well beside it, and with it
/// on, the palette. Turned on, it is `whenOn`; a swatch keeps the fill's opacity (a label's black at 70 %).
struct InspectorFillRow: View {
    let fill: RGBA?
    let palette: [RGBA]
    let whenOn: RGBA
    let set: (RGBA?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Fill", isOn: Binding(get: { fill != nil }, set: { set($0 ? whenOn : nil) }))
                Spacer(minLength: 8)
                if let fill {
                    ColorPicker(
                        "Fill", selection: Binding(get: { fill.color }, set: { set(RGBA(picked: $0, opacity: true)) }), supportsOpacity: true
                    )
                    .labelsHidden()
                }
            }
            if let fill {
                InspectorSwatches(chosen: fill, palette: palette, title: "Fill") { color in
                    set(RGBA(color.r, color.g, color.b, fill.a))
                }
            }
        }
    }
}

/// The palette's swatches, in rows of nine, the one of `chosen`'s colour (whatever its opacity) ringed. VoiceOver reads
/// each by its name ("Rojo"), a project's colour by its place ("Color del proyecto 2").
private struct InspectorSwatches: View {
    let chosen: RGBA
    let palette: [RGBA]
    let title: LocalizedStringKey
    let set: (RGBA) -> Void

    /// Swatches a row.
    private static let perRow = 9

    var body: some View {
        // Not lazy: a few swatches, all made at once (VoiceOver reads them all, wherever the panel is scrolled).
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: palette.count, by: Self.perRow)), id: \.self) { first in
                HStack(spacing: 6) {
                    ForEach(first..<min(first + Self.perRow, palette.count), id: \.self) { index in
                        swatch(index)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private func swatch(_ index: Int) -> some View {
        let swatch = palette[index]
        let isChosen = Self.same(swatch, chosen)
        return Button {
            set(swatch)
        } label: {
            Circle()
                .fill(swatch.color)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .overlay {
                    if isChosen { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-3) }
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: Self.name(index)))
        .accessibilityLabel(Text(verbatim: Self.name(index)))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private static func same(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 1e-4 && abs(a.g - b.g) < 1e-4 && abs(a.b - b.b) < 1e-4
    }

    /// The fixed colours' names, in `AnnotationPalette.fixed`'s order; the project's by their place after them.
    private static func name(_ index: Int) -> String {
        switch index {
        case 0: String(localized: "White")
        case 1: String(localized: "Black")
        case 2: String(localized: "Red")
        case 3: String(localized: "Orange")
        case 4: String(localized: "Yellow")
        case 5: String(localized: "Green")
        case 6: String(localized: "Blue")
        case 7: String(localized: "Purple")
        default:
            String(
                format: String(localized: "Project Color %lld", comment: "A colour of the annotation palette the project uses: its place"),
                index - AnnotationPalette.fixed.count + 1)
        }
    }
}

/// A row of choices as tiles (a text's style and font, a shape, a title card's style and background): each its face (a
/// symbol, "Aa" in its font) over its name; the chosen one ringed, the ring moving by `Motion.selector` (a fade with
/// Reduce Motion). VoiceOver reads the group's title, then each choice, the chosen one selected.
struct InspectorTiles<Value: Hashable, Face: View>: View {
    let title: LocalizedStringKey
    let selected: Value
    let choices: [(Value, LocalizedStringKey)]
    /// The lines a name may take: 2 for names of two words ("Tercio inferior"), 1 for one word, which shrinks rather
    /// than breaks ("Redondeada").
    var nameLines = 2
    let choose: (Value) -> Void
    @ViewBuilder let face: (Value, Bool) -> Face

    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                    tile(choice.0, name: choice.1)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private func tile(_ value: Value, name: LocalizedStringKey) -> some View {
        let isSelected = value == selected
        return Button {
            guard !isSelected else { return }
            withAnimation(.panel(Motion.selector, reduceMotion: reduceMotion)) { choose(value) }
        } label: {
            VStack(spacing: 4) {
                face(value, isSelected)
                    .frame(height: 18)
                Text(name)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nameLines)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 2)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .matchedGeometryEffect(id: "ring", in: ring)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(name))
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension RGBA {
    /// The colour picked in the system's colour panel, in sRGB; opaque unless `opacity`.
    init(picked color: Color, opacity: Bool) {
        let picked = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            Double(picked.redComponent), Double(picked.greenComponent), Double(picked.blueComponent),
            opacity ? Double(picked.alphaComponent) : 1)
    }
}
