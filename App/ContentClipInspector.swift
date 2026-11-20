// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// The inspector of the one clip with content selected (phase 3 design §5.2–§5.4, plan 3a decisions 10–12 and 19): what
/// it is and where the output shows it; a title card's title and subtitle, its four styles, its background (the project's
/// Stage, a colour or the blurred frame of the take there), its text's colour and its duration; a frozen frame's duration;
/// an imported clip's volume, speed and the stretch of its file it plays. Each change is one step (`ContentClipCommands`);
/// the volume's slider is a gesture, one step when it is let go. Delete takes the clip out of the sequence.
struct ContentClipInspector: View {
    let model: EditorModel
    let clip: Clip
    let document: EditDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ContentClipHeader(clip: clip, document: document)
            switch clip.content {
            case let .card(card, _)?:
                TitleCardSection(model: model, id: clip.id, card: card, palette: AnnotationPalette.colors(of: document))
                DurationRow(model: model, id: clip.id, duration: TimeMap.outputDuration(of: clip))
            case .freeze?:
                PanelSection {
                    DurationRow(model: model, id: clip.id, duration: TimeMap.outputDuration(of: clip))
                    Text("It shows the take still at that instant, with everything it has there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case let .media(media)?:
                MediaClipSection(model: model, id: clip.id, media: media)
            case nil:
                EmptyView()
            }
            Button("Delete", role: .destructive) { _ = model.deleteSelection() }
        }
    }
}

/// Its kind's symbol and name ("Placa «Intro»", "Cuadro congelado", "Clip importado") and where the output shows it.
private struct ContentClipHeader: View {
    let clip: Clip
    let document: EditDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(verbatim: name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
            }
            if let output {
                Text("From \(Self.time(output.lowerBound)) to \(Self.time(output.upperBound))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch clip.content {
        case .freeze?: "snowflake"
        case .card?: "character.textbox"
        case .media?, nil: "film"
        }
    }

    private var name: String {
        switch clip.content {
        case .freeze?:
            return String(localized: "Frozen Frame")
        case .card?:
            let kind = String(localized: "Title Card")
            return ContentClipTrackRules.label(of: clip).map { "\(kind) «\($0)»" } ?? kind
        case .media?, nil:
            return String(localized: "Imported Clip")
        }
    }

    /// Where the output shows it, `[O_k, O_k + D_k)`.
    private var output: Range<Int64>? {
        let map = TimeMap(sequence: document.sequence)
        guard let k = document.sequence.firstIndex(where: { $0.id == clip.id }), k < map.clipOutputStarts.count else { return nil }
        let start = map.clipOutputStarts[k]
        let end = k + 1 < map.clipOutputStarts.count ? map.clipOutputStarts[k + 1] : map.duration
        return start < end ? start..<end : nil
    }

    static func time(_ τ: Int64) -> String {
        Timecode.duration(Double(τ) / 1e9)
    }
}

/// A title card's title and subtitle, style, background (and its colour), and its text's colour (decision 10).
private struct TitleCardSection: View {
    let model: EditorModel
    let id: String
    let card: TitleCard
    let palette: [RGBA]

    /// What is behind the card, without its colour.
    private enum Backdrop: Hashable { case stage, color, blurredFrame }

    private static let styles: [(TitleCardStyle, LocalizedStringKey, String)] = [
        (.centered, "Centered", "text.aligncenter"), (.leading, "Leading", "text.alignleft"),
        (.large, "Large", "textformat.size.larger"), (.minimal, "Minimal", "textformat.size.smaller"),
    ]
    private static let backdrops: [(Backdrop, LocalizedStringKey, String)] = [
        (.stage, "Stage", "photo.artframe"), (.color, "Color", "paintpalette"), (.blurredFrame, "Blurred Frame", "aqi.medium"),
    ]

    private var backdrop: Backdrop {
        switch card.background {
        case .stage: .stage
        case .color: .color
        case .blurredFrame: .blurredFrame
        }
    }

