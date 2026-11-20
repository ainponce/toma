// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat

/// The mouse on an audio row (phase 3 design §7.2 and §7.3, plan 3c decisions 13 and 14), on top of `AudioRowRules` and
/// `AudioRangeCommands`:
///
/// - Dragging the volume line outside the stretches changes the row's volume (`TrackCommands.setTrackGain`, −∞ to +6 dB);
///   inside one, the stretch's (−∞ to +12 dB). The line sticks to 0 dB.
/// - Dragging over the waveform marks a stretch: only in the view, with its capsule "0 dB", until the first drag of its
///   line or a number typed in the capsule (double click) makes it (`audio.range`); its edges and a stretch's trim it.
///   A click in a stretch selects it; ⌫ deletes it; Esc gives the mark up.
/// - ⌥ and a drag within 4 pt of a cut between two clips moves the cut of the sound: earlier is a J cut, later an L cut;
///   it sticks to the picture's cut within 4 pt, and its notch follows. A double click on the notch, or "Reset Audio
///   Cut", puts it back.
///
/// Each drag that edits is one gesture of the model, as the other drags of the timeline (`TimelineInteraction`).
extension TimelineInteraction {
    enum AudioDrag {
        /// Pressed, not yet dragged.
        case pressed(AudioRowPointed, down: CGPoint)
        /// Over the waveform: the stretch it marks (no gesture: nothing changes until it is made).
        case markRange(Base, track: String, anchor: Int64)
        /// An edge of the marked stretch; `other` is the edge that stays.
        case trimMark(Base, track: String, other: Int64)
        /// The volume line of stretch `id`; of the marked stretch over `marked`, which its first change makes as `id`.
        case rangeGain(Base, track: String, id: String, marked: Range<Int64>?)
        /// An edge of stretch `id`, from where it was.
        case trimRange(Base, track: String, id: String, edge: ClipEdge, from: Int64)
        case rowGain(Base, track: String, takes: [String])
        /// ⌥ at a cut: the cut of the sound at the start of clip `clip`, `shift` when it started, the drag from `anchor`.
        case audioCut(Base, clip: Int, shift: Int64, anchor: Int64, takeBounds: [String: ClosedRange<HostTime>])
    }

    private var audioRows: TimelineAudioRows { view.tracks.audioRows }

    // MARK: - The mouse

    /// A press at `point` on what `hit` says: whether an audio row took it (a press anywhere else gives up the mark).
    func audioMouseDown(_ event: NSEvent, at point: CGPoint, hit: TimelineHit) -> Bool {
        guard case .empty(.audio, _) = hit, let pointed = view.audioHit(at: point, option: event.modifierFlags.contains(.option))
        else {
            setMark(nil)
            return false
        }
        if event.clickCount >= 2 {
            if let capsule = view.audioCapsule, capsule.frame.insetBy(dx: -2, dy: -2).contains(point) {
                drag = .none
                editCapsule(capsule)
                return true
            }
            if canEdit, let clip = view.movedCut(nearX: point.x) {
                drag = .none
                model?.setAudioShift(clip: clip, to: 0)
                return true
            }
        }
        switch pointed.hit {
        case let .rangeLine(id), let .rangeEdge(id, _):
            if id != TimelineAudioRows.markID { model?.selection = .gainRange(id) }
        case .rowLine, .audioCut, .empty:
            break
        }
        drag = .audio(.pressed(pointed, down: point))
        return true
    }

    func audioMouseDragged(_ audio: AudioDrag, _ event: NSEvent) {
        guard case let .pressed(pointed, down) = audio else {
            updateAudioDrag(audio, event)
            return
        }
        guard TimelineDragRules.isDrag(from: down, to: point(event)) else { return }
        startAudioDrag(pointed, event)
        if case let .audio(started) = drag { updateAudioDrag(started, event) }
    }

