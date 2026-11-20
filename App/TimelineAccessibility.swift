// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import Editing
import ProjectFormat

/// What VoiceOver reads of the timeline (design §5.10): the timeline is a container ("Timeline") whose elements are the
/// playhead and each clip, zoom block and camera change in sight, where they are drawn.
///
/// - A clip: "Part from 0:12 to 0:31, speed 2×"; a block: "Automatic zoom of 2×, from 0:40 to 0:44" (or "Zoom of…" for
///   one of the user's; a calm one says its mode, "Zoom of 2×, Loupe, from…"); a change: "Camera change at 0:42"; an annotation: "Text “Hola”, from 0:12 to 0:15" (phase 3),
///   with Duplicate and Delete. Each one is selected with AXPress, as a click selects it, and
///   reads as selected while it is. While the document can be edited, a clip has the actions Split, Delete and Trim
///   Start and Trim End to Playhead (those that need the playhead on the clip do nothing without it), and a block and a
///   change, Delete.
/// - The playhead: "Playhead, 0:42 of 2:14", an element that is adjusted (VoiceOver's increment and decrement) a second
///   at a time, saying where it went.
///
/// The elements are kept while their items are in sight, so VoiceOver's cursor stays on them as the timeline changes.
@MainActor
final class TimelineAccessibility {
    private unowned let view: EditorTimelineView
    private var elements: [String: TimelineItemElement] = [:]
    private lazy var playhead: TimelinePlayheadElement = {
        let element = TimelinePlayheadElement(parent: view)
        element.step = { [weak self] seconds in self?.movePlayhead(seconds) ?? false }
        return element
    }()

    init(view: EditorTimelineView) {
        self.view = view
    }

    private var model: EditorModel? { view.interaction.model }

