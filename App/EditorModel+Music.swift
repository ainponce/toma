// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Editing
import Export
import ProjectFormat
import UniformTypeIdentifiers

/// The music of the document (phase 3 design §7.4 and §7.5, plan 3c decisions 15 to 17): each change one step of
/// `MusicCommands`. The timeline's drags make theirs from the document the drag started from (`TimelineMusicDrags`); the
/// panel's sliders are gestures, as its other bars are.
extension EditorModel {
    /// Where "Add Music…" puts a new piece now (`MusicCommands.roomForNew`): all the video without music, otherwise the
    /// free gap the playhead is in, if it lasts 1 s; `nil` when there is no room ("No room for more music.").
    var musicRoom: Range<Int64>? {
        guard let document else { return nil }
        return MusicCommands.roomForNew(document, atOutput: playheadNanoseconds, timeMap: TimeMap(sequence: document.sequence))
    }

    /// The piece of music under the playhead, the one "Replace Music…" changes when nothing is selected.
    var musicUnderPlayhead: String? {
        guard let document else { return nil }
        let τ = playheadNanoseconds
        return MusicCommands.shownItems(document, timeMap: TimeMap(sequence: document.sequence))
            .first { $0.output.contains(τ) || $0.output.upperBound == τ }?.id
    }

    /// The selected piece of music, if one is.
    var selectedMusic: String? {
        if case let .musicItem(id)? = selection { id } else { nil }
    }

    /// The piece of music `source` in the room for a new one at output instant `atOutput` (the playhead's, by default),
    /// selected afterwards; whether it went in.
    @discardableResult
    func addMusic(source: String, atOutput: Int64? = nil) -> Bool {
        guard canEdit, let document,
            let step = MusicCommands.add(
                document, source: source, atOutput: atOutput ?? playheadNanoseconds, timeMap: TimeMap(sequence: document.sequence),
                makeID: Self.newID),
            perform(step) != .refused
        else { return false }
        selection = .musicItem(step.target)
        return true
    }

    /// A sound file of the user's copied into the project (`EditSession.importAsset(_:kind: .audio)`, off the main thread),
    /// then a piece of music at `atOutput` (the playhead's, by default), or the source of piece `replacing`. "Couldn't open
    /// the file." for one that does not play; the session says why one could not be saved.
    func importMusic(_ url: URL, atOutput: Int64? = nil, replacing: String? = nil) {
        guard canEdit, let session = panelSession else { return }
        let τ = atOutput ?? playheadNanoseconds
        Task {
            let outcome = await session.importAsset(url, kind: .audio)
            switch outcome {
            case let .imported(path):
                if let replacing {
                    replaceMusic(id: replacing, source: path)
                } else if !addMusic(source: path, atOutput: τ) {
                    NSSound.beep()
                }
            case .notPlayable, .notAnImage, .notALUT:
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Couldn't open the file.")
                if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            case .saveFailed, .notEditable:
                break
            }
        }
    }

    /// "Choose a File…" and "Import Audio…": an M4A, an MP3, a WAV, an AIFF or a CAF, for a new piece of music at
    /// `atOutput` (the playhead's, by default) or for the source of piece `replacing`.
    func chooseMusicFile(atOutput: Int64? = nil, replacing: String? = nil) {
        guard canEdit else { return }
        let panel = NSOpenPanel()
        let caf = UTType(filenameExtension: "caf")
        panel.allowedContentTypes = [UTType.mpeg4Audio, .mp3, .wav, .aiff] + (caf.map { [$0] } ?? [])
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            self?.importMusic(url, atOutput: atOutput, replacing: replacing)
        }
        if let window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    /// The playhead to output instant `τ`, as a click on the timeline puts it.
    func movePlayhead(toOutput τ: Int64) {
        scrub(toSeconds: Double(τ) / 1e9)
        endScrub()
    }

    /// "Replace Music…": piece `id` plays `source` instead (`music.change`).
    func replaceMusic(id: String, source: String) {
        changeMusic(id: id) { $0.source = source }
        selection = .musicItem(id)
    }

    /// Piece `id` changed by `edit` (its volume, fades, loop or source), held as `MusicCommands.change` holds it: a step
    /// of the gesture while one lasts (a slider being dragged), otherwise one of its own.
    func changeMusic(id: String, _ edit: (inout MusicItem) -> Void) {
        guard canEdit, let document, let step = MusicCommands.change(document, id: id, edit) else { return }
        if isGesturing { updateGesture(step) } else { perform(step) }
    }

    /// Piece `id` moved to start at output instant `toOutputStart`, as long as it is, between its neighbours.
    func moveMusic(id: String, toOutputStart: Int64) {
        guard canEdit, let document,
            let step = MusicCommands.move(document, id: id, toOutputStart: toOutputStart, timeMap: TimeMap(sequence: document.sequence))
        else { return }
        perform(step)
    }

    /// Edge `edge` of piece `id` to output instant `toOutput`; the start keeps the music in its place.
    func trimMusic(id: String, edge: ClipEdge, toOutput: Int64) {
        guard canEdit, let document,
            let step = MusicCommands.trim(document, id: id, edge: edge, toOutput: toOutput, timeMap: TimeMap(sequence: document.sequence))
        else { return }
        perform(step)
    }

    /// What piece `id` plays slid to `offset` ns into its file, without moving it.
    func slipMusic(id: String, offset: Int64) {
        guard canEdit, let document, let item = document.music.items.first(where: { $0.id == id }),
            let step = MusicCommands.slip(document, id: id, offset: offset, themeLength: musicLength(of: item.source))
        else { return }
        perform(step)
    }

    /// Takes piece `id` out.
    func deleteMusic(id: String) {
        guard canEdit, let document, let step = MusicCommands.delete(document, id: id) else { return }
        perform(step)
    }

    /// "Lower Music While Speaking" and its amount, attack and release, as a whole.
    func setDucking(_ ducking: Ducking) {
        guard canEdit, let document, let step = MusicCommands.setDucking(document, ducking) else { return }
        perform(step)
    }

    /// The length in ns of the file `source` plays, once it is in the caches (a theme's 2:00 even before).
    func musicLength(of source: String) -> Int64? {
        if MusicThemes.id(ofSource: source) != nil {
            return Int64(MusicThemes.loopFrames) * 1_000_000_000 / Int64(MusicFile.sampleRate)
        }
        return audio.shown.lengths[source]
    }
}