    func audioMouseUp(_ audio: AudioDrag, _ event: NSEvent) {
        switch audio {
        case let .pressed(pointed, _):
            audioClick(pointed, at: point(event))
        case .markRange, .trimMark:
            // A stretch too short to be made is none; marking one that short is a click.
            let short = audioRows.mark.map { $0.output.upperBound - $0.output.lowerBound < AudioRangeCommands.minimumDuration } ?? true
            guard short else { break }
            setMark(nil)
            if case .markRange = audio {
                view.scrub(at: point(event).x)
                view.endScrub()
            }
        case let .rangeGain(_, track, id, marked):
            if let step = endAudioGesture() {
                model?.selection = .gainRange(step.target)
            } else if let marked, let sequence = model?.document?.sequence {
                // Nothing made: the mark is still there.
                setMark((track, marked, sequence))
                if model?.selection == .gainRange(id) { model?.selection = nil }
            }
        case let .trimRange(_, _, id, _, _):
            if endAudioGesture() != nil { model?.selection = .gainRange(id) }
        case .rowGain:
            _ = endAudioGesture()
        case let .audioCut(base, clip, shift, anchor, takeBounds):
            audioRows.draggedCut = nil
            view.needsLayout = true
            let held = heldShift(base, clip: clip, shift: shift, anchor: anchor, takeBounds: takeBounds, at: point(event))
            if endAudioGesture() != nil { announceCut(held) }
        }
    }

    /// Esc during an audio drag: what it edited is given up, and so is a stretch it was marking.
    func cancelAudioDrag(_ audio: AudioDrag) {
        switch audio {
        case .pressed:
            break
        case .markRange, .trimMark:
            setMark(nil)
        case let .rangeGain(_, track, id, marked):
            lastStep = nil
            model?.cancelGesture()
            view.setPreview(nil)
            if let marked, let sequence = model?.document?.sequence {
                setMark((track, marked, sequence))
                if model?.selection == .gainRange(id) { model?.selection = nil }
            }
        case .trimRange, .rowGain, .audioCut:
            lastStep = nil
            model?.cancelGesture()
            view.setPreview(nil)
            audioRows.draggedCut = nil
            view.needsLayout = true
        }
    }

    /// Esc with no drag: gives up the marked stretch, if there is one.
    func cancelAudioMark() -> Bool {
        guard audioRows.mark != nil else { return false }
        setMark(nil)
        return true
    }

    /// The cursor over an audio row: up and down over a volume line, sideways over an edge of a stretch and, with ⌥, over
    /// a cut.
    func setAudioCursor(_ event: NSEvent, at point: CGPoint) {
        guard canEdit, let pointed = view.audioHit(at: point, option: event.modifierFlags.contains(.option)) else { return }
        switch pointed.hit {
        case .rangeLine, .rowLine: NSCursor.resizeUpDown.set()
        case .rangeEdge, .audioCut: NSCursor.resizeLeftRight.set()
        case .empty: NSCursor.arrow.set()
        }
    }

    // MARK: - The drags

