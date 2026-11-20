// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// The Annotations tab (phase 3 design §5.6, ⌘9; plan 3a decision 19): on top, Add, a button for each kind of annotation
/// (Image… and Clip… ask for the file); under it the inspector of what is selected, an annotation
/// (`AnnotationInspector`) or a clip with content (`ContentClipInspector`); and at the bottom Video, what goes into the
/// sequence: a title card at the playhead, at the start or at the end, a frozen frame and an imported clip. The buttons
/// that add stay where they are when what they add appears, so a second click adds another.
struct AnnotationsTab: View {
    let model: EditorModel

    /// The name of the file of Image…, Clip… or Clip in the Sequence… while it is copied into the project.
    @State private var importingOverlay: String?
    @State private var importingClip: String?

    var body: some View {
        if let document = model.document {
            VStack(alignment: .leading, spacing: 18) {
                AddAnnotationSection(model: model) { importingOverlay = $0 }
                if let importingOverlay { ImportingRow(name: importingOverlay) }
                selected(in: document)
                Divider()
                VideoSection(model: model) { importingClip = $0 }
                if let importingClip { ImportingRow(name: importingClip) }
            }
        }
    }

    /// The inspector of what is selected; with nothing of the tab's, what it is for.
    @ViewBuilder
    private func selected(in document: EditDocument) -> some View {
        switch model.selection {
        case let .annotations(ids)? where ids.count == 1:
            if let annotation = document.annotations.items.first(where: { ids.contains($0.id) }) {
                Divider()
                AnnotationInspector(model: model, annotation: annotation, document: document)
                    .id(annotation.id)
            }
        case let .annotations(ids)? where ids.count > 1:
            Divider()
            SeveralAnnotations(model: model, count: ids.count)
        case let .clips(ids)? where ids.count == 1:
            if let clip = document.sequence.first(where: { ids.contains($0.id) }), clip.content != nil {
                Divider()
                ContentClipInspector(model: model, clip: clip, document: document)
                    .id(clip.id)
            } else {
                hint
            }
        default:
            hint
        }
    }

    private var hint: some View {
        Text("Select an annotation on the preview or the timeline to change it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Add: Text, Arrow, Shape, Callout and Step at the playhead (`EditorModel.addAnnotation`), and Image… and Clip…, a file
/// over the video (`EditorModel.chooseOverlay`), as tiles with their symbols (plan 3a decision 20).
private struct AddAnnotationSection: View {
    let model: EditorModel
    let importing: @MainActor (String?) -> Void

    var body: some View {
        PanelSection("Add") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                AddTile(title: "Text", symbol: "textformat") { model.addAnnotation(.text) }
                AddTile(title: "Arrow", symbol: "arrow.up.right") { model.addAnnotation(.arrow) }
                AddTile(title: "Shape", symbol: "square.on.circle") { model.addAnnotation(.shape) }
                AddTile(title: "Callout", symbol: "bubble.left") { model.addAnnotation(.callout) }
                AddTile(title: "Step", symbol: "1.circle") { model.addAnnotation(.step) }
                AddTile(title: "Image…", symbol: "photo") { model.chooseOverlay(.image, importing: importing) }
                AddTile(title: "Clip…", symbol: "film") { model.chooseOverlay(.video, importing: importing) }
            }
            .disabled(!model.canEdit)
        }
    }
}

/// A button of Add: its symbol over its name, on a soft tile that washes under the pointer.
private struct AddTile: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(height: 18)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(InspectorTileStyle(isSelected: false))
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

/// Video: Add Title Card at the playhead (and at the start or at the end with one click), Freeze Frame and Clip in the
/// Sequence… (phase 3 design §5.2–§5.4).
private struct VideoSection: View {
    let model: EditorModel
    let importing: @MainActor (String?) -> Void

    var body: some View {
        PanelSection("Video") {
            Button {
                model.addTitleCard(at: .output(model.playheadNanoseconds))
            } label: {
                Label("Add Title Card", systemImage: "character.textbox")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            HStack(spacing: 8) {
                Button {
                    model.addTitleCard(at: .start)
                } label: {
                    Label("At the Start", systemImage: "arrow.left.to.line")
                        .frame(maxWidth: .infinity)
                }
                .help(Text("Add a title card at the start of the video"))
                .accessibilityLabel(Text("Add a title card at the start of the video"))
                Button {
                    model.addTitleCard(at: .end)
                } label: {
                    Label("At the End", systemImage: "arrow.right.to.line")
                        .frame(maxWidth: .infinity)
                }
                .help(Text("Add a title card at the end of the video"))
                .accessibilityLabel(Text("Add a title card at the end of the video"))
            }
            FreezeFrameButton(model: model)
            Button {
                model.chooseFile(.video) { url in
                    importing(url.lastPathComponent)
                    Task {
                        await model.addMediaToSequence(from: url, at: .output(model.playheadNanoseconds))
                        importing(nil)
                    }
                }
            } label: {
                Label("Clip in the Sequence…", systemImage: "film")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .disabled(!model.canEdit)
    }
}

/// Freeze Frame, off where the playhead is inside a clip with content (nothing is frozen there). Its own view: while
/// paused it follows the playhead, and only it is drawn again when the playhead moves; while playing it does not follow
/// it (a click then freezes the frame shown, or beeps).
private struct FreezeFrameButton: View {
    let model: EditorModel

    var body: some View {
        let enabled = model.isPlaying || model.canFreezeAtPlayhead
        Button {
            model.freezeFrame()
        } label: {
            Label("Freeze Frame", systemImage: "snowflake")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(!enabled)
    }
}

/// "Importing «name»…" with a spinning bar, while a file is copied into the project.
private struct ImportingRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(format: String(localized: "Importing “%@”…"), name))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Several annotations selected: how many, Duplicate and Delete.
private struct SeveralAnnotations: View {
    let model: EditorModel
    let count: Int

    var body: some View {
        PanelSection {
            Text("\(count) Annotations Selected", comment: "The Annotations tab with several annotations selected: how many")
                .font(.headline)
            HStack(spacing: 8) {
                Button("Duplicate") { model.duplicateSelectedAnnotations() }
                Button("Delete", role: .destructive) { model.deleteSelectedAnnotations() }
            }
        }
    }
}

/// A tile of the tab and its inspector: a soft fill, a wash while the pointer is over it or it is pressed, and, chosen, the
/// accent's wash and border.
struct InspectorTileStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        InspectorTileLabel(configuration: configuration, isSelected: isSelected)
    }
}

private struct InspectorTileLabel: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.45)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.08 : 0.05))
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
                }
            }
            .onHover { hovering = $0 }
            .animation(.panel(Motion.hover, reduceMotion: reduceMotion), value: hovering)
    }
}
