// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat

/// What the panel does to the document (design §5.4): each control is one of `StyleCommands`' steps. A drag of a bar is
/// a gesture (Task 36): the preview follows it, and its end is one edit; the arrow keys and a click are steps of their own,
/// which the session's rule for bursts joins into one undo.
extension EditorModel {
    /// Sets the style value at `pointer` (`/style/padding`…): inside a gesture it is the gesture's step, otherwise an edit.
    func setStyle(_ pointer: String, _ value: some Encodable, label: EditLabel) {
        guard let document, let step = StyleCommands.set(document, pointer, value, label: label) else { return }
        if isGesturing { updateGesture(step) } else { perform(step) }
    }

    /// The background, and with it the blur when the new one needs another (the Desktop starts at 50): one edit.
    func setBackground(_ background: Background, blur: Double? = nil) {
        guard let document else { return }
        var changes: [EditChange] = []
        var target = "/style/background"
        if let step = StyleCommands.set(document, "/style/background", background, label: .background) {
            changes += step.changes
            target = step.target
        }
        if let blur, let step = StyleCommands.set(document, "/style/backgroundBlur", blur, label: .background) { changes += step.changes }
        guard !changes.isEmpty else { return }
        let step = EditStep(label: .background, target: target, changes: changes)
        if isGesturing { updateGesture(step) } else { perform(step) }
    }

    // MARK: - Image

    /// "Choose Image…": the file is copied into the project (`importAsset`), then it is the background.
    func chooseImage(_ url: URL) {
        guard canEdit, importTask == nil, let session = panelSession else { return }
        imageImport = .importing
        importTask = Task {
            let outcome = await session.importAsset(url)
            let cancelled = Task.isCancelled
            importTask = nil
            switch outcome {
            case let .imported(path):
                imageImport = .idle
                setBackground(.image(file: path))
            case .notAnImage:
                imageImport = .notAnImage
            case .saveFailed:
                // Cancelled by the user while it waited for room on a full disk: nothing to say.
                imageImport = cancelled ? .idle : .saveFailed
            case .notEditable:
                imageImport = .idle
            }
        }
    }

    /// Stops an import that waits for room on a full disk.
    func cancelImageImport() {
        importTask?.cancel()
    }

    /// "Remove Image": the background goes back to Toma's wallpaper.
    func removeImage() {
        setBackground(DefaultStyle.toma.style.background)
    }

    // MARK: - The style for new projects

    /// "Use This Style for New Projects": the stage, the whole cursor and the zoom's settings of this project.
    func useStyleForNewProjects() {
        guard let document, let session = panelSession, styleStore != .working else { return }
        let style = DefaultStyle(
            style: document.style, cursor: document.cursor, zoomShow: document.zoom.show, zoomAuto: document.zoom.auto,
            zoomSpring: document.zoom.spring, zoomMotionBlur: document.zoom.motionBlur)
        let package = ProjectPackage(url: session.packageURL)
        runStyleStore { try await $0.save(style, from: package) }
    }

    /// "Restore Toma's Style": the next projects start as Toma's.
    func restoreTomaStyle() {
        runStyleStore { try await $0.reset() }
    }

    private func runStyleStore(_ work: @escaping @Sendable (DefaultStyleStore) async throws -> Void) {
        guard styleStore != .working else { return }
        styleStore = .working
        Task {
            let store = DefaultStyleStore(directory: DefaultStyleStore.defaultDirectory)
            do {
                try await work(store)
                styleStore = .idle
            } catch {
                styleStore = .failed
            }
        }
    }
}
