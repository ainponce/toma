// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat

/// What VoiceOver reads of the timeline (design §5.10): the timeline is a container ("Timeline") whose elements are the
/// playhead and each clip, zoom block and camera change in sight, where they are drawn.
///
/// - A clip: "Part from 0:12 to 0:31, speed 2×"; a block: "Automatic zoom of 2×, from 0:40 to 0:44" (or "Zoom of…" for
///   one of the user's); a change: "Camera change at 0:42". Each one is selected with AXPress, as a click selects it, and
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
            let label = String(
                format: String(localized: "Part from %1$@ to %2$@, speed %3$@", comment: "VoiceOver: a clip of the timeline, its start, end and speed"),
                Self.time(clip.output.lowerBound), Self.time(clip.output.upperBound), TimelineFormat.multiplier(clip.info.speed))
            add(clip.id, .video, clip.output, label: label, actions: trim)
        }
        for zoom in content.zooms.items {
            let depth = TimelineFormat.multiplier(zoom.info.depth)
            let (start, end) = (Self.time(zoom.output.lowerBound), Self.time(zoom.output.upperBound))
            let label = zoom.info.automatic
                ? String(
                    format: String(localized: "Automatic zoom of %1$@, from %2$@ to %3$@", comment: "VoiceOver: an automatic zoom block, its depth, start and end"),
                    depth, start, end)
                : String(
                    format: String(localized: "Zoom of %1$@, from %2$@ to %3$@", comment: "VoiceOver: a zoom block of the user's, its depth, start and end"),
                    depth, start, end)
            add(zoom.id, .zoom, zoom.output, label: label, actions: [Action(.delete)])
        }
        for change in content.cameraChanges.items {
            let label = String(
                format: String(localized: "Camera change at %@", comment: "VoiceOver: a change of the camera's style on the timeline, its time"),
                Self.time(change.output.lowerBound))
            add(change.id, .camera, change.output, label: label, actions: [Action(.delete)])
        }
        elements = kept
        return children
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
        enum Kind { case split, delete, trimStart, trimEnd }
        let kind: Kind
        init(_ kind: Kind) { self.kind = kind }

        var name: String {
            switch kind {
            case .split: String(localized: "Split")
            case .delete: String(localized: "Delete")
            case .trimStart: String(localized: "Trim Start to Playhead", comment: "VoiceOver: an action of a clip: its start trimmed up to the playhead")
            case .trimEnd: String(localized: "Trim End to Playhead", comment: "VoiceOver: an action of a clip: its end trimmed up to the playhead")
            }
        }
    }

    /// AXPress: the item is the one selected, as a click selects it.
    private func select(_ id: String, on track: TimelineTrack) -> Bool {
        guard let model else { return false }
        switch track {
        case .video: model.selection = .clips([id])
        case .zoom: model.selection = .zooms([id])
        case .camera: model.selection = .cameraChange(id)
        case .ruler, .screen, .audio: return false
        }
        return true
    }

    private func run(_ action: Action.Kind, id: String, track: TimelineTrack, output: Range<Int64>) -> Bool {
        guard let model else { return false }
        // Split and trim the clip under the playhead: this one, only if the playhead is on it.
        let onIt = output.lowerBound < model.playheadNanoseconds && model.playheadNanoseconds < output.upperBound
        switch action {
        case .split:
            guard onIt else { return false }
            model.split(atOutput: model.playheadNanoseconds)
            return true
        case .trimStart:
            return onIt && model.trimToPlayhead(.start)
        case .trimEnd:
            return onIt && model.trimToPlayhead(.end)
        case .delete:
            guard select(id, on: track) else { return false }
            view.interaction.deleteSelected()
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