    /// The playhead, then the items in sight track by track in time order.
    func children() -> [Any] {
        guard let content = view.content, let geometry = view.geometry() else {
            elements = [:]
            return []
        }
        // Where items are seen: right of the headers and under the ruler.
        let area = CGRect(
            x: TimelineLayout.headerWidth, y: TimelineLayout.rulerHeight, width: geometry.areaWidth,
            height: max(view.bounds.height - TimelineLayout.rulerHeight, 0))
        var children: [Any] = [updatedPlayhead(geometry)]
        var kept: [String: TimelineItemElement] = [:]
        func add(_ id: String, _ track: TimelineTrack, _ output: Range<Int64>, label: String, actions: [Action]) {
            guard let drawn = geometry.itemFrame(of: TimelineItem(id: id, track: track, output: output)) else { return }
            let frame = drawn.offsetBy(dx: TimelineLayout.headerWidth, dy: 0).intersection(area)
            guard !frame.isNull, !frame.isEmpty else { return }
            let element = elements[id] ?? TimelineItemElement(parent: view)
            element.setAccessibilityFrameInParentSpace(frame)
            element.setAccessibilityLabel(label)
            element.setAccessibilitySelected(view.selected.contains(id))
            element.press = { [weak self] in self?.select(id, on: track) ?? false }
            element.setAccessibilityCustomActions(model?.canEdit == true ? actions.map { action in
                NSAccessibilityCustomAction(name: action.name) { [weak self] in
                    MainActor.assumeIsolated { self?.run(action.kind, id: id, track: track, output: output) ?? false }
                }
            } : [])
            kept[id] = element
            children.append(element)
        }
        let trim = [Action(.split), Action(.delete), Action(.trimStart), Action(.trimEnd)]
        for clip in content.clips.items {
            // A frozen frame, a title card or an imported clip (phase 3): "Placa «Intro», 3 s", and Delete.
            if let info = content.contentClips.info(clip.id) {
                add(clip.id, .video, clip.output, label: TimelineContentClipItems.accessibilityLabel(info), actions: [Action(.delete)])
                continue
            }
            let label = String(
                format: String(localized: "Part from %1$@ to %2$@, speed %3$@", comment: "VoiceOver: a clip of the timeline, its start, end and speed"),
                Self.time(clip.output.lowerBound), Self.time(clip.output.upperBound), TimelineFormat.multiplier(clip.info.speed))
            add(clip.id, .video, clip.output, label: label, actions: trim)
        }
        for zoom in content.zooms.items {
            let depth = TimelineFormat.multiplier(zoom.info.depth)
            let (start, end) = (Self.time(zoom.output.lowerBound), Self.time(zoom.output.upperBound))
            let label: String
            if zoom.info.mode.isCalm {
                // A calm block says its mode (phase 3 design §6); a Classic one reads as in phase 2.
                let mode = ZoomModeNames.text(zoom.info.mode)
                label = zoom.info.automatic
                    ? String(
                        format: String(
                            localized: "Automatic zoom of %1$@, %2$@, from %3$@ to %4$@",
                            comment: "VoiceOver: an automatic zoom block, its depth, its mode (Highlight, Dim, Loupe), start and end"),
                        depth, mode, start, end)
                    : String(
                        format: String(
                            localized: "Zoom of %1$@, %2$@, from %3$@ to %4$@",
                            comment: "VoiceOver: a zoom block of the user's, its depth, its mode (Highlight, Dim, Loupe), start and end"),
                        depth, mode, start, end)
            } else {
                label = zoom.info.automatic
                    ? String(
                        format: String(localized: "Automatic zoom of %1$@, from %2$@ to %3$@", comment: "VoiceOver: an automatic zoom block, its depth, start and end"),
                        depth, start, end)
                    : String(
                        format: String(localized: "Zoom of %1$@, from %2$@ to %3$@", comment: "VoiceOver: a zoom block of the user's, its depth, start and end"),
                        depth, start, end)
            }
            add(zoom.id, .zoom, zoom.output, label: label, actions: [Action(.delete)])
        }
        for block in content.privacy.items.items {
            let label = TimelinePrivacyItems.accessibilityLabel(block.info, output: block.output)
            add(block.id, .privacy, block.output, label: label, actions: [Action(.delete)])
        }
        for annotation in content.annotations.items.items {
            let label = TimelineAnnotationItems.accessibilityLabel(annotation.info, output: annotation.output)
            add(annotation.id, .annotations, annotation.output, label: label, actions: [Action(.duplicate), Action(.delete)])
        }
        let showInCaptions = [Action(.showInCaptions)]
        content.captions.forEach(from: geometry.visibleOutput.lower, to: geometry.visibleOutput.upper) { caption in
            add(caption.id, .captions, caption.output, label: TimelineCaptionItems.accessibilityLabel(caption.info, output: caption.output), actions: showInCaptions)
        }
        for block in content.layoutBlocks.items {
            let label = String(
                format: String(localized: "Layout %1$@, from %2$@ to %3$@", comment: "VoiceOver: a layout block of the Camera track, its layout, start and end"),
                LayoutNames.name(block.info.kind), Self.time(block.output.lowerBound), Self.time(block.output.upperBound))
            add(block.id, .camera, block.output, label: label, actions: [Action(.changeLayout)] + trim.filter { $0.kind != .split })
        }
        for change in content.cameraChanges.items {
            let label = String(
                format: String(localized: "Camera change at %@", comment: "VoiceOver: a change of the camera's style on the timeline, its time"),
                Self.time(change.output.lowerBound))
            add(change.id, .camera, change.output, label: label, actions: [Action(.delete)])
        }
        // The stretches at another volume of each audio row and the cuts of the sound moved off the picture's (3c): a
        // stretch reads its volume and its times, and is selected and deleted; a cut says where the sound went, on the
        // first audio row, and is put back.
        func addAudio(
            _ key: String, frame drawn: CGRect?, label: String, selected: Bool, press: @escaping @MainActor @Sendable () -> Bool,
            actions: [(name: String, run: @MainActor @Sendable () -> Void)]
        ) {
            guard let drawn else { return }
            let frame = drawn.offsetBy(dx: TimelineLayout.headerWidth, dy: 0).intersection(area)
            guard !frame.isNull, !frame.isEmpty else { return }
            let element = elements[key] ?? TimelineItemElement(parent: view)
            element.setAccessibilityFrameInParentSpace(frame)
            element.setAccessibilityLabel(label)
            element.setAccessibilitySelected(selected)
            element.press = press
            element.setAccessibilityCustomActions(model?.canEdit == true ? actions.map { action in
                NSAccessibilityCustomAction(name: action.name) {
                    MainActor.assumeIsolated { action.run() }
                    return true
                }
            } : [])
            kept[key] = element
            children.append(element)
        }
        let audioRows = geometry.rows.filter { if case .audio = $0.track { true } else { false } }
        for row in audioRows {
            guard case let .audio(track) = row.track else { continue }
            let top = TimelineLayout.rulerHeight + row.top - geometry.verticalOffset + 2
            for range in content.audioRanges[track] ?? [] {
                let label = String(
                    format: String(
                        localized: "Range Volume, %1$@, from %2$@ to %3$@",
                        comment: "VoiceOver: a stretch at another volume of an audio row of the timeline, its volume, start and end"),
                    TimelineAudioItems.gainText(range.gain), Self.time(range.output.lowerBound), Self.time(range.output.upperBound))
                let id = range.id
                addAudio(
                    "range \(track) \(id) \(range.output.lowerBound)", frame: geometry.itemRect(range.output, top: top, height: row.height - 4, gap: 0),
                    label: label, selected: view.selected.contains(id),
                    press: { [weak self] in
                        self?.model?.selection = .gainRange(id)
                        return self != nil
                    },
                    actions: [(String(localized: "Delete Range", comment: "The menu of a stretch at another volume of an audio row"), { @MainActor @Sendable [weak self] in
                        self?.model?.deleteGainRange(track: track, id: id)
                    })])
            }
        }
        if let row = audioRows.first {
            let top = TimelineLayout.rulerHeight + row.top - geometry.verticalOffset + 2
            for cut in content.audioCuts {
                guard let label = Self.cutLabel(cut.audio - cut.picture) else { continue }
                let x = geometry.x(cut.audio), clip = cut.clip
                addAudio(
                    "cut \(clip)", frame: CGRect(x: x - 6, y: top, width: 12, height: row.height - 4), label: label, selected: false,
                    press: { false },
                    actions: [(String(localized: "Reset Audio Cut", comment: "The menu of an audio row: the cut of the sound back to the picture's"), { @MainActor @Sendable [weak self] in
                        self?.model?.setAudioShift(clip: clip, to: 0)
                    })])
            }
        }
        addMarkers(content, geometry, kept: &kept, children: &children)
        elements = kept
        return children
    }

