// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import ProjectFormat

/// The motion of one revision of the document (design §8.6): its time map, where things are on the stage, the drawn
/// cursor's path and the zoom camera's, which follows that cursor, and, with a split, the zoom inside the screen's card
/// (1c design §5.4). Built once per revision (from those of the revision before it after an edit,
/// `init(take:events:document:after:)`), off the main thread, and shared by the preview and the export at any size they
/// draw: everything is in output time and stage units (the card's zoom, in fractions of the screen).
public struct MotionPaths: Sendable {
    public let timeMap: TimeMap
    public let stage: StagePoints
    public let cursor: CursorPath
    public let zoom: ZoomCameraPath
    /// `nil` when the document has no split (`CardZoomPath`).
    public let cardZoom: CardZoomPath?
    /// What of the document they were built from.
    private let inputs: Inputs

    /// `cameraReadable`: some camera track of the take can be read (plan decision 40, `LayoutTimeline.cameraReadable`),
    /// as the render is told (`FrameRenderer.cameraReadable`): the zoom camera's layouts see the camera as the render
    /// does (`ZoomCameraPath`).
    public init(take: TakeRecord, events: [InputEvent], document: EditDocument, cameraReadable: Bool = true) {
        timeMap = TimeMap(sequence: document.sequence)
        stage = StagePoints(take: take, events: events, document: document)
        cursor = CursorPath(take: take, events: events, style: document.cursor, timeMap: timeMap)
        zoom = ZoomCameraPath(
            document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take, cameraReadable: cameraReadable)
        cardZoom = CardZoomPath(document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take)
        inputs = Inputs(document, cameraReadable: cameraReadable)
    }

    /// The paths of `document` after an edit of the document `old` was built from, of the same take and events (design
    /// §8.6): bit for bit the paths `init(take:events:document:)` builds, so every query, at a point or over a span,
    /// gives the same bits, built from what of `old` the edit leaves as it was. That is `old` itself when the edit
    /// touches nothing they read (`areThePaths(of:)`). Otherwise each of the cursor's spring, the zoom camera and the
    /// card's keeps `old`'s checkpoints before the first step the edit can change for it, a second earlier for what
    /// reads ahead (`StepGrid.checkpointsKept(changingFrom:)`), and simulates only from there; that step is the first
    /// at which one of its inputs differs:
    ///
    /// - The time map: the start of the first clip that differs, or the end of the shorter one when only its end does
    ///   (a trim or a cut inside it); every camera reads the source instant shown on each of its steps.
    /// - The cursor (`CursorPath.rebuilt`): the first raw position, button change or click it places otherwise, the
    ///   end of the shorter output, and the whole of it with another smoothing. Its raw inputs are `old`'s over the
    ///   same time map, and its idle opacity too with the same idle settings.
    /// - The zoom's blocks on the grid and its spring, which each camera compares itself; the take's camera bubble for
    ///   the stage's camera (its first change placed otherwise; the whole of it when it shows or starts otherwise), and
    ///   the layouts it reads that bubble from where a Bubble span rules (`firstChangedLayoutOutput`).
    /// - The stage (the screens, the aspect, the padding and whether there is a window frame): the whole of both
    ///   cameras, and it is built again.
    /// - For the card's camera, the layouts only decide whether there is one: one that was not there is simulated from
    ///   output 0.
    ///
    /// After an edit of zoom blocks alone, each camera also takes the old one's tail from the first checkpoint after the
    /// blocks it changed on which it is the old camera again, bit for bit (`ZoomSimulation`). The stage's camera and the
    /// card's are built at once, on two threads: they read the same cursor and stage and nothing of each other.
    ///
    /// Built off the main thread, like `init(take:events:document:cameraReadable:)`, with the camera readable as there.
    public init(
        take: TakeRecord, events: [InputEvent], document: EditDocument, after old: MotionPaths, cameraReadable: Bool = true
    ) {
        let inputs = Inputs(document, cameraReadable: cameraReadable)
        guard inputs != old.inputs else {
            self = old
            return
        }
        let timeMap = TimeMap(sequence: document.sequence)
        let sameStage = inputs.stage == old.inputs.stage
        let stage = sameStage ? old.stage : StagePoints(take: take, events: events, document: document)
        let (cursor, cursorChanged) = CursorPath.rebuilt(
            after: old.cursor, take: take, events: events, style: document.cursor, timeMap: timeMap)
        let timeChanged = Self.firstChangedOutput(old.inputs.sequence, old.timeMap, document.sequence, timeMap)
            .map(StepGrid.firstStep(atOrAfter:))
        // What both cameras read besides their blocks and spring.
        let changed = sameStage ? [timeChanged, cursorChanged].compactMap { $0 }.min() : 0
        let bubbleChanged = Self.firstChangedBubbleOutput(
            old.inputs.camera, old.timeMap, document.camera, timeMap, take: take.id).map(StepGrid.firstStep(atOrAfter:))
        let layouts = ZoomCameraPath.layouts(of: document, take: take, timeMap: timeMap, cameraReadable: cameraReadable)
        let layoutsChanged = Self.firstChangedLayoutOutput(
            old.zoom.layouts, layouts, sameSpring: old.inputs.camera.spring == document.camera.spring
        ).map(StepGrid.firstStep(atOrAfter:))
        let zoomChanged = [changed, bubbleChanged, layoutsChanged].compactMap { $0 }.min()
        (zoom, cardZoom) = Self.atOnce(
            {
                ZoomCameraPath(
                    document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take, after: old.zoom,
                    changedFrom: zoomChanged, layouts: layouts)
            },
            {
                CardZoomPath(
                    document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take, after: old.cardZoom,
                    changedFrom: changed)
            })
        self.timeMap = timeMap
        self.stage = stage
        self.cursor = cursor
        self.inputs = inputs
    }

