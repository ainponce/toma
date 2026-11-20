// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Editing
import Foundation
import ProjectFormat

/// The import of a `.cube` for Custom, as the Camera tab shows it (phase 2 design §6.3).
enum LUTImportState: Equatable {
    case idle
    /// Being copied into the project; a full disk makes it wait (the amber banner says so) until it is cancelled.
    case importing
    /// Read, and not a 3D LUT Toma reads: why.
    case refused(CubeLUTError)
    /// Not a `.cube` that could be opened (not named so, gone, not a regular file, unreadable).
    case unreadable
    case saveFailed
}

/// What the Camera tab does to the camera's picture (phase 2 design §6.1 to §6.3, plan 2b task I13): each control is one
/// step of `CameraPictureCommands`. A drag (of the framing's small view, of a bar) is a gesture: the preview follows it and
/// its end is one edit; a click, a key or a notch of the wheel is a step of its own, which the session joins into one undo
/// when they come in a burst.
extension EditorModel {
    /// Applies `step`: inside a gesture it is the gesture's step, otherwise an edit.
    private func applyPicture(_ step: EditStep?) {
        guard let step else { return }
        if isGesturing { updateGesture(step) } else { perform(step) }
    }

    /// Fondo: Original, Desenfocado or Quitado.
    func setCameraBackground(_ background: CameraBackground) {
        guard let document else { return }
        applyPicture(CameraPictureCommands.setBackground(document, background))
    }

    /// Encuadre: Centrado, Seguir la cara (from 1.4× when it was not zoomed) or Manual.
    func setFramingMode(_ mode: CameraFramingMode) {
        guard let document else { return }
        applyPicture(CameraPictureCommands.setFramingMode(document, mode))
    }

    /// The centre of Manual framing, in fractions of the camera's frame.
    func setFramingCenter(_ center: NormalizedPoint) {
        guard let document else { return }
        applyPicture(CameraPictureCommands.setFramingCenter(document, center))
    }

    /// The framing's zoom, 1 to 2.5.
    func setFramingZoom(_ zoom: Double) {
        guard let document else { return }
        applyPicture(CameraPictureCommands.setFramingZoom(document, zoom))
    }

    /// A look of Color. Custom only with a `.cube` in the document (`chooseLUT` brings one in).
    func setLookPreset(_ preset: CameraColorPreset) {
        guard let document else { return }
        applyPicture(CameraPictureCommands.setLookPreset(document, preset))
    }

    /// Intensidad, 0 to 1.
    func setLookIntensity(_ value: Double) {
        guard let document else { return }
        applyPicture(CameraPictureCommands.setLookIntensity(document, value))
    }

    /// "Custom…": the `.cube` at `url` is read and copied into the project (`importAsset(_:kind: .lut)`), then it is the
    /// look, in one edit. `finished` is told how it went: `.idle` once it is the look (or when there is nothing to say),
    /// the reason it was refused otherwise. One import at a time, an image's or a `.cube`'s (`cancelImageImport` stops the
    /// one waiting for room on a full disk): whether it started (`finished` is called only then).
    @discardableResult
    func chooseLUT(_ url: URL, finished: @escaping @MainActor (LUTImportState) -> Void) -> Bool {
        guard canEdit, importTask == nil, let session = panelSession else { return false }
        importTask = Task {
            let outcome = await session.importAsset(url, kind: .lut)
            let cancelled = Task.isCancelled
            importTask = nil
            switch outcome {
            case let .imported(path):
                if let document, let step = CameraPictureCommands.setCustomLook(document, file: path) { perform(step) }
                finished(.idle)
            case let .notALUT(reason):
                finished(.refused(reason))
            case .notAnImage, .notPlayable:
                // `.notPlayable` is only a clip's or a sound's, never a `.cube`'s.
                finished(.unreadable)
            case .saveFailed:
                // Cancelled by the user while it waited for room on a full disk: nothing to say.
                finished(cancelled ? .idle : .saveFailed)
            case .notEditable:
                finished(.idle)
            }
        }
        return true
    }
}

#if DEBUG
extension EditorModel {
    /// `TOMA_SHOWCASE_PICTURE` of `-TomaShowcase`: the camera's background, framing and look by their names in the
    /// document (`blurred`, `manual`, `warm`…), each left as it is when empty or unknown; then, after a second, the
    /// panel scrolled that fraction of the way down (the Camera tab's sections are below its first screen); the
    /// playhead at that frame (the camera starts a little after the screen); and the framing's zoom.
    func showcasePicture(_ parts: [String]) {
        if let background = parts.first.flatMap(CameraBackground.init(rawValue:)) { setCameraBackground(background) }
        if parts.count > 1, let mode = CameraFramingMode(rawValue: parts[1]) { setFramingMode(mode) }
        if parts.count > 2, let preset = CameraColorPreset(rawValue: parts[2]) { setLookPreset(preset) }
        if parts.count > 4, let frame = Int(parts[4]) { seek(frame: frame) }
        if parts.count > 5, let zoom = Double(parts[5]) { setFramingZoom(zoom) }
        guard parts.count > 3, let fraction = Double(parts[3]) else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard let content = window?.contentView else { return }
            for scrollView in Self.scrollViews(in: content) {
                guard let document = scrollView.documentView else { continue }
                let room = document.frame.height - scrollView.contentView.bounds.height
                // The panel's: the one that scrolls up and down, not the timeline's.
                guard room > 0, !scrollView.hasHorizontalScroller || scrollView.hasVerticalScroller else { continue }
                let y = document.isFlipped ? room * fraction : room * (1 - fraction)
                scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
#endif