    /// The markers' flags on the ruler (phase 3, 3d plan decision 3), after everything else: "Marker “Intro” at 0:12"
    /// (or "Unnamed marker at 0:40"); pressing one takes the playhead to it, and while the document can be edited it has
    /// Rename… and Delete, as its menu.
    private func addMarkers(
        _ content: TimelineContent, _ geometry: TimelineGeometry, kept: inout [String: TimelineItemElement], children: inout [Any]
    ) {
        let ruler = CGRect(x: TimelineLayout.headerWidth, y: 0, width: geometry.areaWidth, height: TimelineLayout.rulerHeight)
        for marker in content.markers {
            let x = TimelineLayout.headerWidth + geometry.snapped(geometry.x(marker.output))
            let frame = CGRect(x: x - 3, y: 0, width: TimelineRuler.flagWidth + 6, height: TimelineLayout.rulerHeight).intersection(ruler)
            guard !frame.isNull, !frame.isEmpty else { continue }
            let key = "marker \(marker.id)"
            let element = elements[key] ?? TimelineItemElement(parent: view)
            element.setAccessibilityFrameInParentSpace(frame)
            let time = Self.time(marker.output)
            element.setAccessibilityLabel(marker.name.isEmpty
                ? String(format: String(localized: "Unnamed marker at %@", comment: "VoiceOver: a marker without a name on the timeline's ruler, its time"), time)
                : String(
                    format: String(localized: "Marker “%1$@” at %2$@", comment: "VoiceOver: a marker on the timeline's ruler, its name and its time"),
                    marker.name, time))
            element.setAccessibilitySelected(false)
            element.press = { [weak self] in
                guard let model = self?.model else { return false }
                model.goTo(marker)
                return true
            }
            element.setAccessibilityCustomActions(model?.canEdit == true ? [
                NSAccessibilityCustomAction(name: String(localized: "Rename…", comment: "The menu of a marker's flag on the timeline's ruler")) {
                    [weak self] in
                    MainActor.assumeIsolated { self?.view.interaction.askMarkerName(marker) }
                    return true
                },
                NSAccessibilityCustomAction(name: String(localized: "Delete")) { [weak self] in
                    MainActor.assumeIsolated { self?.model?.deleteMarker(marker) }
                    return true
                },
            ] : [])
            kept[key] = element
            children.append(element)
        }
    }

