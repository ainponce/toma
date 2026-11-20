// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// The mouse on the Music track (phase 3 design §7.4, plan 3c decisions 13 and 15), on top of `MusicTrackRules` and
/// `MusicCommands`:
///
/// - A click on a piece selects it (the Audio tab shows it); on nothing, the playhead goes there.
/// - Dragging a piece moves it (it stops at its neighbours and at the ends of the video); its edges trim it (the start
///   keeps the music in its place); ⌥ and a drag of its body slides what it plays under it (`offset`); its volume line,
///   its volume, sticking to 0 dB.
/// - Its menu: "Replace Music…" and "Delete Music"; on nothing, "Add Music…" and "Import Audio…". The library's list
///   opens in a popover where the menu was (`MusicLibraryPopover`).
/// - An audio file dropped on the track goes in there (`TimelineMusicDrop`).
///
/// Each drag that edits is one gesture of the model, as the other drags of the timeline (`TimelineInteraction`).
extension TimelineInteraction {
    enum MusicDrag {
        /// Pressed, not yet dragged.
        case pressed(MusicPointed, down: CGPoint)
        /// The body of piece `id`, which started at `start`, grabbed `grab` ns after its start.
        case moveMusic(Base, id: String, start: Int64, grab: Int64)
        case trimMusic(Base, id: String, edge: ClipEdge, from: Int64)
        /// ⌥ on piece `id`: its `offset` when it started, the drag from `anchor`, the length of its file if known.
        case slipMusic(Base, id: String, offset: Int64, anchor: Int64, length: Int64?)
        case musicGain(Base, id: String)
    }

    // MARK: - The mouse

    /// A press at `point` on what `hit` says: whether the Music track took it.
    func musicMouseDown(_ event: NSEvent, at point: CGPoint, hit: TimelineHit) -> Bool {
        guard case .empty(.music, _) = hit, let pointed = view.musicHit(at: point, option: event.modifierFlags.contains(.option))
        else { return false }
        switch pointed.hit {
        case let .body(id), let .edge(id, _), let .slip(id), let .gainLine(id):
            model?.selection = .musicItem(id)
        case .empty:
            break
        }
        drag = .music(.pressed(pointed, down: point))
        return true
    }

    func musicMouseDragged(_ music: MusicDrag, _ event: NSEvent) {
        guard case let .pressed(pointed, down) = music else {
            updateMusicDrag(music, event)
            return
        }
        guard TimelineDragRules.isDrag(from: down, to: point(event)) else { return }
        startMusicDrag(pointed)
        if case let .music(started) = drag { updateMusicDrag(started, event) }
    }

    func musicMouseUp(_ music: MusicDrag, _ event: NSEvent) {
        switch music {
        case let .pressed(pointed, _):
            // A click on nothing: no piece selected, and the playhead goes there.
            if case .empty = pointed.hit {
                model?.selection = nil
                view.scrub(at: point(event).x)
                view.endScrub()
            }
        case let .moveMusic(_, id, _, _), let .trimMusic(_, id, _, _), let .slipMusic(_, id, _, _, _), let .musicGain(_, id):
            if endMusicGesture() != nil { model?.selection = .musicItem(id) }
        }
    }

    /// Esc during a drag of the Music track: what it edited is given up.
    func cancelMusicDrag(_ music: MusicDrag) {
        guard case .pressed = music else {
            lastStep = nil
            model?.cancelGesture()
            view.setPreview(nil)
            return
        }
    }

    /// The cursor over the Music track: sideways over an edge and, with ⌥, over a piece; up and down over its volume line.
    func setMusicCursor(_ event: NSEvent, at point: CGPoint) {
        guard canEdit, let pointed = view.musicHit(at: point, option: event.modifierFlags.contains(.option)) else { return }
        switch pointed.hit {
        case .edge: NSCursor.resizeLeftRight.set()
        case .slip: NSCursor.openHand.set()
        case .gainLine: NSCursor.resizeUpDown.set()
        case .body, .empty: NSCursor.arrow.set()
        }
    }

    // MARK: - The drags

    private func startMusicDrag(_ pointed: MusicPointed) {
        guard canEdit, let model, model.document != nil else {
            drag = .none
            return
        }
        func item(_ id: String, in document: EditDocument) -> MusicItem? {
            document.music.items.first { $0.id == id }
        }
        switch pointed.hit {
        case .empty:
            // Dragging on nothing goes on moving the playhead.
            drag = .playhead
            view.scrub(at: view.content?.layout.x(ofOutput: pointed.output, scale: view.scale, offset: view.offset) ?? 0)
        case let .body(id):
            guard let base = begin(), let piece = item(id, in: base.document) else { return cancelMusicStart() }
            drag = .music(.moveMusic(base, id: id, start: piece.start, grab: pointed.output - piece.start))
        case let .edge(id, edge):
            guard let base = begin(), let piece = item(id, in: base.document) else { return cancelMusicStart() }
            drag = .music(.trimMusic(base, id: id, edge: edge, from: edge == .start ? piece.start : min(piece.end, base.map.duration)))
        case let .slip(id):
            guard let base = begin(), let piece = item(id, in: base.document) else { return cancelMusicStart() }
            drag = .music(.slipMusic(base, id: id, offset: piece.offset, anchor: pointed.output, length: model.musicLength(of: piece.source)))
        case let .gainLine(id):
            guard let base = begin() else { return cancelMusicStart() }
            drag = .music(.musicGain(base, id: id))
        }
    }

