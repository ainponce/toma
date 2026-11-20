// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Export
import SwiftUI

/// The list of the music library, in a popover from "Add Music…" or "Replace Music…" (plan 3c decision 16): the six
/// themes of `music-1`, each with its name, its style, its 2:00 and Play or Stop, then "Choose a File…". Playing one makes
/// it first if it is not in the library's cache ("Preparing…"), pauses the editor and stops the one heard before; choosing
/// one adds it (or makes the piece `replacing` play it) and closes the list. Closing the list stops what plays.
struct MusicLibraryPicker: View {
    let model: EditorModel
    /// The piece the choice replaces; `nil`: the choice is a new piece.
    let replacing: String?
    /// Closes the popover it is in, when that is not the panel's (`showsLibrary`).
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(MusicThemes.ids, id: \.self) { id in
                ThemeRow(model: model, id: id) { choose(id) }
            }
            Divider()
                .padding(.vertical, 4)
            Button("Choose a File…") {
                model.audio.showsLibrary = false
                close()
                model.chooseMusicFile(replacing: replacing)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .padding(8)
        .frame(width: 300)
        .onDisappear { model.audio.stopListening() }
    }

    private func choose(_ id: String) {
        model.audio.stopListening()
        model.audio.showsLibrary = false
        close()
        let source = MusicThemes.source(id)
        if let replacing {
            model.replaceMusic(id: replacing, source: source)
        } else {
            model.addMusic(source: source)
        }
    }
}

/// A theme of the list: Play or Stop, its name and style (a click chooses it), "Preparing…" while it is made to be heard,
/// and its length.
private struct ThemeRow: View {
    let model: EditorModel
    let id: String
    let choose: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "Stop" hearing a theme: Parar (not the recording's Detener).
    private static var stop: String {
        String(localized: "music.stop", comment: "The music library's list: stops the theme being heard (Stop)")
    }

    var body: some View {
        let name = EditorAudio.name(ofTheme: id), style = EditorAudio.style(ofTheme: id)
        let length = Timecode.duration(Double(MusicThemes.loopFrames) / 48_000)
        let heard = model.audio.listening == id
        HStack(spacing: 8) {
            Button {
                if heard { model.audio.stopListening() } else { model.audio.listen(to: id) }
            } label: {
                Image(systemName: heard ? "stop.fill" : "play.fill")
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .help(heard ? Text(Self.stop) : Text("Play"))
            .accessibilityLabel(heard ? Text(Self.stop) : Text("Play"))
            .accessibilityValue(Text(verbatim: name))
            Button(action: choose) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: name)
                            .font(.body.weight(.medium))
                        Text(verbatim: style)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if heard, model.audio.listeningPreparing {
                        ProgressView()
                            .controlSize(.small)
                        Text(verbatim: EditorAudio.preparingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: length)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(name), \(style), \(length)"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        }
        .onHover { hovering = $0 }
        .animation(.panel(Motion.hover, reduceMotion: reduceMotion), value: hovering)
    }
}
