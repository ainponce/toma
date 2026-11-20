// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import Testing

@Suite struct AudioRowRulesTests {
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }
    private static func ns(_ s: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: s) }

    private static func take(_ id: String) -> TakeRecord {
        TakeRecord(
            id: id, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: [
                TrackRecord(
                    id: "display-1", kind: .display,
                    source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                    segments: [
                        SegmentRecord(
                            index: 1, file: "takes/\(id)/display-1/seg-0001.mov", startHostTime: base, endHostTime: at(40),
                            endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                    ])
            ])
    }

    private static func document(_ sequence: [Clip]) -> EditDocument {
        var document = EditDocument.legacy(take: take("take-001"), events: [])
        document.sequence = sequence
        return document
    }

    private static func clip(_ id: String, take: String = "take-001", _ from: Double, _ to: Double, shift: Int64 = 0) -> Clip {
        Clip(id: id, take: take, start: Self.at(from), end: Self.at(to), speed: 1, audioShift: shift)
    }

    @Test func gainAndHeightGoBothWays() {
        let h = 100.0
        #expect(AudioRowGeometry.y(ofGain: 12, height: h) == 0)
        #expect(abs(AudioRowGeometry.y(ofGain: -48, height: h) - 92) < 1e-9)
        #expect(AudioRowGeometry.y(ofGain: GainRange.silence, height: h) == h)
        #expect(AudioRowGeometry.y(ofGain: -60, height: h) == h)
        #expect(AudioRowGeometry.y(ofGain: 30, height: h) == 0)
        #expect(AudioRowGeometry.gain(atY: 0, height: h) == 12)
        #expect(abs(AudioRowGeometry.gain(atY: 92, height: h) + 48) < 1e-9)
        #expect(AudioRowGeometry.gain(atY: 95, height: h) == GainRange.silence)
        #expect(AudioRowGeometry.gain(atY: -20, height: h) == 12)
        for g in stride(from: -48.0, through: 12.0, by: 1.5) where abs(g) > AudioRowGeometry.snap {
            #expect(abs(AudioRowGeometry.gain(atY: AudioRowGeometry.y(ofGain: g, height: h), height: h) - g) < 1e-9)
        }
        // Near 0 dB it sticks.
        #expect(AudioRowGeometry.gain(atY: AudioRowGeometry.y(ofGain: 0.6, height: h), height: h) == 0)
        #expect(AudioRowGeometry.gain(atY: AudioRowGeometry.y(ofGain: -0.7, height: h), height: h) == 0)
        #expect(AudioRowGeometry.gain(atY: AudioRowGeometry.y(ofGain: 0.9, height: h), height: h) != 0)
    }

    @Test func trackGainInDecibels() {
        #expect(AudioRowGeometry.decibels(ofTrackGain: 1) == 0)
        #expect(abs(AudioRowGeometry.decibels(ofTrackGain: 2) - 6.0206) < 0.001)
        #expect(AudioRowGeometry.decibels(ofTrackGain: 0) == GainRange.silence)
        #expect(AudioRowGeometry.decibels(ofTrackGain: 5) == AudioRowGeometry.decibels(ofTrackGain: 2))
        #expect(AudioRowGeometry.trackGain(ofDecibels: 9) == 2)
        #expect(AudioRowGeometry.trackGain(ofDecibels: 0) == 1)
        #expect(AudioRowGeometry.trackGain(ofDecibels: GainRange.silence) == 0)
        #expect(abs(AudioRowGeometry.trackGain(ofDecibels: -6.0206) - 0.5) < 0.001)
        #expect(AudioRowGeometry.decibels(ofTrackGain: .nan) == 0)
    }

    @Test func cutsAreTheBordersThatTakeAShift() {
        // 0..5 | 5..10 (J moved by 1 s) | a frozen frame | 10..15 | another take 0..5
        let frozen = Clip(id: "c-freeze", take: "take-001", start: Self.at(10), end: Self.at(10), speed: 1, content: .freeze(duration: 2_000_000_000))
        let sequence = [
            Self.clip("c-0", 0, 5), Self.clip("c-1", 5, 10, shift: -1_000_000_000), frozen, Self.clip("c-3", 10, 15),
            Self.clip("c-4", take: "take-002", 0, 5),
        ]
        let document = Self.document(sequence)
        let map = TimeMap(sequence: sequence)
        let cuts = AudioRowRules.cuts(document, timeMap: map)
        // Not clip 0 (the first), not the frozen frame (2), not the clip after it (3); clips 1 and 4 can.
        #expect(cuts.map(\.clip) == [1, 4])
        #expect(cuts[0].picture == Self.ns(5))
        #expect(cuts[0].audio == Self.ns(4))
        #expect(cuts[1].picture == map.clipOutputStarts[4])
        #expect(cuts[1].audio == cuts[1].picture)
        #expect(AudioRowRules.cuts(Self.document([Self.clip("c-0", 0, 5)]), timeMap: TimeMap(sequence: [Self.clip("c-0", 0, 5)])).isEmpty)
    }

    private let ranges: [(id: String, x: ClosedRange<Double>, gain: Double)] = [("g-1", 100...200, -30)]

    @Test func optionNearABorderIsTheAudioCut() {
        let cuts = [(clip: 1, x: 50.0), (clip: 2, x: 300.0)]
        func hit(_ x: Double, option: Bool) -> AudioRowHit {
            AudioRowRules.hit(x: x, y: 20, option: option, height: 40, ranges: [], cuts: cuts, rowGain: 0)
        }
        #expect(hit(53, option: true) == .audioCut(clip: 1))
        #expect(hit(297, option: true) == .audioCut(clip: 2))
        #expect(hit(53, option: false) == .empty)
        #expect(hit(55, option: true) == .empty)
        // The row's line is at the top for 0 dB with a 40 pt row: 12 dB at 0, so 0 dB is at ~9.2.
        let y = AudioRowGeometry.y(ofGain: 0, height: 40)
        #expect(AudioRowRules.hit(x: 53, y: y, option: false, height: 40, ranges: [], cuts: cuts, rowGain: 0) == .rowLine)
    }

    @Test func rangesWinOverTheRowLine() {
        let h = 40.0
        let rowY = AudioRowGeometry.y(ofGain: 0, height: h)
        let rangeY = AudioRowGeometry.y(ofGain: -30, height: h)
        func hit(_ x: Double, _ y: Double) -> AudioRowHit {
            AudioRowRules.hit(x: x, y: y, option: false, height: h, ranges: ranges, cuts: [], rowGain: 0)
        }
        #expect(hit(150, rangeY) == .rangeLine(id: "g-1"))
        // Inside the stretch the row's line is not there.
        #expect(hit(150, rowY) == .empty)
        #expect(hit(102, rangeY) == .rangeEdge(id: "g-1", edge: .start))
        #expect(hit(197, 2) == .rangeEdge(id: "g-1", edge: .end))
        #expect(hit(50, rowY) == .rowLine)
        #expect(hit(250, rowY) == .rowLine)
        #expect(hit(50, h - 1) == .empty)
    }

    @Test func theNearestEdgeWinsWhereTwoStretchesTouch() {
        let touching: [(id: String, x: ClosedRange<Double>, gain: Double)] = [("g-1", 100...150, 0), ("g-2", 152...200, 0)]
        func hit(_ x: Double) -> AudioRowHit {
            AudioRowRules.hit(x: x, y: 5, option: false, height: 40, ranges: touching, cuts: [], rowGain: 0)
        }
        #expect(hit(149) == .rangeEdge(id: "g-1", edge: .end))
        #expect(hit(153) == .rangeEdge(id: "g-2", edge: .start))
    }

    @Test func aCutOnTopOfARangeEdgeIsTheCutOnlyWithOption() {
        let cuts = [(clip: 1, x: 100.0)]
        let with = AudioRowRules.hit(x: 101, y: 5, option: true, height: 40, ranges: ranges, cuts: cuts, rowGain: 0)
        let without = AudioRowRules.hit(x: 101, y: 5, option: false, height: 40, ranges: ranges, cuts: cuts, rowGain: 0)
        #expect(with == .audioCut(clip: 1))
        #expect(without == .rangeEdge(id: "g-1", edge: .start))
    }
}