    private func cancelMusicStart() {
        drag = .none
    }

    private func updateMusicDrag(_ music: MusicDrag, _ event: NSEvent) {
        let point = point(event)
        var step: EditStep?
        var label: String?
        switch music {
        case .pressed:
            return
        case let .moveMusic(base, id, start, grab):
            // Its start snaps, and its end, whichever is nearer what it snaps to.
            let proposed = output(at: point) - grab
            let length = (base.document.music.items.first { $0.id == id }).map { $0.end - $0.start } ?? 0
            let startSnapped = snapped(proposed, event: event, base: base)
            let endSnapped = snapped(proposed + length, event: event, base: base) - length
            let τ = abs(endSnapped - proposed) < abs(startSnapped - proposed) ? endSnapped : startSnapped
            step = MusicCommands.move(base.document, id: id, toOutputStart: τ, timeMap: base.map)
            let now = step.flatMap { try? base.document.applying($0.changes) }?.music.items.first { $0.id == id }?.start ?? start
            label = TimelineDragRules.trimLabel(delta: now - start, position: now, total: base.map.duration, locale: .current)
            NSCursor.closedHand.set()
        case let .trimMusic(base, id, edge, from):
            let τ = snapped(output(at: point), event: event, base: base)
            step = MusicCommands.trim(base.document, id: id, edge: edge, toOutput: τ, timeMap: base.map)
            let moved = step.flatMap { try? base.document.applying($0.changes) }?.music.items.first { $0.id == id }
            let now = moved.map { edge == .start ? $0.start : min($0.end, base.map.duration) } ?? from
            label = TimelineDragRules.trimLabel(delta: now - from, position: now, total: base.map.duration, locale: .current)
            NSCursor.resizeLeftRight.set()
        case let .slipMusic(base, id, offset, anchor, length):
            // The music follows the pointer: dragged right, what played before plays here.
            let (moved, overflow) = offset.subtractingReportingOverflow(output(at: point) - anchor)
            step = MusicCommands.slip(base.document, id: id, offset: overflow ? 0 : moved, themeLength: length)
            let now = step.flatMap { try? base.document.applying($0.changes) }?.music.items.first { $0.id == id }?.offset ?? offset
            label = Timecode.duration(Double(now) / 1e9)
            NSCursor.closedHand.set()
        case let .musicGain(base, id):
            guard let area = view.musicRowArea() else { return }
            let gain = AudioRowGeometry.gain(atY: point.y - area.top, height: area.height)
            step = MusicCommands.change(base.document, id: id) { $0.gain = gain }
            label = TimelineAudioItems.gainText(min(max(gain, MusicCommands.gains.lowerBound), MusicCommands.gains.upperBound))
            NSCursor.resizeUpDown.set()
        }
        lastStep = step
        view.setPreview(model?.updateGesture(step))
        if let label { showLabel(label, at: point.x) } else { hideLabel() }
    }

    /// The gesture's last step made, once; the step if it changed the document.
    private func endMusicGesture() -> EditStep? {
        guard let model else { return nil }
        let step = lastStep
        lastStep = nil
        guard model.endGesture() else {
            view.setPreview(nil)
            return nil
        }
        return step
    }

    // MARK: - The menu

    /// The menu of the Music track at `point`: over a piece, "Replace Music…" and "Delete Music" (it is selected
    /// first); on nothing, "Add Music…" (the playhead goes there, and the library's list opens there) and "Import
    /// Audio…".
    func musicMenu(at point: CGPoint) -> NSMenu? {
        guard let model, let pointed = view.musicHit(at: point, option: false) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let id: String? = switch pointed.hit {
        case let .body(id), let .edge(id, _), let .slip(id), let .gainLine(id): id
        case .empty: nil
        }
        if let id {
            model.selection = .musicItem(id)
            let replace = MusicMenuItem(String(localized: "Replace Music…", comment: "The menu of a piece of music: another theme or file plays in its place")) {
                [weak self] in self?.showMusicLibrary(at: point, replacing: id)
            }
            let delete = MusicMenuItem(String(localized: "Delete Music", comment: "The menu of a piece of music of the Music track")) {
                model.deleteMusic(id: id)
            }
            for item in [replace, delete] {
                item.isEnabled = canEdit
                menu.addItem(item)
            }
        } else {
            let τ = clamped(pointed.output)
            let add = MusicMenuItem(String(localized: "Add Music…", comment: "Adds a theme of the library or a file of the user's under the video")) {
                [weak self] in
                model.movePlayhead(toOutput: τ)
                self?.showMusicLibrary(at: point, replacing: nil)
            }
            let file = MusicMenuItem(String(localized: "Import Audio…", comment: "Adds a sound file of the user's (M4A, MP3, WAV, AIFF or CAF) as music")) {
                model.chooseMusicFile(atOutput: τ)
            }
            let room = model.document.flatMap { MusicCommands.roomForNew($0, atOutput: τ, timeMap: TimeMap(sequence: $0.sequence)) } != nil
            for item in [add, file] {
                item.isEnabled = canEdit && room
                menu.addItem(item)
            }
        }
        return menu
    }
}