    /// What VoiceOver says of a cut of the sound moved `shift` ns of output off the picture's: "Audio cut moved 0,30 s
    /// earlier" (a J cut) or "… later" (an L cut); `nil` at the picture's.
    static func cutLabel(_ shift: Int64) -> String? {
        let amount = AudioRowText.shift(shift, locale: .current)
        switch AudioRowText.cut(shift) {
        case .j?:
            return String(
                format: String(localized: "Audio cut moved %@ earlier", comment: "VoiceOver: a J cut of the timeline, how much sooner the next clip is heard"),
                amount)
        case .l?:
            return String(
                format: String(localized: "Audio cut moved %@ later", comment: "VoiceOver: an L cut of the timeline, how much longer the clip before is heard"),
                amount)
        case nil:
            return nil
        }
    }

    /// An output time as VoiceOver reads it: whole seconds, `0:42`.
    private static func time(_ τ: Int64) -> String {
        Timecode.duration(Double(τ) / 1e9)
    }

    // MARK: - The playhead

    private func updatedPlayhead(_ geometry: TimelineGeometry) -> TimelinePlayheadElement {
        let x = TimelineLayout.headerWidth + geometry.x(view.playhead)
        playhead.setAccessibilityFrameInParentSpace(CGRect(x: x - 4, y: 0, width: 9, height: view.bounds.height))
        playhead.setAccessibilityLabel(playheadLabel())
        return playhead
    }

    private func playheadLabel() -> String {
        guard let model else { return "" }
        return String(
            format: String(localized: "Playhead, %1$@ of %2$@", comment: "VoiceOver: the timeline's playhead, its time and what the output lasts"),
            Timecode.duration(model.currentSeconds), Timecode.duration(model.durationSeconds))
    }