    /// `a()` and `b()`, run at once on two threads (`DispatchQueue.concurrentPerform`, which returns when both are done):
    /// for work that shares nothing it writes, which gives what running them one after the other gives.
    private static func atOnce<A: Sendable, B: Sendable>(_ a: @Sendable () -> A, _ b: @Sendable () -> B) -> (A, B) {
        let first = Slot<A>(), second = Slot<B>()
        DispatchQueue.concurrentPerform(iterations: 2) { k in
            if k == 0 { first.value = a() } else { second.value = b() }
        }
        // `concurrentPerform` returned: both were written, each by one thread, before this reads them.
        return (first.value!, second.value!)
    }

    /// Whether these are the paths of `document` too (of the same take and events, with the camera as readable): it
    /// differs from the one they were built from in nothing they read (the clips, the screens, the aspect, the window
    /// frame and the padding, the cursor, the zoom and the camera, whose layouts decide whether there is a card's zoom and
    /// where the stage's keeps the cursor from the bubble), as after an edit of the background, the shadow or the corners.
    /// Then a new revision keeps them rather than building them again (about 100 ms for an hour of take).
    public func areThePaths(of document: EditDocument) -> Bool {
        inputs == Inputs(document, cameraReadable: inputs.cameraReadable)
    }

    /// Everything of a document the paths read (`StagePoints`, `CursorPath`, `ZoomCameraPath`, `CameraBubble`, the
    /// layouts, and `CardZoomPath`: the project's layout and the blocks', which make a split, over the same stage, cursor
    /// and zoom), and whether the camera can be read.
    private struct Inputs: Equatable, Sendable {
        let sequence: [Clip]
        let screens: ScreenPlan
        let aspect: Aspect
        let frame: WindowFrame
        let padding: Double
        let cursor: CursorStyle
        let zoom: ZoomPlan
        /// With `layout` and `layouts`.
        let camera: CameraPlan
        let cameraReadable: Bool

        init(_ document: EditDocument, cameraReadable: Bool) {
            sequence = document.sequence
            screens = document.screens
            aspect = document.aspect
            frame = document.style.frame
            padding = document.style.padding
            cursor = document.cursor
            zoom = document.zoom
            camera = document.camera
            self.cameraReadable = cameraReadable
        }

        /// What `StagePoints` reads: the screens, the aspect, the padding and whether there is a window frame (its
        /// appearance, title and buttons are only drawn).
        var stage: Stage {
            let framed = switch frame {
            case .none: false
            case .macWindow: true
            }
            return Stage(screens: screens, aspect: aspect, padding: padding, framed: framed)
        }

        struct Stage: Equatable {
            let screens: ScreenPlan
            let aspect: Aspect
            let padding: Double
            let framed: Bool
        }
    }

    // MARK: - What an edit changes

