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
    /// - `TOMA_SHOWCASE_P3_ANNOTATIONS=inspector` (Task A14, with `TOMA_SHOWCASE_TAB=8`): a Lower third text at 2 s
    ///   selected, with the playhead on it, its inspector in the Annotations tab; `inspector-arrow`, `inspector-shape`,
    ///   `inspector-callout` and `inspector-clip` the same with an arrow, a shape with a fill, a speech bubble and the take's
    ///   own first segment imported as a clip over the video; `card`, a title card "Intro" at the start, selected, with a
    ///   subtitle and a colour background. With `TOMA_SHOWCASE_PANEL_PNG=<path>`, the window and the panel drawn into PNGs
    ///   (`CaptionsShowcase.snapshotLater`); with `TOMA_SHOWCASE_P3_NARROW=1`, the panel at its narrowest, 260 pt.
    ///   `anchor` and `menu` check, with the screen locked, that the inspector's anchor switches leave a text on its pixels
    ///   (`TOMA_SHOWCASE_P3_ANCHOR_LOG`) and that ⌘D and Edit ▸ Arrange's keys reach the model through the main menu
    ///   (`TOMA_SHOWCASE_P3_MENU_LOG`).
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
        case let variant? where variant.hasPrefix("inspector"):
            await showcaseInspector(variant)
        case "card"?:
            showcaseCard()
        case "anchor"?:
            await showcaseAnchor(log: environment["TOMA_SHOWCASE_P3_ANCHOR_LOG"])
        case "menu"?:
            await showcaseMenuKeys(log: environment["TOMA_SHOWCASE_P3_MENU_LOG"])
        default: break
        }
        if let variant = environment["TOMA_SHOWCASE_P3_ANNOTATIONS"], variant.hasPrefix("inspector") || variant == "card" {
            if environment["TOMA_SHOWCASE_P3_NARROW"] == "1" { Self.narrowPanel(of: window) }
            if environment["TOMA_SHOWCASE_PANEL_PNG"] != nil { CaptionsShowcase.snapshotLater(window) }
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

    /// `TOMA_SHOWCASE_P3_ANNOTATIONS=inspector…`: one annotation at 2 s, selected with the playhead on it.
    private func showcaseInspector(_ variant: String) async {
        let kind: AnnotationKind
        var rect = NormalizedRect(x: 0.06, y: 0.72, width: 0.42, height: 0.1)
        switch variant {
        case "inspector-arrow":
            kind = AnnotationDefaults.kind(.arrow, text: "")
            rect = AnnotationDefaults.rect(for: kind, aspect: nil, spaceAspect: 16.0 / 9)
        case "inspector-shape":
            kind = .shape(ShapeAnnotation(shape: .roundedRect, fill: RGBA(1, 69.0 / 255, 58.0 / 255, 0.25)))
            rect = NormalizedRect(x: 0.35, y: 0.35, width: 0.3, height: 0.2)
        case "inspector-callout":
            kind = AnnotationDefaults.kind(.callout, text: "Clic acá")
            rect = AnnotationDefaults.rect(for: kind, aspect: nil, spaceAspect: 16.0 / 9)
        case "inspector-clip":
            guard let project = overlayProject, let session = panelSession,
                let segment = project.take.tracks.first(where: { $0.kind.isScreen && !$0.segments.isEmpty })?.segments.first,
                case let .imported(path) = await session.importAsset(project.package.url.appending(path: segment.file), kind: .video),
                let info = await mediaInfo(of: path)
            else { return }
            kind = AnnotationDefaults.clip(asset: path, fileDuration: info.duration)
            rect = NormalizedRect(x: 0.6, y: 0.08, width: 0.32, height: 0.32)
        default:
            kind = .text(TextAnnotation(string: "Ana Pérez · Diseño", preset: .lowerThird, size: 0.04))
        }
        guard let document,
            let step = AnnotationCommands.add(
                document, kind, atOutput: TimeMap.outputNanoseconds(seconds: 2), rect: rect, makeID: Self.newID),
            perform(step) != .refused
        else { return }
        // Of the output, so the project's automatic zoom does not take it out of the frame.
        if let added = self.document,
            let output = AnnotationCommands.setAnchor(added, id: step.target, to: .output, rect: rect)
        {
            perform(output)
        }
        selectAnnotation(step.target, showingIt: true)
    }

    /// `TOMA_SHOWCASE_P3_ANNOTATIONS=anchor`: a text stuck to the recording at 2 s, selected, then fixed on the output and
    /// stuck to the recording again by the inspector's switches (`setAnnotationAnchor`); where the frame at the playhead
    /// draws its box and its letters (in output pixels) each time, written to `TOMA_SHOWCASE_P3_ANCHOR_LOG=<path>`: the
    /// three lines are the same when nothing jumps.
    private func showcaseAnchor(log: String?) async {
        guard let document,
            let step = AnnotationCommands.add(
                document, .text(TextAnnotation(string: "Acá", preset: .label, size: 0.05)),
                atOutput: TimeMap.outputNanoseconds(seconds: 2), rect: NormalizedRect(x: 0.2, y: 0.25, width: 0.25, height: 0.06),
                makeID: Self.newID),
            perform(step) != .refused
        else { return }
        let id = step.target
        selectAnnotation(id, showingIt: true)
        var lines: [String] = []
        func measure(_ what: String) async {
            // The preview's scene is built again off the main thread after each step.
            try? await Task.sleep(for: .seconds(2))
            guard let scene = shownScene else { return }
            let frame = scene.frame(at: Double(playheadNanoseconds) / 1e9) { _ in true }
            guard let drawn = DrawnAnnotation.all(in: frame).first(where: { $0.layer.id == id }) else {
                lines.append("\(what): not drawn")
                return
            }
            let box = drawn.box
            var em = 0.0
            if case let .text(text) = drawn.layer.content { em = text.size * drawn.space.height }
            let anchor = self.document?.annotations.items.first { $0.id == id }.map { "\($0.anchor)" } ?? "?"
            lines.append(
                String(format: "%@: x %.2f y %.2f w %.2f h %.2f em %.2f — %@", what, box.x, box.y, box.width, box.height, em, anchor))
        }
        await measure("stuck")
        setAnnotationAnchor(id, to: .output)
        await measure("output")
        setAnnotationAnchor(id, to: .recording)
        await measure("stuck again")
        if let log { try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8) }
    }

    /// `TOMA_SHOWCASE_P3_ANNOTATIONS=menu`: a text at 2 s selected, then ⌘D, ⌘[, ⌥⌘] and ⌘] sent to the app's main menu
    /// as key equivalents (as AppKit sends a key the window does not take); after each, how many annotations there are,
    /// which is selected and their layers, written to `TOMA_SHOWCASE_P3_MENU_LOG=<path>`, with the Edit menu's items.
    private func showcaseMenuKeys(log: String?) async {
        guard let document,
            let step = AnnotationCommands.add(
                document, .text(TextAnnotation(string: "Uno", preset: .label, size: 0.05)),
                atOutput: TimeMap.outputNanoseconds(seconds: 2), rect: NormalizedRect(x: 0.2, y: 0.25, width: 0.25, height: 0.06),
                makeID: Self.newID),
            perform(step) != .refused
        else { return }
        selectAnnotation(step.target, showingIt: true)
        var lines: [String] = []
        func state(_ what: String) {
            let items = self.document?.annotations.items ?? []
            let layers = items.map { "\($0.id)=\($0.layer)" }.joined(separator: " ")
            lines.append("\(what): \(items.count) annotations, selected \(selectedAnnotationIDs.sorted()), \(layers)")
        }
        // What opening the menus does: SwiftUI fills and enables their items then.
        func refresh(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items { if let submenu = item.submenu { refresh(submenu) } }
        }
        func refreshMenus() { for item in NSApp.mainMenu?.items ?? [] { if let menu = item.submenu { refresh(menu) } } }
        /// The item of the Edit menu with the key equivalent `key` (⌘D), or the `arrange`th of its Arrange submenu: its key
        /// as the menu has it on this Mac's keyboard layout (macOS moves ⌘[ and ⌘] on other layouts) sent to the main menu.
        func press(_ name: String, key: String? = nil, arrange: Int? = nil) async {
            try? await Task.sleep(for: .seconds(1))
            refreshMenus()
            let edit = NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.items.contains { $0.keyEquivalent == "d" && $0.keyEquivalentModifierMask == .command }
            }
            let item: NSMenuItem? =
                if let key { edit?.items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command } }
                else { edit?.items.first { $0.submenu?.items.count == 4 }?.submenu?.items[arrange ?? 0] }
            guard let item, let window = self.window,
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: item.keyEquivalentModifierMask,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: item.keyEquivalent, charactersIgnoringModifiers: item.keyEquivalent, isARepeat: false, keyCode: 0)
            else {
                lines.append("\(name): no item")
                return
            }
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
            try? await Task.sleep(for: .milliseconds(300))
            let option = item.keyEquivalentModifierMask.contains(.option) ? "⌥" : ""
            state("\(name) (\(item.title), ⌘\(option)\(item.keyEquivalent)) handled \(handled)")
        }
        try? await Task.sleep(for: .seconds(2))
        lines.append("key window is the editor: \(NSApp.keyWindow === window)")
        // As when its window becomes key (with the screen locked, no window is).
        KeyEditor.shared.follow(self)
        try? await Task.sleep(for: .seconds(1))
        refreshMenus()
        state("start")
        await press("⌘D", key: "d")
        await press("⌘[", arrange: 1)
        await press("⌥⌘]", arrange: 2)
        await press("⌥⌘[", arrange: 3)
        await press("⌘]", arrange: 0)
        if let log { try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8) }
    }

    /// `TOMA_SHOWCASE_P3_ANNOTATIONS=card`: a title card "Intro" at the start with a subtitle and a dark blue background,
    /// selected, the playhead on it.
    private func showcaseCard() {
        guard let document, let step = ContentClipCommands.addCard(document, at: .start, title: "Intro", makeID: Self.newID),
            perform(step) != .refused
        else { return }
        changeTitleCard(step.target) {
            $0.subtitle = "Cómo grabar una demo en cinco minutos"
            $0.background = .color(RGBA(0.08, 0.1, 0.22, 1))
        }
        selection = .clips([step.target])
        if let rate = self.document?.frameRate { seek(frame: rate) }
    }

    /// The panel of the editor's window at its narrowest, 260 pt.
    private static func narrowPanel(of window: NSWindow?) {
        guard let content = window?.contentView else { return }
        func inspector(_ view: NSView) -> NSView? {
            view.identifier?.rawValue == "inspector" ? view : view.subviews.lazy.compactMap(inspector).first
        }
        guard let panel = inspector(content) else { return }
        var view: NSView? = panel
        while let current = view, !(current.superview is NSSplitView) { view = current.superview }
        guard let split = view?.superview as? NSSplitView, split.subviews.count > 1 else { return }
        split.setPosition(split.bounds.width - 260 - split.dividerThickness, ofDividerAt: split.subviews.count - 2)
        split.layoutSubtreeIfNeeded()
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
