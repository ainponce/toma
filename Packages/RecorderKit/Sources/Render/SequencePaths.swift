// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The motion paths of one revision of the document for every take its sequence shows (phase 3 design §9, base plan
/// decision 10): each take's own, `MotionPaths(take:events:document:cameraReadable:)` of that take, its events and the
/// whole document, so each take has its own screens, cursor and zoom camera, and at the border between two takes the
/// zoom's path cuts (each starts where its take's clips put it, at rest before its first block). The paths of the
/// project's own take are always there, shown or not, since a scene always has that take's (`FrameEvaluator`). Every
/// take's stage is the output's (design §9: the stage is laid out with each clip's own screens, in the one output): a
/// take that is not the one of the first clip has its paths built with the ratio `auto` follows
/// (`StageLayout.contentRatio(project:document:)`), its screens fitted inside it. With one take, that take's paths alone,
/// as phase 2 builds them.
///
/// Built off the main thread, as `MotionPaths` is, and shared by the preview and the export at any size they draw.
public struct SequencePaths: Sendable {
    /// By take id: the project's own take, and every other take of the package the sequence shows.
    public let byTake: [String: MotionPaths]
    /// Whether some camera track of each take of `byTake` can be read, as its paths were built with.
    let cameraReadable: [String: Bool]

    /// The paths of `project`'s take and of every other take of the package `document`'s sequence shows
    /// (`LoadedProject.takesShown(by:)`: a take the manifest does not have has none), each with the camera readable as
    /// `cameraReadable` says for its id (`FrameRenderer.cameraReadableByTake`; `true` for an id it does not name, as
    /// `MotionPaths` takes it). A take's paths in `last`, built with the camera readable alike, are kept when they are
    /// `document`'s too (`MotionPaths.areThePaths(of:contentRatio:)`: an edit of the background, the shadow or the
    /// corners), which costs no rebuild; any other take's are built. Reads the events of the takes it builds for (the
    /// disk, the first time): never on the main thread.
    public init(
        project: LoadedProject, document: EditDocument, cameraReadable: [String: Bool], reusing last: SequencePaths? = nil
    ) {
        var byTake: [String: MotionPaths] = [:], readable: [String: Bool] = [:]
        let ratioTake = StageLayout.contentRatioTake(of: document, ownTake: project.take.id)
        let takes = project.takesShown(by: document)
        // The first clip's take first: its stage's ratio, worked out from its own screens, is every other take's
        // (`StageLayout.contentRatio(project:document:)`; none for a take the manifest does not have).
        let ordered = takes.filter { $0.take.id == ratioTake } + [project] + takes.filter { $0.take.id != ratioTake }
        for shown in ordered where byTake[shown.take.id] == nil {
            let id = shown.take.id, camera = cameraReadable[id] ?? true
            readable[id] = camera
            let ratio: Double?? = id == ratioTake ? nil : .some(byTake[ratioTake]?.stage.contentRatio)
            if let old = last?.byTake[id], last?.cameraReadable[id] == camera,
               old.areThePaths(of: document, contentRatio: ratio)
            {
                byTake[id] = old
            } else {
                byTake[id] = MotionPaths(
                    take: shown.take, events: shown.events, document: document, cameraReadable: camera, contentRatio: ratio)
            }
        }
        self.init(byTake: byTake, cameraReadable: readable)
    }

    /// `byTake`, built with the camera readable as `cameraReadable` says for each.
    init(byTake: [String: MotionPaths], cameraReadable: [String: Bool]) {
        self.byTake = byTake
        self.cameraReadable = cameraReadable
    }

    /// Whether these are the paths of `document` too: every take's are (`MotionPaths.areThePaths(of:)`), each of which
    /// reads the whole sequence, so the takes it shows are the same.
    public func areThePaths(of document: EditDocument) -> Bool {
        byTake.values.allSatisfy { $0.areThePaths(of: document) }
    }
}
