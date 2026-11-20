// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat
import UniformTypeIdentifiers

/// What the Annotations tab and the Edit menu do with the clips with content (phase 3 design §5.2–§5.4, plan 3a Task
/// A14): a frozen frame and a title card at the playhead, a title card at the start or the end, an imported clip into the
/// sequence, and the changes the inspector makes to one. Each is one step of `ContentClipCommands`; the one made is the
/// one selected.
extension EditorModel {
    /// The files the open panels of the tab offer: an image (PNG, JPEG, HEIC, and TIFF, GIF and PDF converted as they are
    /// imported, `AssetImport.importableImageExtensions`) and a clip (MOV, MP4, M4V).
    enum ImportedFile {
        case image, video

        var contentTypes: [UTType] {
            let extensions = self == .image ? AssetImport.importableImageExtensions : ContentClipTrackRules.videoExtensions.sorted()
            var types: [UTType] = []
            for name in extensions {
                guard let type = UTType(filenameExtension: name), !types.contains(type) else { continue }
                types.append(type)
            }
            return types
        }
    }

    /// Edit ▸ Freeze Frame and the tab's: a frozen frame of the instant at the playhead (`ContentClipCommands.freeze`),
    /// selected. Inside a clip with content, or between two, nothing is frozen and the system beeps.
    func freezeFrame() {
        guard canEdit, !isGesturing, let document,
            let step = ContentClipCommands.freeze(document, atOutput: playheadNanoseconds, makeID: Self.newID)
        else {
            NSSound.beep()
            return
        }
        if perform(step) != .refused { selection = .clips([step.target]) }
    }

    /// Whether Freeze Frame freezes something at the playhead now: not inside a clip with content, nor between two.
    var canFreezeAtPlayhead: Bool {
        guard canEdit, let document else { return false }
        return ContentClipCommands.freeze(document, atOutput: playheadNanoseconds, makeID: { $0 + "00000000" }) != nil
    }

    /// "Add Title Card" at `place` (the playhead's `.output`, `.start` or `.end`), titled "Title": the card is the one
    /// selected.
    func addTitleCard(at place: ContentClipCommands.Place) {
        guard canEdit, !isGesturing, let document,
            let step = ContentClipCommands.addCard(document, at: place, title: String(localized: "Title"), makeID: Self.newID),
            perform(step) != .refused
        else { return }
        selection = .clips([step.target])
    }

    /// "Clip in the Sequence…" (design §5.4): the clip at `url` copied into the project (`EditSession.importAsset`) and put
    /// into the sequence, the whole of its file (`mediaInfo(of:)`, off the main thread), at `place`; without one, at the
    /// edge of the clip nearest the playhead (`ContentClipCommands.insertionPoint`, as a drop on the Video track), in the
    /// document as it is once the file is in. It is the one selected. A file that is not a clip that plays says so; one
    /// too short for a frame of output beeps.
    func addMediaToSequence(from url: URL, at place: ContentClipCommands.Place?) async {
        guard canEdit, let session = panelSession else { return }
        switch await session.importAsset(url, kind: .video) {
        case let .imported(path):
            guard let info = await mediaInfo(of: path) else {
                tellCouldNotOpen()
                return
            }
            guard canEdit, let document else { return }
            let at = place ?? ContentClipCommands.insertionPoint(document, nearOutput: playheadNanoseconds)
            guard let step = ContentClipCommands.addMedia(document, asset: path, fileDuration: info.duration, at: at, makeID: Self.newID)
            else {
                NSSound.beep()
                return
            }
            if perform(step) != .refused { selection = .clips([step.target]) }
        case .notPlayable, .notAnImage, .notALUT:
            tellCouldNotOpen()
        case .saveFailed, .notEditable:
            // The session's banner says why.
            break
        }
    }

    /// What the imported file `asset` of the project is (its length, its picture's size, whether it has a sound), read
    /// once a file (`MediaInfo.probe`, off the main thread) and kept while the app runs: an asset is named by its content,
    /// so what it is never changes. `nil` if it cannot be read (asked again the next time).
    func mediaInfo(of asset: String) async -> MediaInfo? {
        guard let package = overlayProject?.package else { return nil }
        let key = package.url.standardizedFileURL.path + "\n" + asset
        if let known = MediaInfoMemo.known[key] { return known }
        if let probing = MediaInfoMemo.probing[key] { return await probing.value }
        let probing = Task { await MediaInfo.probe(asset, in: package) }
        MediaInfoMemo.probing[key] = probing
        let info = await probing.value
        MediaInfoMemo.probing[key] = nil
        if let info { MediaInfoMemo.known[key] = info }
        return info
    }

    /// The title card `id` changed by `edit` (its texts, style, background or text color), in one step.
    func changeTitleCard(_ id: String, _ edit: (inout TitleCard) -> Void) {
        guard canEdit, let document, let step = ContentClipCommands.changeCard(document, clipID: id, edit) else { return }
        perform(step)
    }

    /// The speed or the volume of the imported clip `id`: a step of the gesture while one lasts (the volume's slider being
    /// dragged), otherwise one of its own.
    func setMediaClip(_ id: String, speed: Double? = nil, volume: Double? = nil) {
        guard canEdit, let document else { return }
        let step = ContentClipCommands.setMedia(document, clipID: id, speed: speed, volume: volume)
        if isGesturing {
            updateGesture(step)
        } else if let step {
            perform(step)
        }
    }

    /// The system's open panel over the editor's window for one file of `kind`; `done` gets it.
    func chooseFile(_ kind: ImportedFile, _ done: @escaping @MainActor (URL) -> Void) {
        guard canEdit else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kind.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            MainActor.assumeIsolated { done(url) }
        }
        if let window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// "Couldn't open the file.", over the window.
    func tellCouldNotOpen() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't open the file.")
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
    }
}

/// What `EditorModel.mediaInfo(of:)` read, by package and asset, and what it is reading.
@MainActor
private enum MediaInfoMemo {
    static var known: [String: MediaInfo] = [:]
    static var probing: [String: Task<MediaInfo?, Never>] = [:]
}
