// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The motion of one revision of the document (design §8.6): its time map, where things are on the stage, the drawn
/// cursor's path and the zoom camera's, which follows that cursor, and, with a split, the zoom inside the screen's card
/// (1c design §5.4). Built once per revision, off the main thread, and shared by the preview and the export at any size
/// they draw: everything is in output time and stage units (the card's zoom, in fractions of the screen).
public struct MotionPaths: Sendable {
    public let timeMap: TimeMap
    public let stage: StagePoints
    public let cursor: CursorPath
    public let zoom: ZoomCameraPath
    /// `nil` when the document has no split (`CardZoomPath`).
    public let cardZoom: CardZoomPath?
    /// What of the document they were built from.
    private let inputs: Inputs

    public init(take: TakeRecord, events: [InputEvent], document: EditDocument) {
        timeMap = TimeMap(sequence: document.sequence)
        stage = StagePoints(take: take, events: events, document: document)
        cursor = CursorPath(take: take, events: events, style: document.cursor, timeMap: timeMap)
        zoom = ZoomCameraPath(document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take)
        cardZoom = CardZoomPath(document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take)
        inputs = Inputs(document)
    }

    /// Whether these are the paths of `document` too (of the same take and events): it differs from the one they were
    /// built from in nothing they read (the clips, the screens, the aspect, the window frame and the padding, the cursor,
    /// the zoom and the camera, whose layouts decide whether there is a card's zoom), as after an edit of the background,
    /// the shadow or the corners. Then a new revision keeps them rather than building them again (about 100 ms for an
    /// hour of take).
    public func areThePaths(of document: EditDocument) -> Bool {
        inputs == Inputs(document)
    }

    /// Everything of a document the paths read (`StagePoints`, `CursorPath`, `ZoomCameraPath`, `CameraBubble`, and
    /// `CardZoomPath`: the project's layout and the blocks', which make a split, over the same stage, cursor and zoom).
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

        init(_ document: EditDocument) {
            sequence = document.sequence
            screens = document.screens
            aspect = document.aspect
            frame = document.style.frame
            padding = document.style.padding
            cursor = document.cursor
            zoom = document.zoom
            camera = document.camera
        }
    }
}
