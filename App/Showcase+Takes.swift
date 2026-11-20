// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import Editing
import Foundation
import ProjectFormat

extension EditorModel {
    /// The showcase of the takes, the markers and the teleprompter (3d): what its `TOMA_SHOWCASE_P3_*` variables ask
    /// for.
    func showcaseTakes(_ environment: [String: String]) async {
        showcaseMarkers(environment)
        await showcaseTwoTakes(environment)
    }

    /// `TOMA_SHOWCASE_P3_TAKES=use` (T10): each take of the package the sequence does not show added at its end ("Add
    /// to End", `TakeCommands.appendToEnd`), then the playhead put again at `TOMA_SHOWCASE_PLAYHEAD` (a time in the
    /// second take: its camera's bubble), and, once that is drawn, the PNGs `TOMA_SHOWCASE_P3_TIMELINE_PNG` (the
    /// timeline, its thumbnails and waveforms of each take) and `TOMA_SHOWCASE_PANEL_PNG` (the window and the panel)
    /// written again: the earlier showcases wrote them before the takes were added.
    func showcaseTwoTakes(_ environment: [String: String]) async {
        guard environment["TOMA_SHOWCASE_P3_TAKES"] == "use", let project = overlayProject else { return }
        for take in project.takes {
            guard let document, !document.sequence.contains(where: { $0.take == take.id }),
                let shown = project.focused(on: take.id)
            else { continue }
            // Its events, read off the main thread (the opening read them already).
            _ = await Task.detached { shown.events.count }.value
            guard let document = self.document,
                let step = TakeCommands.appendToEnd(document, take: shown, makeID: Self.newID)
            else { continue }
            perform(step)
        }
        if let seconds = environment["TOMA_SHOWCASE_PLAYHEAD"].flatMap(Double.init) {
            // Once the revision is shown, so the playhead is counted in the sequence with the takes added.
            try? await Task.sleep(for: .milliseconds(500))
            scrub(toSeconds: seconds)
            endScrub()
        }
        if environment["TOMA_SHOWCASE_PANEL_PNG"] != nil { CaptionsShowcase.snapshotLater(window) }
        if let path = environment["TOMA_SHOWCASE_P3_TIMELINE_PNG"] {
            try? await Task.sleep(for: .seconds(3))
            Self.writeTakesTimelinePNG(to: URL(filePath: path))
        }
    }

    /// The first editor timeline of the app's windows, drawn from its layers into a PNG at `url` at 2×, as
    /// `TOMA_SHOWCASE_P3_TIMELINE_PNG` of the annotations draws it.
    static func writeTakesTimelinePNG(to url: URL) {
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
}
#endif