extension TimelineInteraction {
    /// The library's list (`MusicLibraryPicker`) in a popover at `point` of the timeline (the view's coordinates): to add
    /// a piece at the playhead, or to make piece `replacing` play another.
    func showMusicLibrary(at point: CGPoint, replacing: String?) {
        guard let model, canEdit else { return }
        MusicLibraryPopover.show(model: model, replacing: replacing, at: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2), in: view)
    }
}

/// The popover of the library's list over the timeline, one at a time; it closes when the pointer goes elsewhere.
@MainActor
private final class MusicLibraryPopover: NSObject, NSPopoverDelegate {
    private static var shown: MusicLibraryPopover?
    private let popover = NSPopover()

    static func show(model: EditorModel, replacing: String?, at rect: CGRect, in view: NSView) {
        shown?.popover.close()
        let made = MusicLibraryPopover()
        made.popover.behavior = .transient
        made.popover.delegate = made
        made.popover.contentViewController = NSHostingController(
            rootView: MusicLibraryPicker(model: model, replacing: replacing) { [weak made] in made?.popover.close() })
        shown = made
        made.popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.shown === self { Self.shown = nil }
    }
}

/// A menu item that runs a closure.
private final class MusicMenuItem: NSMenuItem {
    private let body: () -> Void

    init(_ title: String, _ body: @escaping () -> Void) {
        self.body = body
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError()
    }

    @objc private func run() {
        body()
    }
}

// MARK: - Dropping a sound on the Music track

/// A sound file dragged from Finder over the Music track (plan 3c decision 16): while it is over a gap with room for it
/// (`MusicCommands.roomForNew`), the gap is outlined; dropped, it is copied into the project and goes in there
/// (`EditorModel.importMusic`). An M4A, an MP3, a WAV, an AIFF or a CAF; whether it plays is judged as it is imported.
@MainActor
final class TimelineMusicDrop {
    /// The extensions the track takes (`AssetKind.audio`'s, and `aif`).
    static let extensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf"]

    private unowned let view: EditorTimelineView
    private let outline = CALayer()

    init(view: EditorTimelineView) {
        self.view = view
        outline.cornerRadius = 4
        outline.borderWidth = 2
        outline.isHidden = true
        outline.zPosition = 3
        view.overlay.addSublayer(outline)
    }

    /// What a drag over the timeline can do here: copy a sound into a gap of the Music track, outlined.
    func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let target = target(sender) else {
            hide()
            return []
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.borderColor = view.palette.selection
        outline.backgroundColor = view.palette.selection.copy(alpha: 0.12)
        outline.frame = target.rect
        outline.isHidden = false
        CATransaction.commit()
        return .copy
    }

    /// The file was dropped: it is imported and goes into its gap.
    func perform(_ sender: any NSDraggingInfo) -> Bool {
        guard let target = target(sender), let model = view.interaction.model else { return false }
        hide()
        model.importMusic(target.url, atOutput: target.output)
        return true
    }

    func hide() {
        guard !outline.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.isHidden = true
        CATransaction.commit()
    }

    /// The file dragged, where it was dropped and the gap it would go in, in the area's coordinates: one sound file over
    /// the Music track of a document that can be edited, where there is room.
    private func target(_ sender: any NSDraggingInfo) -> (url: URL, output: Int64, rect: CGRect)? {
        guard let model = view.interaction.model, model.canEdit, let document = model.document, let content = view.content,
            let geometry = view.geometry(), let row = geometry.rows.first(where: { $0.track == .music })
        else { return nil }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard urls.count == 1, let url = urls.first, url.isFileURL, Self.extensions.contains(url.pathExtension.lowercased()) else { return nil }
        let point = view.convert(sender.draggingLocation, from: nil)
        let top = TimelineLayout.rulerHeight + row.top - geometry.verticalOffset
        guard point.x >= TimelineLayout.headerWidth, point.y >= top, point.y < top + row.height else { return nil }
        let τ = content.layout.output(atX: point.x, scale: geometry.scale, offset: geometry.offset)
        guard let room = MusicCommands.roomForNew(document, atOutput: τ, timeMap: content.map),
            let rect = geometry.itemRect(room, top: top + 1, height: row.height - 2, gap: 1)
        else { return nil }
        return (url, τ, rect)
    }
}