    private func startAudioDrag(_ pointed: AudioRowPointed, _ event: NSEvent) {
        guard canEdit, let model, let document = model.document else {
            drag = .none
            return
        }
        let track = pointed.track
        switch pointed.hit {
        case .empty:
            setMark(nil)
            if case .gainRange? = model.selection { model.selection = nil }
            drag = .audio(.markRange(plainBase(document), track: track, anchor: pointed.output))
        case let .rangeEdge(id, edge) where id == TimelineAudioRows.markID:
            guard let mark = audioRows.mark else { return cancelStart() }
            let other = edge == .start ? mark.output.upperBound : mark.output.lowerBound
            drag = .audio(.trimMark(plainBase(document), track: track, other: other))
        case let .rangeLine(id) where id == TimelineAudioRows.markID:
            guard let mark = audioRows.mark, let base = begin() else { return cancelStart() }
            // Made by its first change: selected under the id it is made with, and no longer a mark.
            let id = EditorModel.newID("g-")
            setMark(nil)
            model.selection = .gainRange(id)
            drag = .audio(.rangeGain(base, track: track, id: id, marked: mark.output))
        case let .rangeLine(id):
            guard let base = begin() else { return cancelStart() }
            drag = .audio(.rangeGain(base, track: track, id: id, marked: nil))
        case let .rangeEdge(id, edge):
            guard let shown = view.content?.audioRanges[track]?.filter({ $0.id == id }), let first = shown.first,
                let base = begin()
            else { return cancelStart() }
            let from = edge == .start ? first.output.lowerBound : shown.map(\.output.upperBound).max() ?? first.output.upperBound
            drag = .audio(.trimRange(base, track: track, id: id, edge: edge, from: from))
        case .rowLine:
            guard let base = begin() else { return cancelStart() }
            let takes = model.audioTracks.first { $0.track == track }?.takes ?? []
            drag = .audio(.rowGain(base, track: track, takes: takes))
        case let .audioCut(clip):
            guard document.sequence.indices.contains(clip), let base = begin() else { return cancelStart() }
            let shift = SequenceRules.audioShift(of: document.sequence, at: clip)
            audioRows.draggedCut = clip
            drag = .audio(.audioCut(base, clip: clip, shift: shift, anchor: pointed.output, takeBounds: model.audioTakeBounds))
        }
    }

    private func cancelStart() {
        drag = .none
    }

    /// What a mark's drag snaps with, without a gesture: nothing changes while a stretch is only marked.
    private func plainBase(_ document: EditDocument) -> Base {
        let map = TimeMap(sequence: document.sequence)
        let points = EditPoints(document: document, timeMap: map, recorded: model?.recordedMarkers ?? [:]).all
        return Base(document: document, map: map, points: points, project: nil, takeBounds: model?.takeBounds ?? [:])
    }

    private func updateAudioDrag(_ audio: AudioDrag, _ event: NSEvent) {
        let point = point(event)
        var step: EditStep?
        var label: String?
        switch audio {
        case .pressed:
            return
        case let .markRange(base, track, anchor):
            let a = clamped(snapped(anchor, event: event, base: base)), b = clamped(snapped(output(at: point), event: event, base: base))
            setMark(a == b ? nil : (track, min(a, b)..<max(a, b), base.document.sequence))
            return
        case let .trimMark(base, track, other):
            let τ = clamped(snapped(output(at: point), event: event, base: base))
            setMark(τ == other ? nil : (track, min(τ, other)..<max(τ, other), base.document.sequence))
            NSCursor.resizeLeftRight.set()
            return
        case let .rangeGain(base, track, id, marked):
            guard let area = view.audioRowArea(track) else { return }
            let gain = AudioRowGeometry.gain(atY: point.y - area.top, height: area.height)
            if let marked {
                // The id it is selected under, unless another stretch has it already.
                var first: String? = id
                step = AudioRangeCommands.addRange(
                    base.document, track: track, takes: takes(of: track), forOutput: marked, gain: gain, timeMap: base.map
                ) { prefix in
                    defer { first = nil }
                    return first ?? EditorModel.newID(prefix)
                }
            } else {
                step = AudioRangeCommands.setGain(base.document, track: track, id: id, gain: gain)
            }
            NSCursor.resizeUpDown.set()
        case let .trimRange(base, track, id, edge, _):
            let τ = snapped(output(at: point), event: event, base: base)
            step = AudioRangeCommands.trim(base.document, track: track, id: id, edge: edge, toOutput: τ, timeMap: base.map)
            NSCursor.resizeLeftRight.set()
        case let .rowGain(base, track, takes):
            guard let area = view.audioRowArea(track) else { return }
            let gain = AudioRowGeometry.trackGain(ofDecibels: AudioRowGeometry.gain(atY: point.y - area.top, height: area.height))
            step = TrackCommands.setTrackGain(base.document, track: track, takes: takes) { $0.gain = gain }
            label = TimelineAudioItems.gainText(AudioRowGeometry.decibels(ofTrackGain: gain))
            NSCursor.resizeUpDown.set()
        case let .audioCut(base, clip, shift, anchor, takeBounds):
            let held = heldShift(base, clip: clip, shift: shift, anchor: anchor, takeBounds: takeBounds, at: point)
            step = AudioRangeCommands.setAudioShift(base.document, clip: clip, to: held, takeBounds: takeBounds)
            label = TimelineAudioItems.cutText(held)
            NSCursor.resizeLeftRight.set()
        }
        lastStep = step
        let preview = model?.updateGesture(step)
        view.setPreview(preview)
        if case let .trimRange(_, track, id, edge, from) = audio, let total = view.content?.map.duration {
            // Where the edge is now, as the timeline shows it.
            let shown = view.content?.audioRanges[track]?.filter { $0.id == id } ?? []
            let now = edge == .start ? shown.map(\.output.lowerBound).min() ?? from : shown.map(\.output.upperBound).max() ?? from
            label = TimelineDragRules.trimLabel(delta: now - from, position: now, total: total, locale: .current)
        }
        if let label { showLabel(label, at: point.x) } else { hideLabel() }
    }

