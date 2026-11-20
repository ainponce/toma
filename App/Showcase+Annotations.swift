// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import Editing
import Foundation
import ProjectFormat
import Render

extension EditorModel {
    /// The showcase of the annotations, the title cards and the imported images and clips (3a): what its
    /// `TOMA_SHOWCASE_P3_*` variables ask for.
    ///
    /// - `TOMA_SHOWCASE_P3_ANNOTATIONS=track`: five annotations on the Annotations track (Task A12), a text and an arrow
    ///   that overlap, a step, a shape of the output and a speech bubble of the whole video; the arrow selected, with the
    ///   playhead on it.
    /// - `TOMA_SHOWCASE_P3_ANNOTATIONS=content`: a title card, a frozen frame and an imported clip in the sequence (Task
    ///   A15, `showcaseContentClips`).
    /// - `TOMA_SHOWCASE_P3_ANNOTATIONS=edit`: those of `track`, the arrow selected with the playhead on it, its handles over
    ///   the preview (Task A13); `edit-flat`, the same with the zooms hidden; `edit-split`, with a Split block at the
    ///   playhead; `edit-callout`, the speech bubble of the whole video selected; `text`, the text "Hola" being edited in
    ///   place; `edit-shape`, a shape of the take turned 20° selected.
    /// - `TOMA_SHOWCASE_P3_TIMELINE_PNG=<path>`: once that is drawn, a PNG of the editor's timeline at 2×, made from its
    ///   layers in the app (`CALayer.render(in:)`), for when the screen cannot be captured (it is locked).
    /// - `TOMA_SHOWCASE_P3_PREVIEW_PNG=<path>`: then, a PNG of the preview at 2×: the frame at the playhead drawn by a
    ///   renderer of its own from the scene shown, with the overlays' layers over it.
    func showcaseAnnotations(_ environment: [String: String]) async {
        switch environment["TOMA_SHOWCASE_P3_ANNOTATIONS"] {
        case "track"?, "edit"?: showcaseAnnotationTrack()
        case "edit-flat"?, "edit-split"?:
            showcaseAnnotationTrack()
            if case let .annotations(ids)? = selection, let arrow = ids.first {
                if environment["TOMA_SHOWCASE_P3_ANNOTATIONS"] == "edit-flat" {
                    setZoomShow(false)
                } else if let rate = document?.frameRate {
                    // From a second before the arrow, so its cards are settled at the arrow.
                    seek(frame: Int(1.5 * Double(rate)))
                    _ = addLayoutBlock(kind: .split)
                }
                selectAnnotation(arrow, showingIt: true)
            }
        case "edit-shape"?:
            showcaseAnnotationShape()
        case "edit-callout"?:
            showcaseAnnotationTrack()
            if let callout = document?.annotations.items.first(where: {
                if case .callout = $0.kind { return true }
                return false
            }) {
                selection = .annotations([callout.id])
            }
        case "text"?:
            showcaseAnnotationTrack()
            if let text = document?.annotations.items.first(where: {
                if case let .text(text) = $0.kind { return text.string == "Hola" }
                return false
            }) {
                selectAnnotation(text.id, showingIt: true)
                try? await Task.sleep(for: .seconds(2))
                Self.annotationEditor()?.beginEditingText(text.id)
            }
        case "content"?: await showcaseContentClips()
        default: break
        }
        if let path = environment["TOMA_SHOWCASE_P3_TIMELINE_PNG"] {
            try? await Task.sleep(for: .seconds(3))
            Self.writeTimelinePNG(to: URL(filePath: path))
        }
        if let path = environment["TOMA_SHOWCASE_P3_PREVIEW_PNG"] {
            try? await Task.sleep(for: .seconds(3))
            await writePreviewPNG(to: URL(filePath: path))
        }
    }

    /// The editor's first `AnnotationEditorView`.
    private static func annotationEditor() -> AnnotationEditorView? {
        NSApp.windows.lazy.compactMap { $0.contentView.flatMap { find(AnnotationEditorView.self, in: $0) } }.first
    }

