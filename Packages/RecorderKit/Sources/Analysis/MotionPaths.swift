// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The motion of one revision of the document (design §8.6): its time map, where things are on the stage, the drawn
/// cursor's path and the zoom camera's, which follows that cursor. Built once per revision, off the main thread, and
/// shared by the preview and the export at any size they draw: everything is in output time and stage units.
public struct MotionPaths: Sendable {
    public let timeMap: TimeMap
    public let stage: StagePoints
    public let cursor: CursorPath
    public let zoom: ZoomCameraPath

    public init(take: TakeRecord, events: [InputEvent], document: EditDocument) {
        timeMap = TimeMap(sequence: document.sequence)
        stage = StagePoints(take: take, events: events, document: document)
        cursor = CursorPath(take: take, events: events, style: document.cursor, timeMap: timeMap)
        zoom = ZoomCameraPath(document: document, timeMap: timeMap, stage: stage, cursor: cursor, take: take)
    }
}
