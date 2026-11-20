// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import Editing
import Foundation
import ProjectFormat

extension EditorModel {
    /// The showcase of the calm zoom, highlight, dim and the loupe (3b): what its `TOMA_SHOWCASE_P3_*` variables ask
    /// for (plan 3b decision 12).
    ///
    /// - `TOMA_SHOWCASE_P3_CALMZOOM=<highlight|dim|loupe>`: that mode for the first zoom block (a block of 3 s centred on
    ///   the playhead if there is none), selected, with the Zoom tab open; `loupe-rect` is the loupe as a rounded rectangle.
    /// - `TOMA_SHOWCASE_P3_CALMZOOM=track`: on the Zoom track, in the first four fifths of the output, a block of the
    ///   user's in each mode (Classic, the first block trimmed; Highlight, Dim and Loupe), and in the last fifth the
    ///   automatic zooms planned again in Loupe; the Loupe block selected.
    ///
    /// With `TOMA_SHOWCASE_PANEL_PNG` the panel is drawn into PNGs, and with `TOMA_SHOWCASE_P3_TIMELINE_PNG` the timeline
    /// is drawn again into its PNG once this is done (the screen cannot be captured while it is locked).
    func showcaseCalmZoom(_ environment: [String: String]) async {
        switch environment["TOMA_SHOWCASE_P3_CALMZOOM"] {
        case nil: return
        case "track"?: await showcaseCalmZoomTrack()
        case let raw?:
            let rounded = raw == "loupe-rect"
            guard let mode = rounded ? .loupe : ZoomMode(rawValue: raw) else { return }
            if document?.zoom.regions.isEmpty != false { addZoom() }
            // An automatic block becomes the user's with its id.
            guard let id = document?.zoom.regions.first?.id else { return }
            setZoomMode(id, mode)
            if rounded { setLoupe(id, shape: .roundedRect) }
            selection = .zooms([id])
        }
        panelTab = .zoom
        CaptionsShowcase.snapshotLater(window)
        if let path = environment["TOMA_SHOWCASE_P3_TIMELINE_PNG"] {
            try? await Task.sleep(for: .seconds(2))
            Self.writeCalmZoomTimelinePNG(to: URL(filePath: path))
        }
    }

    /// `TOMA_SHOWCASE_P3_CALMZOOM=track`.
    private func showcaseCalmZoomTrack() async {
        guard let start = document else { return }
        let fifth = TimeMap(sequence: start.sequence).duration / 5
        if let first = start.zoom.regions.first,
            let step = ZoomCommands.trim(start, id: first.id, edge: .end, toOutput: fifth)
        {
            perform(step)
        }
        var loupe: String?
        for (k, mode) in [ZoomMode.highlight, .dim, .loupe].enumerated() {
            let part = Int64(k + 1) * fifth..<Int64(k + 2) * fifth
            guard let document, let step = ZoomCommands.add(document, output: part, makeID: Self.newID), perform(step) != .refused
            else { continue }
            setZoomMode(step.target, mode)
            if mode == .loupe { loupe = step.target }
        }
        setAutoZoomMode(.loupe)
        regenerateAutoZoom()
        let deadline = ContinuousClock.now + .seconds(10)
        while autoZoomPending != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if let loupe { selection = .zooms([loupe]) }
    }

    /// The first editor timeline of the app's windows, drawn from its layers into a PNG at `url` at 2×.
    private static func writeCalmZoomTimelinePNG(to url: URL) {
        func timeline(in view: NSView) -> EditorTimelineView? {
            if let found = view as? EditorTimelineView { return found }
            return view.subviews.lazy.compactMap(timeline(in:)).first
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