    /// The cut of the sound a drag from `anchor` with the pointer at `point` asks for: `shift` moved as far as the pointer
    /// went, at 0 within 4 pt of the picture's cut, held to what there is of each take (`AudioRangeCommands.shiftLimits`).
    private func heldShift(
        _ base: Base, clip: Int, shift: Int64, anchor: Int64, takeBounds: [String: ClosedRange<HostTime>], at point: CGPoint
    ) -> Int64 {
        let limits = AudioRangeCommands.shiftLimits(base.document, clip: clip, takeBounds: takeBounds)
        let (moved, overflow) = shift.addingReportingOverflow(output(at: point) - anchor)
        var proposed = overflow ? (shift < 0 ? Int64.min : .max) : moved
        if abs(Double(proposed) * view.scale / 1e9) <= AudioRowRules.grab { proposed = 0 }
        return min(max(proposed, limits.lowerBound), limits.upperBound)
    }

    /// The gesture's last step made, once; the step if it changed the document.
    private func endAudioGesture() -> EditStep? {
        guard let model else { return nil }
        let step = lastStep
        lastStep = nil
        guard model.endGesture() else {
            view.setPreview(nil)
            return nil
        }
        return step
    }

    /// A press let go where it was: in the marked stretch, nothing; in a stretch, it is selected; elsewhere the mark goes,
    /// nothing is selected and the playhead goes there.
    private func audioClick(_ pointed: AudioRowPointed, at point: CGPoint) {
        guard let model else { return }
        if case let .rangeLine(id) = pointed.hit, id != TimelineAudioRows.markID { return }
        if case let .rangeEdge(id, _) = pointed.hit, id != TimelineAudioRows.markID { return }
        if let mark = audioRows.mark, mark.track == pointed.track, mark.output.contains(pointed.output) { return }
        setMark(nil)
        if let range = view.content?.audioRanges[pointed.track]?.first(where: { $0.output.contains(pointed.output) }) {
            model.selection = .gainRange(range.id)
            return
        }
        model.selection = nil
        view.scrub(at: point.x)
        view.endScrub()
    }

    private func takes(of track: String) -> [String] {
        model?.audioTracks.first { $0.track == track }?.takes ?? []
    }

    /// The marked stretch is now `mark`, drawn so.
    private func setMark(_ mark: (track: String, output: Range<Int64>, sequence: [Clip])?) {
        guard mark != nil || audioRows.mark != nil else { return }
        audioRows.mark = mark
        view.needsLayout = true
    }

