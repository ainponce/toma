// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The camera's analysis of every take the sequence shows (phase 3 design §8.1: the analyses of phase 2 are by take).
extension CameraAnalysisCaches {
    /// `inputs` with its masks and faces replaced by what the caches hold whole for what `document` asks of each of
    /// `takes` (`fill(_:document:take:package:caches:)` of each, a take listed twice once): the masks and the faces of
    /// every take, none of them emptying another's, each under its own take's key (`CameraSegment.take`). With one take,
    /// what `fill(_:document:take:package:caches:)` gives. Reads the disk: never on the main thread.
    public static func fill(
        _ inputs: inout AnalysisInputs, document: EditDocument, takes: [TakeRecord], package: ProjectPackage,
        caches: ProjectCaches
    ) {
        var masks: [CameraSegment: URL] = [:]
        var faces: [CameraSegment: CameraFaceTrack] = [:]
        var done: Set<String> = []
        for take in takes where done.insert(take.id).inserted {
            var part = AnalysisInputs()
            fill(&part, document: document, take: take, package: package, caches: caches)
            masks.merge(part.personMasks) { first, _ in first }
            faces.merge(part.faceTracks) { first, _ in first }
        }
        inputs.personMasks = masks
        inputs.faceTracks = faces
    }
}
