// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// `TwoClips` (its clips end at 4 s and 8 s of output) with a zoom block over the source [102 s, 103 s), one across
/// the cut [104 s, 112 s) and one inside it; a camera change at 111.5 s and one in the cut; a screen change at 113 s;
/// and markers at 102.5 s and in the cut.
private extension TwoClips {
    enum Marked {
        static func zoom(_ id: String, from: Double, to: Double) -> ZoomRegion {
            ZoomRegion(
                id: id, take: TwoClips.takeID, start: TwoClips.at(from), end: TwoClips.at(to), origin: .user, focus: .follow,
                instant: false)
        }

        static func camera(_ id: String, at seconds: Double) -> CameraChange {
            CameraChange(id: id, take: TwoClips.takeID, t: TwoClips.at(seconds), style: .default, origin: .user)
        }

        static var document: EditDocument {
            var document = TwoClips.document()
            document.zoom.regions = [
                zoom("z-00000001", from: 2, to: 3), zoom("z-00000002", from: 4, to: 12), zoom("z-00000003", from: 6, to: 8),
            ]
            document.camera.changes = [camera("k-00000001", at: 11.5), camera("k-00000002", at: 7)]
            document.screens.changes = [
                ScreenChange(id: "p-00000001", take: TwoClips.takeID, t: TwoClips.at(13), track: "display-2", origin: .user)
            ]
            return document
        }

        static var points: EditPoints {
            let document = Self.document
            let markers = [TwoClips.at(2.5), TwoClips.at(8)]
            return EditPoints(document: document, timeMap: TimeMap(sequence: document.sequence), markers: markers)
        }
    }
}

@Test func editPointsNavigate() {
    let points = TwoClips.Marked.points
    // The start; the first zoom [1 s, 2 s) with the marker inside it; the zoom across the cut [3 s, 6 s); the edge
    // between the clips; the camera change; the screen change; the end. Nothing of what is cut, and no repeats.
    let expected = [0, 1, 1.5, 2, 3, 4, 5.5, 6, 7, 8].map(TwoClips.output)
    #expect(points.all == expected)
    var forward: [Int64] = []
    var t = TwoClips.output(-1)
    while let next = points.next(after: t) {
        forward.append(next)
        t = next
    }
    #expect(forward == expected)
    var backward: [Int64] = []
    t = TwoClips.output(9)
    while let previous = points.previous(before: t) {
        backward.append(previous)
        t = previous
    }
    #expect(backward == expected.reversed())
    // Between two points, and on one: always strictly before or after it.
    #expect(points.next(after: TwoClips.output(4.5)) == TwoClips.output(5.5))
    #expect(points.previous(before: TwoClips.output(4.5)) == TwoClips.output(4))
    #expect(points.next(after: TwoClips.output(4)) == TwoClips.output(5.5))
    #expect(points.previous(before: TwoClips.output(4)) == TwoClips.output(3))
    #expect(points.next(after: TwoClips.output(8)) == nil)
    #expect(points.previous(before: 0) == nil)
}

@Test func editPointsOfOneClipAreItsEnds() {
    let document = TwoClips.document([TwoClips.clip(1, from: 1, to: 5)])
    let points = EditPoints(document: document, timeMap: TimeMap(sequence: document.sequence), markers: [])
    #expect(points.all == [0, TwoClips.output(4)])
}

@Test func snappingPicksTheClosestWithinTolerance() {
    // The zoom starts at 1.0 s; the playhead is at 1.1 s.
    let points = TwoClips.Marked.points
    let playhead = TwoClips.output(1.1)
    #expect(points.snap(TwoClips.output(1.04), tolerance: TwoClips.output(0.060), also: [playhead]) == TwoClips.output(1.0))
    #expect(points.snap(TwoClips.output(1.04), tolerance: TwoClips.output(0.030), also: [playhead]) == TwoClips.output(1.04))
    // The closer one wins, an extra one too; exactly at the tolerance it still snaps.
    #expect(points.snap(TwoClips.output(1.08), tolerance: TwoClips.output(0.060), also: [playhead]) == playhead)
    #expect(points.snap(TwoClips.output(1.06), tolerance: TwoClips.output(0.060), also: []) == TwoClips.output(1.0))
    #expect(points.snap(TwoClips.output(1.07), tolerance: TwoClips.output(0.060), also: []) == TwoClips.output(1.07))
    // Halfway between two, the earlier; past the ends too; a negative tolerance never snaps.
    #expect(points.snap(TwoClips.output(2.5), tolerance: TwoClips.output(1), also: []) == TwoClips.output(2))
    #expect(points.snap(TwoClips.output(-0.01), tolerance: TwoClips.output(0.060), also: []) == 0)
    #expect(points.snap(TwoClips.output(8.05), tolerance: TwoClips.output(0.060), also: []) == TwoClips.output(8))
    #expect(points.snap(TwoClips.output(1), tolerance: -1, also: []) == TwoClips.output(1))
}