    /// A second later or earlier, said once it is there.
    private func movePlayhead(_ seconds: Int) -> Bool {
        guard let model, model.step(seconds: seconds) else { return false }
        let label = playheadLabel()
        playhead.setAccessibilityLabel(label)
        NSAccessibility.post(
            element: playhead, notification: .announcementRequested,
            userInfo: [.announcement: label, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        return true
    }

    // MARK: - Actions

    private struct Action {
        enum Kind { case split, delete, trimStart, trimEnd, changeLayout, showInCaptions, duplicate }
        let kind: Kind
        init(_ kind: Kind) { self.kind = kind }

        var name: String {
            switch kind {
            case .split: String(localized: "Split")
            case .delete: String(localized: "Delete")
            case .trimStart: String(localized: "Trim Start to Playhead", comment: "VoiceOver: an action of a clip: its start trimmed up to the playhead")
            case .trimEnd: String(localized: "Trim End to Playhead", comment: "VoiceOver: an action of a clip: its end trimmed up to the playhead")
            case .changeLayout: String(localized: "Change Layout")
            case .showInCaptions: String(localized: "Show in Captions", comment: "VoiceOver: an action of a caption of the timeline: its first word is shown in the Captions tab")
            case .duplicate: String(localized: "Duplicate")
            }
        }
    }

    /// AXPress: the item is the one selected, as a click selects it.
    private func select(_ id: String, on track: TimelineTrack) -> Bool {
        guard let model else { return false }
        switch track {
        case .video: model.selection = .clips([id])
        case .zoom: model.selection = .zooms([id])
        case .camera:
            if view.content?.layoutBlockIDs.contains(id) == true {
                model.selection = .layoutBlock(id)
            } else {
                // A change of the bubble, as a click and the Camera tab's list select one: the playhead goes onto it.
                guard let output = view.hitItems.first(where: { $0.id == id })?.output.lowerBound else { return false }
                model.selectCameraChange(id, output: output)
            }
        case .privacy: model.selection = .privacyBlocks([id])
        case .captions: return showInCaptions(id)
        case .annotations: model.selection = .annotations([id])
        case .ruler, .screen, .audio, .importedAudio, .music: return false
        }
        return true
    }

    /// A caption is not selected: pressing it, as its action, shows its first word in the Captions tab.
    private func showInCaptions(_ id: String) -> Bool {
        guard let model, let ref = view.content?.captions.items.first(where: { $0.id == id })?.info.words.first?.ref else { return false }
        model.voice.reveal(ref)
        return true
    }

    private func run(_ action: Action.Kind, id: String, track: TimelineTrack, output: Range<Int64>) -> Bool {
        guard let model else { return false }
        let isBlock = track == .camera && view.content?.layoutBlockIDs.contains(id) == true
        // Split and trim the clip under the playhead: this one, only if the playhead is on it.
        let onIt = output.lowerBound < model.playheadNanoseconds && model.playheadNanoseconds < output.upperBound
        switch action {
        case .split:
            guard onIt else { return false }
            model.split(atOutput: model.playheadNanoseconds)
            return true
        case .trimStart:
            return onIt && (isBlock ? model.trimLayoutBlock(id, edge: .start) : model.trimToPlayhead(.start))
        case .trimEnd:
            return onIt && (isBlock ? model.trimLayoutBlock(id, edge: .end) : model.trimToPlayhead(.end))
        case .changeLayout:
            guard isBlock, let geometry = view.geometry(),
                let frame = geometry.itemFrame(of: TimelineItem(id: id, track: track, output: output))
            else { return false }
            view.interaction.popLayoutMenu(id: id, at: CGPoint(x: TimelineLayout.headerWidth + frame.minX, y: frame.maxY))
            return true
        case .showInCaptions:
            return showInCaptions(id)
        case .delete:
            guard select(id, on: track) else { return false }
            view.interaction.deleteSelected()
            return true
        case .duplicate:
            guard select(id, on: track) else { return false }
            model.duplicateSelectedAnnotations()
            return true
        }
    }
}

/// A clip, a block or a change: AXPress selects it. VoiceOver asks on the main thread.
private final class TimelineItemElement: NSAccessibilityElement {
    var press: @MainActor @Sendable () -> Bool = { false }

    init(parent: NSView) {
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(.button)
    }

    override func accessibilityPerformPress() -> Bool {
        let press = press
        return MainActor.assumeIsolated { press() }
    }
}

/// The playhead: increment and decrement move it. VoiceOver asks on the main thread.
private final class TimelinePlayheadElement: NSAccessibilityElement {
    var step: @MainActor @Sendable (Int) -> Bool = { _ in false }

    init(parent: NSView) {
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(.incrementor)
    }

    override func accessibilityPerformIncrement() -> Bool {
        let step = step
        return MainActor.assumeIsolated { step(1) }
    }

    override func accessibilityPerformDecrement() -> Bool {
        let step = step
        return MainActor.assumeIsolated { step(-1) }
    }
}
