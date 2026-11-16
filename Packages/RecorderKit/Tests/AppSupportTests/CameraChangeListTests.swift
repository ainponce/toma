// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import Testing
// Not @testable: the app uses only the public API.
import Editing

@Suite struct CameraChangeListTests {
    private static let takeID = "take-001"
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }
    private static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    private static let circle = CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .topLeading)
    private static let square = CameraStyle(shape: .roundedSquare, size: CameraStyle.small, anchor: .bottomLeading)
    private static let wide = CameraStyle(shape: .landscape, size: CameraStyle.large, anchor: .top)

    /// 60 s of one take with the 20 s to 30 s cut out; changes at 10 s, 25 s (in the cut) and 40 s.
    private static func document() -> EditDocument {
        let take = TakeRecord(id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [])
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = [
            Clip(id: "c-00000001", take: takeID, start: base, end: at(20), speed: 1),
            Clip(id: "c-00000002", take: takeID, start: at(30), end: at(60), speed: 1),
        ]
        document.camera = CameraPlan(
            show: true, initial: [takeID: .default],
            changes: [
                CameraChange(id: "k-00000003", take: takeID, t: at(40), style: wide, origin: .recorded),
                CameraChange(id: "k-00000001", take: takeID, t: at(10), style: circle, origin: .recorded),
                CameraChange(id: "k-00000002", take: takeID, t: at(25), style: square, origin: .user),
            ])
        return document
    }

    @Test func rowsAreTheVisibleChangesInOutputOrder() {
        let document = Self.document()
        let rows = CameraChangeList.rows(document, timeMap: TimeMap(sequence: document.sequence))
        // The change at 25 s is in the cut: no row. The one at 40 s is at 30 s of output.
        #expect(
            rows == [
                CameraChangeRow(id: "k-00000001", output: Self.output(10), style: Self.circle),
                CameraChangeRow(id: "k-00000003", output: Self.output(30), style: Self.wide),
            ])
    }

    @Test func editingTargetFollowsThePlayhead() {
        let document = Self.document()
        let map = TimeMap(sequence: document.sequence)
        #expect(CameraChangeList.editing(document, atOutput: Self.output(5), timeMap: map) == .initial)
        #expect(CameraChangeList.editing(document, atOutput: Self.output(10), timeMap: map) == .change(id: "k-00000001", output: Self.output(10)))
        // At 20 s of output the source is 30 s: the cut change at 25 s rules, and shows where the clip after the cut starts.
        #expect(CameraChangeList.editing(document, atOutput: Self.output(20), timeMap: map) == .change(id: "k-00000002", output: Self.output(20)))
        #expect(CameraChangeList.editing(document, atOutput: Self.output(45), timeMap: map) == .change(id: "k-00000003", output: Self.output(30)))
    }

    @Test func arrowsMoveTheBubbleToTheNeighbouringPlace() {
        #expect(CameraAnchorGrid.neighbor(of: .topLeading, dx: 1, dy: 0) == .top)
        #expect(CameraAnchorGrid.neighbor(of: .topLeading, dx: 0, dy: 1) == .leading)
        // Over the centre, which is no place.
        #expect(CameraAnchorGrid.neighbor(of: .top, dx: 0, dy: 1) == .bottom)
        #expect(CameraAnchorGrid.neighbor(of: .leading, dx: 1, dy: 0) == .trailing)
        // At the edge it stays.
        #expect(CameraAnchorGrid.neighbor(of: .bottomTrailing, dx: 1, dy: 0) == .bottomTrailing)
        #expect(CameraAnchorGrid.neighbor(of: .top, dx: 0, dy: -1) == .top)
        #expect(CameraAnchorGrid.rows.flatMap { $0 }.compactMap { $0 }.count == CameraAnchor.allCases.count)
    }
}