    /// VoiceOver says where the cut of the sound went once a drag moved it.
    private func announceCut(_ shift: Int64) {
        guard let text = TimelineAccessibility.cutLabel(shift) else { return }
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [.announcement: text])
    }

    // MARK: - The capsule

    /// A double click on the capsule: a field over it, the volume to type; Return or leaving it makes it (the marked
    /// stretch at that volume, or the selected one changed), Esc gives it up.
    private func editCapsule(_ capsule: (frame: CGRect, track: String, range: String?)) {
        guard canEdit, let model, let window = view.window else { return }
        for field in view.subviews where field is AudioGainField { field.removeFromSuperview() }
        let current = capsule.range.flatMap { id in view.content?.audioRanges[capsule.track]?.first { $0.id == id }?.gain } ?? 0
        let width = max(capsule.frame.width + 16, 64.0)
        let frame = CGRect(x: capsule.frame.midX - width / 2, y: capsule.frame.midY - 11, width: width, height: 22)
        let field = AudioGainField(frame: frame)
        field.stringValue = AudioRowText.decibels(current, locale: .current) ?? "\u{2212}∞"
        field.setAccessibilityLabel(String(localized: "Range Volume", comment: "The volume of a stretch of an audio row of the timeline, in dB"))
        field.placeholderString = String(localized: "Range Volume", comment: "The volume of a stretch of an audio row of the timeline, in dB")
        let marked = audioRows.mark
        field.onDone = { [weak self, weak model] text in
            guard let self, let model, let text else { return }
            guard let gain = AudioRowText.gain(from: text) else {
                NSSound.beep()
                return
            }
            if let id = capsule.range {
                model.setGainRange(track: capsule.track, id: id, gain: gain)
            } else if let marked, marked.track == capsule.track {
                self.setMark(nil)
                model.addGainRange(track: marked.track, forOutput: marked.output, gain: gain)
            }
        }
        view.addSubview(field)
        window.makeFirstResponder(field)
    }

    // MARK: - The menu

    /// The menu of an audio row at `point`: "Delete Range" over a stretch, "Reset Audio Cut" at a cut of the sound that
    /// moved; nothing elsewhere.
    func audioMenu(at point: CGPoint) -> NSMenu? {
        guard let model, let pointed = view.audioHit(at: point, option: false), let content = view.content else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let range = content.audioRanges[pointed.track]?.first(where: { $0.output.contains(pointed.output) }) {
            model.selection = .gainRange(range.id)
            let delete = AudioMenuItem(String(localized: "Delete Range", comment: "The menu of a stretch at another volume of an audio row")) {
                model.deleteGainRange(track: pointed.track, id: range.id)
            }
            delete.isEnabled = canEdit
            menu.addItem(delete)
        }
        let x = point.x - TimelineLayout.headerWidth
        if let geometry = view.geometry(),
            let cut = content.audioCuts.first(where: { cut in
                guard cut.audio != cut.picture else { return false }
                let (a, b) = (geometry.x(min(cut.audio, cut.picture)), geometry.x(max(cut.audio, cut.picture)))
                return x >= a - AudioRowRules.grab && x <= b + AudioRowRules.grab
            })
        {
            let reset = AudioMenuItem(String(localized: "Reset Audio Cut", comment: "The menu of an audio row: the cut of the sound back to the picture's")) {
                model.setAudioShift(clip: cut.clip, to: 0)
            }
            reset.isEnabled = canEdit
            menu.addItem(reset)
        }
        return menu.items.isEmpty ? nil : menu
    }
}

/// The capsule's field: the volume typed in it is given once, when Return is pressed or the field is left (`nil` with
/// Esc), and the field goes.
final class AudioGainField: NSTextField, NSTextFieldDelegate {
    var onDone: (String?) -> Void = { _ in }
    private var done = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        alignment = .center
        bezelStyle = .roundedBezel
        focusRingType = .default
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finish(nil)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finish(stringValue)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finish(stringValue)
    }

    private func finish(_ text: String?) {
        guard !done else { return }
        done = true
        let timeline = superview
        let onDone = onDone
        removeFromSuperview()
        timeline?.window?.makeFirstResponder(timeline)
        onDone(text)
    }
}

/// A menu item that runs a closure.
private final class AudioMenuItem: NSMenuItem {
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