    var body: some View {
        PanelSection {
            TextField(
                "Title", text: Binding(get: { card.title }, set: { new in model.changeTitleCard(id) { $0.title = new } }), axis: .vertical
            )
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
            .panelTitled("Title")
            TextField(
                "Subtitle", text: Binding(get: { card.subtitle }, set: { new in model.changeTitleCard(id) { $0.subtitle = new } }),
                axis: .vertical
            )
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
            .panelTitled("Subtitle")
            InspectorTiles(title: "Style", selected: card.style, choices: Self.styles.map { ($0.0, $0.1) }) { style in
                model.changeTitleCard(id) { $0.style = style }
            } face: { style, chosen in
                Image(systemName: Self.styles.first { $0.0 == style }?.2 ?? "text.aligncenter")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            InspectorTiles(title: "Background", selected: backdrop, choices: Self.backdrops.map { ($0.0, $0.1) }) { chosen in
                model.changeTitleCard(id) { card in
                    switch chosen {
                    case .stage: card.background = .stage
                    case .color: card.background = .color(RGBA(0, 0, 0, 1))
                    case .blurredFrame: card.background = .blurredFrame
                    }
                }
            } face: { chosen, isChosen in
                Image(systemName: Self.backdrops.first { $0.0 == chosen }?.2 ?? "photo.artframe")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            if case let .color(color) = card.background {
                InspectorColorRow(title: "Background Color", color: color, palette: palette) { new in
                    model.changeTitleCard(id) { $0.background = .color(new) }
                }
            }
            InspectorColorRow(title: "Text Color", color: card.textColor, palette: palette) { new in
                model.changeTitleCard(id) { $0.textColor = new }
            }
        }
    }
}

/// The length of a frozen frame or a title card, 0.1 to 60 s (`ContentClipCommands.setDuration`): typed in seconds in
/// the user's language ("2,5"), or half a second at a time with the stepper. What cannot be read as seconds goes back to
/// what it was.
private struct DurationRow: View {
    let model: EditorModel
    let id: String
    /// What it lasts in the output, ns.
    let duration: Int64

    @State private var typed = ""
    @FocusState private var focused: Bool

    private var shown: String {
        TimelineFormat.number((Double(duration) / 1e7).rounded() / 100)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Duration")
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            TextField("Duration", text: $typed)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel(Text("Duration"))
                .accessibilityValue(Text(verbatim: "\(shown) s"))
            Text(verbatim: "s")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Stepper("Duration") {
                set(Double(duration) / 1e9 + 0.5)
            } onDecrement: {
                set(Double(duration) / 1e9 - 0.5)
            }
            .labelsHidden()
        }
        .onAppear { typed = shown }
        .onChange(of: duration) { _, _ in typed = shown }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        guard typed != shown, let new = ContentClipTrackRules.duration(fromTyped: typed) else {
            typed = shown
            return
        }
        model.setContentDuration(id, new)
        typed = shown
    }

    private func set(_ seconds: Double) {
        let held = min(max(seconds, 0.1), 60)
        model.setContentDuration(id, Int64((held * 1e9).rounded()))
    }
}

/// An imported clip in the sequence: its volume (off for a file without sound), its speed and the stretch of its file it
/// plays (trimmed on the Video track).
private struct MediaClipSection: View {
    let model: EditorModel
    let id: String
    let media: MediaClip

    @State private var info: MediaInfo?

    var body: some View {
        let silent = info.map { !$0.hasAudio } ?? false
        let speed = ClipSpeed.clamped(media.speed)
        let presets = SequenceCommands.speedPresets
        let speeds = presets.contains(speed) ? presets : (presets + [speed]).sorted()
        PanelSection {
            InspectorSlider(
                title: "Volume", model: model, value: media.volume, range: ContentClipCommands.volumeRange, step: 1,
                format: InspectorFormat.decibels
            ) { volume in model.setMediaClip(id, volume: volume) }
            .disabled(silent)
            if silent {
                PanelNote("This clip has no sound.", symbol: "speaker.slash")
            }
            Picker("Speed", selection: Binding(get: { speed }, set: { model.setMediaClip(id, speed: $0) })) {
                ForEach(speeds, id: \.self) { value in
                    Text(verbatim: TimelineFormat.multiplier(value)).tag(value)
                }
            }
            .pickerStyle(.menu)
            Text(
                "From \(Self.time(media.start)) to \(Self.time(media.end)) of the file",
                comment: "An imported clip in the sequence: the stretch of its file it plays")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: media.asset) { info = await model.mediaInfo(of: media.asset) }
    }

    private static func time(_ ns: Int64) -> String {
        Timecode.duration(Double(max(ns, 0)) / 1e9)
    }
}