    /// The first output instant at which `new` (`newMap`) can show another source instant than `old` (`oldMap`) or
    /// place one at another output time: the start of the first clip that differs (in its take, source range or speed),
    /// or, when it differs only in its end, the end of the shorter of the two (before it, both show the same instants of
    /// the same clip, but for the last few nanoseconds of the shorter one, held to its last source instant, which the
    /// second `StepGrid.checkpointsKept(changingFrom:)` goes back leaves room for); where the shorter sequence ends when
    /// one goes on after the other. `nil` when they are the same. A clip's ID is not read.
    static func firstChangedOutput(_ old: [Clip], _ oldMap: TimeMap, _ new: [Clip], _ newMap: TimeMap) -> Int64? {
        for (k, (a, b)) in zip(old, new).enumerated() {
            guard a.take != b.take || a.start != b.start || a.end != b.end || a.speed != b.speed else { continue }
            let start = oldMap.clipOutputStarts[k]
            guard a.take == b.take, a.start == b.start, a.speed == b.speed else { return start }
            return start + min(TimeMap.outputDuration(of: a), TimeMap.outputDuration(of: b))
        }
        guard old.count != new.count else { return nil }
        return min(oldMap.duration, newMap.duration)
    }

    /// The first output instant at which the camera the stage's zoom keeps the cursor from (`ZoomCameraPath`'s notes) can
    /// differ between the layouts `old` and `new` (`ZoomCameraPath.layouts`), the take's bubble aside: `nil` when both are
    /// trivial (that bubble alone in both); 0 with another spring (`sameSpring` false); otherwise the start of the first
    /// span that differs but for where it ends (or that only one has). Before it, the span that rules and every span a
    /// transition there reads are the same in both, and a trivial document's bubble is the settled one of the project's
    /// Bubble span, so the camera is too. `nil` when every span is the same.
    static func firstChangedLayoutOutput(_ old: LayoutTimeline, _ new: LayoutTimeline, sameSpring: Bool) -> Int64? {
        guard !old.isTrivial || !new.isTrivial else { return nil }
        guard sameSpring else { return 0 }
        func start(_ span: LayoutSpan) -> LayoutSpan {
            var start = span
            start.output = span.output.lowerBound..<span.output.lowerBound
            return start
        }
        let common = min(old.spans.count, new.spans.count)
        let k = (0..<common).first { start(old.spans[$0]) != start(new.spans[$0]) } ?? common
        return [old.spans, new.spans].compactMap { k < $0.count ? $0[k].output.lowerBound : nil }.min()
    }

    /// The first output instant at which the take's camera bubble (`CameraBubble`) of `new` over `newMap` can differ
    /// from that of `old` over `oldMap`: `nil` when neither shows one, 0 when only one does, or the take's initial style
    /// or what the bubble is measured against (`sizeReference`) differs, otherwise the time of the first of the take's
    /// changes, in output time and in order (`CameraStyleTimeline`), that differs (a bubble at an instant reads the changes
    /// up to it), `nil` without one.
    static func firstChangedBubbleOutput(
        _ old: CameraPlan, _ oldMap: TimeMap, _ new: CameraPlan, _ newMap: TimeMap, take: String
    ) -> Int64? {
        guard old.show || new.show else { return nil }
        guard old.show == new.show, old.initial[take] == new.initial[take], old.sizeReference == new.sizeReference else { return 0 }
        /// The take's changes as `CameraBubble` places them, in the order `CameraStyleTimeline` reads them.
        func placed(_ camera: CameraPlan, _ map: TimeMap) -> [(t: Int64, style: CameraStyle)] {
            camera.changes.filter { $0.take == take }
                .compactMap { change in map.output(ofChangeAt: change.t, take: take).map { ($0, change.style) } }
                .enumerated()
                .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
                .map(\.element)
        }
        let (a, b) = (placed(old, oldMap), placed(new, newMap))
        let common = min(a.count, b.count)
        let i = (0..<common).first { a[$0].t != b[$0].t || a[$0].style != b[$0].style } ?? common
        return [a, b].compactMap { i < $0.count ? $0[i].t : nil }.min()
    }
}

/// One result of `MotionPaths.atOnce(_:_:)`: written by one thread, read once that thread is done.
private final class Slot<Value>: @unchecked Sendable {
    var value: Value?
}
