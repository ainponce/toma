// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import Editing
import Foundation
import ProjectFormat

extension EditorModel {
    /// The showcase of the annotations, the title cards and the imported images and clips (3a): what its
    /// `TOMA_SHOWCASE_P3_*` variables ask for.
    ///
    /// - `TOMA_SHOWCASE_P3_ANNOTATIONS=track`: five annotations on the Annotations track (Task A12), a text and an arrow
    ///   that overlap, a step, a shape of the output and a speech bubble of the whole video; the arrow selected, with the
    ///   playhead on it.
    /// - `TOMA_SHOWCASE_P3_TIMELINE_PNG=<path>`: once that is drawn, a PNG of the editor's timeline at 2×, made from its
    ///   layers in the app (`CALayer.render(in:)`), for when the screen cannot be captured (it is locked).
    func showcaseAnnotations(_ environment: [String: String]) async {
        switch environment["TOMA_SHOWCASE_P3_ANNOTATIONS"] {
        case "track"?: showcaseAnnotationTrack()
        default: break
        }
        if let path = environment["TOMA_SHOWCASE_P3_TIMELINE_PNG"] {
            try? await Task.sleep(for: .seconds(3))
            Self.writeTimelinePNG(to: URL(filePath: path))
        }
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
