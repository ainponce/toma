// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`.
@testable import Render
import Testing

/// "Like the Recording" with takes of screens of other proportions (phase 3 design §9: the stage is laid out with each
/// clip's own screens, in the one output): every take's stage is the output's, the ratio of the take of the first clip,
/// and a take of another proportion is fitted inside it, so its zoom, its cursor and its camera are where a document of
/// that output's aspect puts them for that take alone.

/// The frames per second the frames of these tests are on, the legacy document's.
private let rate = 60

/// The output second of frame `n` of the grid of `rate`.
private func seconds(_ n: Int) -> Double { Double(TimeMap.frameTime(n, frameRate: rate)) / 1e9 }

/// `take-001` of a 16:9 display of 640 × 360 and `take-002` of a 4:3 one of 480 × 360, focused on `take-002`.
private func twoProportions(in dir: URL) async throws -> LoadedProject {
    try await MultiTakeFixtures.twoTakes(in: dir, name: "Proportions", secondScreen: Rect(x: 0, y: 0, width: 480, height: 360))
}

/// `project`'s document of `pieces` in `aspect`, with a zoom block on a fixed point and one that follows the cursor in
/// each take, so the frames show where the stage puts the zoom and the cursor.
private func document(
    _ project: LoadedProject, _ pieces: [(take: String, from: Double, to: Double)], aspect: Aspect
) throws -> EditDocument {
    var document = MultiTakeFixtures.sequence(of: project, pieces)
    document.aspect = aspect
    var regions: [ZoomRegion] = []
    for (k, take) in ["take-001", "take-002"].enumerated() {
        let focused = try #require(project.focused(on: take))
        let start = try #require(EditDocument.legacy(for: focused).sequence.first?.start)
        regions.append(ZoomRegion(
            id: "z-0000000\(2 * k + 1)", take: take, start: start.adding(seconds: 0.2), end: start.adding(seconds: 0.9),
            origin: .user, depth: 2, focus: .fixed(x: 0.7, y: 0.6), instant: false))
        regions.append(ZoomRegion(
            id: "z-0000000\(2 * k + 2)", take: take, start: start.adding(seconds: 1.1), end: start.adding(seconds: 1.8),
            origin: .user, depth: 2.5, focus: .follow, instant: false))
    }
    document.zoom.regions = regions
    return document
}

@Suite struct MultiTakeStageTests {
    /// The first clip of the 16:9 take: the 4:3 take's stage is 16:9 too, and its frames are those of that take alone in
    /// a 16:9 document; the first clip of the 4:3 take: the other way around, in a 4:3 one. With the paths given (the
    /// app's), reused after an edit of the corners, and resized, the same.
    @Test func everyTakeIsLaidOutInTheOutput() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoProportions(in: dir)
            let wide = 640.0 / 360, narrow = 480.0 / 360
            let cases: [(first: String, other: String, ratio: Double, aspect: Aspect, size: SIMD2<Int>)] = [
                ("take-001", "take-002", wide, .landscape, SIMD2(640, 360)),
                ("take-002", "take-001", narrow, .fourByThree, SIMD2(480, 360)),
            ]
            for (first, other, ratio, aspect, size) in cases {
                let both = try document(project, [(first, 0, 2), (other, 0, 2)], aspect: .auto)
                let alone = try document(project, [(other, 0, 2)], aspect: aspect)
                #expect(StageLayout.contentRatio(project: project, document: both) == ratio)
                let paths = SequencePaths(project: project, document: both, cameraReadable: [:])
                for take in [first, other] {
                    #expect(paths.byTake[take]?.stage.stageSize == SIMD2(ratio, 1), "\(take)")
                    #expect(paths.byTake[take]?.stage.contentRatio == ratio, "\(take)")
                }

                let scene = FrameEvaluator(project: project, document: both, outputSize: size)
                let given = FrameEvaluator(project: project, document: both, outputSize: size, paths: paths)
                let reference = FrameEvaluator(project: project, document: alone, outputSize: size)
                var corners = both
                corners.style.cornerRadius += 0.01
                let reused = SequencePaths(project: project, document: corners, cameraReadable: [:], reusing: paths)
                #expect(reused.byTake[other]?.stage.stageSize == SIMD2(ratio, 1))
                for n in 0..<120 {
                    let frame = scene.frame(at: seconds(120 + n))
                    #expect(frame == reference.frame(at: seconds(n)), "\(first) first, frame \(n)")
                    #expect(given.frame(at: seconds(120 + n)) == frame, "\(first) first, frame \(n)")
                }
                // The other take zooms in where its block points, inside its own screen.
                #expect((scene.frame(at: seconds(150)).stage?.depth ?? 1) > 1.5)
                let half = scene.resized(to: size / 2), referenceHalf = reference.resized(to: size / 2)
                #expect(half.frame(at: seconds(150)) == referenceHalf.frame(at: seconds(30)))
            }
        }
    }

    /// A fixed size (16:9) does not depend on the takes: each take's stage is 16:9, as phase 2 lays it out, whatever take
    /// the first clip is of.
    @Test func aFixedAspectKeepsEveryTakesStage() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoProportions(in: dir)
            for first in ["take-001", "take-002"] {
                let other = first == "take-001" ? "take-002" : "take-001"
                let both = try document(project, [(first, 0, 2), (other, 0, 2)], aspect: .landscape)
                let paths = SequencePaths(project: project, document: both, cameraReadable: [:])
                for take in [first, other] {
                    let shown = try #require(project.focused(on: take))
                    let alone = MotionPaths(take: shown.take, events: shown.events, document: both)
                    #expect(paths.byTake[take]?.stage.stageSize == alone.stage.stageSize)
                    #expect(paths.byTake[take]?.stage.stageSize == SIMD2(16.0 / 9, 1))
                }
            }
        }
    }
}