    private static func find<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let found = view as? View { return found }
        for subview in view.subviews { if let found = find(type, in: subview) { return found } }
        return nil
    }

    /// `TOMA_SHOWCASE_P3_ANNOTATIONS=edit-shape`: a shape of the take at 2 s, turned 20°, selected.
    private func showcaseAnnotationShape() {
        guard let document,
            let step = AnnotationCommands.add(
                document, AnnotationDefaults.kind(.shape, text: ""), atOutput: TimeMap.outputNanoseconds(seconds: 2),
                rect: NormalizedRect(x: 0.3, y: 0.3, width: 0.3, height: 0.2), makeID: Self.newID),
            perform(step) != .refused, let added = self.document,
            let turn = AnnotationCommands.change(added, id: step.target, { $0.rotation = 20 })
        else { return }
        perform(turn)
        selectAnnotation(step.target, showingIt: true)
    }

    /// The preview drawn into a PNG at `url`: the frame at the playhead of the scene shown, by a renderer of its own (off
    /// the main thread), and the preview's overlays over it from their layers.
    private func writePreviewPNG(to url: URL) async {
        guard let overlay = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap { Self.find(PreviewOverlayView.self, in: $0) } }).first,
            let project = overlayProject, let document, let scene = shownScene,
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return }
        let seconds = Double(playheadNanoseconds) / 1e9
        let size = scene.outputSize
        let bytes = try? await Task.detached {
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
            renderer.setScene(scene)
            return try renderer.renderBytes(at: seconds)
        }.value
        guard let bytes, let provider = CGDataProvider(data: Data(bytes) as CFData),
            let frame = CGImage(
                width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        overlay.layoutSubtreeIfNeeded()
        overlay.displayIfNeeded()
        let scale = 2.0, bounds = overlay.bounds.size
        guard bounds.width >= 1, bounds.height >= 1, let layer = overlay.layer,
            let context = CGContext(
                data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.draw(frame, in: CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale))
        // The layers are drawn top down: the bitmap's rows go bottom up.
        context.translateBy(x: 0, y: bounds.height * scale)
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The first editor timeline of the app's windows, drawn from its layers into a PNG at `url`.
    private static func writeTimelinePNG(to url: URL) {
        func timeline(in view: NSView) -> EditorTimelineView? {
            if let found = view as? EditorTimelineView { return found }
            for subview in view.subviews { if let found = timeline(in: subview) { return found } }
            return nil
        }
        guard let view = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(timeline(in:)) }).first, let layer = view.layer,
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = 2.0, size = view.bounds.size
        guard size.width >= 1, size.height >= 1,
            let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        // The view's layers are drawn top down: the bitmap's rows go bottom up.
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `TOMA_SHOWCASE_P3_ANNOTATIONS=track`.
    private func showcaseAnnotationTrack() {
        func add(_ kind: AnnotationKind, at seconds: Double) -> String? {
            guard let document,
                let step = AnnotationCommands.add(
                    document, kind, atOutput: TimeMap.outputNanoseconds(seconds: seconds),
                    rect: AnnotationDefaults.rect(for: kind, aspect: nil, spaceAspect: 16.0 / 9), makeID: Self.newID),
                perform(step) != .refused
            else { return nil }
            return step.target
        }
        func anchor(_ id: String?, _ choice: AnnotationCommands.AnchorChoice) {
            guard let id, let document, let annotation = document.annotations.items.first(where: { $0.id == id }),
                let step = AnnotationCommands.setAnchor(document, id: id, to: choice, rect: annotation.rect)
            else { return }
            perform(step)
        }
        _ = add(AnnotationDefaults.kind(.text, text: "Hola"), at: 1)
        let arrow = add(AnnotationDefaults.kind(.arrow, text: ""), at: 2.5)
        _ = add(AnnotationDefaults.kind(.step, text: ""), at: 6)
        anchor(add(AnnotationDefaults.kind(.shape, text: ""), at: 8.5), .output)
        anchor(add(AnnotationDefaults.kind(.callout, text: "Clic acá"), at: 0.5), .whole)
        if let arrow { selectAnnotation(arrow, showingIt: true) }
    }
}
#endif
