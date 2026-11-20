// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import Testing

// The automatic zoom of a take whose clips meet another take's (phase 3 design §9: at the border between two takes the
// zoom's path cuts): a block whose lead runs into the other take is cut at the border, never lost; with one take nothing
// changes.

private enum Border {
    static let first = "take-001", second = "take-002"

    static func base(_ take: String) -> HostTime {
        HostTime(nanoseconds: take == first ? 5_000_000_000_000 : 5_100_000_000_000)
    }

    static func at(_ take: String, _ seconds: Double) -> HostTime { base(take).adding(seconds: seconds) }

    /// A take of one display of 1440 × 900 pt recorded for 60 s.
    static func take(_ id: String) -> TakeRecord {
        TakeRecord(
            id: id, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: [TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(
                    name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [SegmentRecord(
                    index: 1, file: "takes/\(id)/display-1/seg-0001.mov", startHostTime: base(id), endHostTime: at(id, 60),
                    endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)])])
    }

    static func click(_ take: String, _ seconds: Double) -> [InputEvent] {
        [
            InputEvent(t: at(take, seconds), kind: .mouseDown(.left, x: 720, y: 450)),
            InputEvent(t: at(take, seconds + 0.05), kind: .mouseUp(.left, x: 720, y: 450)),
        ]
    }

    static func clip(_ id: Int, _ take: String, _ from: Double, _ to: Double) -> Clip {
        Clip(id: "c-0000000\(id)", take: take, start: at(take, from), end: at(take, to), speed: 1)
    }

    /// A document of `sequence`, of Toma's automatic zoom, each take on its display.
    static func document(_ sequence: [Clip]) -> EditDocument {
        var document = EditDocument.legacy(take: take(first), events: [])
        document.sequence = sequence
        document.screens = ScreenPlan(initial: [first: "display-1", second: "display-1"], changes: [])
        document.zoom.auto = DefaultStyle.toma.zoomAuto
        return document
    }

    /// The source spans of `regions`, in seconds of their take.
    static func spans(_ regions: [ZoomRegion]) -> [String] {
        regions.map { region in
            let from = region.start.seconds(since: base(region.take)), to = region.end.seconds(since: base(region.take))
            return "\(region.take) \(String(format: "%.2f", from))–\(String(format: "%.2f", to))"
        }
    }
}

/// The first take's last 10 s of output end 0.4 s after a click of it, and the second's clip starts 0.3 s before a
/// click of it: each lead runs into the other take. In either order, each take plans the block it plans alone, cut at
/// the border, and no block's output leaves its take's clips.
@Test func aBlockAtTheBorderBetweenTakesIsCutThere() throws {
    let first = Border.take(Border.first), second = Border.take(Border.second)
    let events = [Border.first: Border.click(Border.first, 9.6), Border.second: Border.click(Border.second, 0.3)]
    let pieces = [Border.first: (0.0, 10.0), Border.second: (0.0, 10.0)]
    var alone: [String: [ZoomRegion]] = [:]
    for take in [first, second] {
        let (from, to) = try #require(pieces[take.id])
        alone[take.id] = AutoZoomPlanner.plan(
            take: take, events: events[take.id] ?? [], document: Border.document([Border.clip(1, take.id, from, to)]))
        #expect(alone[take.id]?.count == 1, "\(take.id)")
    }
    #expect(Border.spans(alone[Border.first] ?? []) == ["take-001 9.10–10.00"])
    #expect(Border.spans(alone[Border.second] ?? []) == ["take-002 0.00–1.30"])

    for order in [[first, second], [second, first]] {
        let document = Border.document(order.enumerated().map { k, take in
            Border.clip(k + 1, take.id, pieces[take.id]?.0 ?? 0, pieces[take.id]?.1 ?? 0)
        })
        let map = TimeMap(sequence: document.sequence)
        for take in order {
            let planned = AutoZoomPlanner.plan(take: take, events: events[take.id] ?? [], document: document)
            #expect(planned == alone[take.id], "\(order.map(\.id)) \(take.id)")
            // Inside its take's clip, in output time.
            let clip = try #require(document.sequence.firstIndex { $0.take == take.id })
            let clipOutput = map.clipOutputStarts[clip]..<(map.clipOutputStarts[clip] + TimeMap.outputDuration(of: document.sequence[clip]))
            for region in planned {
                let output = try #require(map.outputRange(ofSource: region.start..<region.end, take: take.id))
                #expect(clipOutput.contains(output.lowerBound) && output.upperBound <= clipOutput.upperBound)
            }
        }
    }
}

/// Two clicks of the first take, one at the end of its first clip and one at the start of its second, with a clip of
/// the other take between: two blocks, one in each run of its clips, never one across the other take's clip.
@Test func blocksOfATakeStayInEachRunOfItsClips() throws {
    let first = Border.take(Border.first)
    let events = Border.click(Border.first, 4.8) + Border.click(Border.first, 5.4)
    let both = Border.document([Border.clip(1, Border.first, 0, 5), Border.clip(2, Border.second, 0, 0.5), Border.clip(3, Border.first, 5, 10)])
    let planned = AutoZoomPlanner.plan(take: first, events: events, document: both)
    #expect(Border.spans(planned) == ["take-001 4.30–5.00", "take-001 5.00–6.40"])
    // Without the other take's clip, the two clicks are one group, one block.
    let together = Border.document([Border.clip(1, Border.first, 0, 10)])
    #expect(AutoZoomPlanner.plan(take: first, events: events, document: together).count == 1)
}
