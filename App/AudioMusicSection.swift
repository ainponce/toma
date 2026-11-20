// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Export
import ProjectFormat
import SwiftUI

/// The Music section of the Audio tab (phase 3 design §7.4 and §7.5, plan 3c decisions 15 to 17), under the tracks:
///
/// - "Add Music…" opens the library's list (`MusicLibraryPicker`) and "Import Audio…" a file of the user's; a new piece
///   covers the video, or the free gap the playhead is in. With no room, both are off ("No room for more music.") and
///   the inspector's "Replace Music…" changes the piece chosen, or the one under the playhead.
/// - The project's pieces in the order they play: the one chosen in the Music track is chosen here, and the other way
///   round; one being made says "Preparing…" with how far it is.
/// - The chosen piece (or the one under the playhead): its volume, its fades, whether it repeats, "Replace Music…" and
///   "Delete Music".
/// - "Lower Music While Speaking", with its amount, attack and release.
struct AudioMusicSection: View {
    let model: EditorModel

    var body: some View {
        if let document = model.document {
            let items = document.music.items.sorted { $0.start < $1.start }
            let room = model.musicRoom != nil
            PanelSection("Music") {
                if !items.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(items, id: \.id) { item in
                            MusicItemRow(model: model, item: item, isSelected: model.selectedMusic == item.id)
                        }
                    }
                }
                // Side by side when they fit whole (English), one under the other otherwise (Spanish is long).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { addButtons(room: room) }
                    VStack(alignment: .leading, spacing: 6) { addButtons(room: room) }
                }
                .popover(isPresented: Binding(get: { model.audio.showsLibrary }, set: { model.audio.showsLibrary = $0 }), arrowEdge: .bottom) {
                    MusicLibraryPicker(model: model, replacing: model.audio.libraryReplaces)
                }
                if !room, !items.isEmpty {
                    Text("No room for more music.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // The piece chosen in the track or the list, or else the one under the playhead (what "Replace Music…"
            // changes when there is no room for another, plan decision 15).
            if let id = model.selectedMusic ?? model.musicUnderPlayhead, let item = items.first(where: { $0.id == id }) {
                MusicItemInspector(model: model, item: item)
            }
            if !items.isEmpty {
                DuckingSection(model: model, ducking: document.music.ducking)
            }
        }
    }

    @ViewBuilder
    private func addButtons(room: Bool) -> some View {
        Button("Add Music…") { open(replacing: nil) }
            .disabled(!room)
            .fixedSize()
        Button("Import Audio…") { model.chooseMusicFile() }
            .disabled(!room)
            .fixedSize()
    }

    private func open(replacing: String?) {
        model.audio.libraryReplaces = replacing
        model.audio.showsLibrary = true
    }
}

/// A piece of the project's music in the section's list: its name, where it plays, and "Preparing…" while it is made.
private struct MusicItemRow: View {
    let model: EditorModel
    let item: MusicItem
    let isSelected: Bool

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let name = EditorAudio.name(ofSource: item.source)
        let preparing = model.audio.shown.preparing.contains(item.source)
        let end = min(item.end, model.document.map { TimeMap(sequence: $0.sequence).duration } ?? item.end)
        let span = Timecode.duration(Double(item.start) / 1e9) + "–" + Timecode.duration(Double(end) / 1e9)
        Button {
            model.selection = .musicItem(item.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: MusicThemes.id(ofSource: item.source) != nil ? "music.note" : "waveform")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(verbatim: name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if preparing {
                    ProgressView()
                        .controlSize(.mini)
                    Text(verbatim: EditorAudio.preparingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: span)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovering ? 0.06 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.panel(Motion.hover, reduceMotion: reduceMotion), value: hovering)
        .accessibilityLabel(Text(verbatim: preparing ? "\(name), \(EditorAudio.preparingText)" : "\(name), \(span)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The chosen piece: its volume (−48 to +6 dB, a gesture as the panel's bars are), its fades (each at most half the
/// piece), whether it repeats, the note of a file longer than 30 minutes, and Replace and Delete.
private struct MusicItemInspector: View {
    let model: EditorModel
    let item: MusicItem

    var body: some View {
        let id = item.id
        let half = Double(max(item.end - item.start, 0)) / 2 / 1e9
        let fades = 0...max(min(half, 10), 0.1)
        PanelSection {
            Text(verbatim: EditorAudio.name(ofSource: item.source))
                .font(.subheadline.weight(.semibold))
            if model.audio.shown.preparing.contains(item.source) {
                HStack(spacing: 6) {
                    if let progress = model.audio.shown.progress {
                        ProgressView(value: progress)
                            .frame(maxWidth: 120)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(verbatim: EditorAudio.preparingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            PanelSlider(
                title: "Volume", model: model, value: Int(max(item.gain, -48).rounded()), range: -48...6, unit: " dB"
            ) { value in
                model.changeMusic(id: id) { $0.gain = Double(value) }
            }
            PanelStepSlider(
                title: "Fade In", value: Double(item.fadeIn) / 1e9, range: fades, step: 0.1, format: Self.seconds
            ) { value in
                model.changeMusic(id: id) { $0.fadeIn = Int64((value * 1e9).rounded()) }
            }
            PanelStepSlider(
                title: "Fade Out", value: Double(item.fadeOut) / 1e9, range: fades, step: 0.1, format: Self.seconds
            ) { value in
                model.changeMusic(id: id) { $0.fadeOut = Int64((value * 1e9).rounded()) }
            }
            Toggle("Loop", isOn: Binding(get: { item.loop }, set: { on in model.changeMusic(id: id) { $0.loop = on } }))
            if model.audio.shown.capped.contains(item.source) {
                Text("Only the first 30 minutes are used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions(id) }
                VStack(alignment: .leading, spacing: 6) { actions(id) }
            }
        }
    }

    @ViewBuilder
    private func actions(_ id: String) -> some View {
        Button("Replace Music…") {
            model.audio.libraryReplaces = id
            model.audio.showsLibrary = true
        }
        .fixedSize()
        Button("Delete Music", role: .destructive) { model.deleteMusic(id: id) }
            .fixedSize()
    }

    /// "1 s", "0,5 s".
    @MainActor
    static func seconds(_ value: Double) -> String {
        TimelineFormat.number((value * 100).rounded() / 100) + " s"
    }
}

/// "Lower Music While Speaking" (on by default: −12 dB, 0,3 s and 0,8 s), with its amount (−24 to −3 dB), its attack
/// (0,1 to 1 s) and its release (0,2 to 2 s): each change one `music.ducking`.
private struct DuckingSection: View {
    let model: EditorModel
    let ducking: Ducking

    var body: some View {
        PanelSection {
            Toggle(
                "Lower Music While Speaking",
                isOn: Binding(get: { ducking.enabled }, set: { on in set { $0.enabled = on } }))
            Group {
                PanelStepSlider(
                    title: "Amount", value: ducking.amount, range: -24 ... -3, step: 1, format: { TimelineAudioItems.gainText($0) }
                ) { value in set { $0.amount = value } }
                PanelStepSlider(
                    title: "Attack", value: ducking.attack, range: 0.1...1, step: 0.05, format: MusicItemInspector.seconds
                ) { value in set { $0.attack = value } }
                PanelStepSlider(
                    title: "Release", value: ducking.release, range: 0.2...2, step: 0.1, format: MusicItemInspector.seconds
                ) { value in set { $0.release = value } }
            }
            .disabled(!ducking.enabled)
        }
    }

    private func set(_ edit: (inout Ducking) -> Void) {
        var next = ducking
        edit(&next)
        model.setDucking(next)
    }
}
