// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat
import Testing

@Suite struct TimelineDragRulesTests {
    private static let es = Locale(identifier: "es")
    private static let en = Locale(identifier: "en")

    @Test func trimLabelShowsTheChangeAndTheEdge() {
        #expect(TimelineDragRules.trimLabel(delta: -1_200_000_000, position: 18_400_000_000, total: 134_000_000_000, locale: Self.es) == "−1,20 s · 0:18,40")
        #expect(TimelineDragRules.trimLabel(delta: 800_000_000, position: 18_400_000_000, total: 134_000_000_000, locale: Self.en) == "+0.80 s · 0:18.40")
        #expect(TimelineDragRules.trimLabel(delta: 0, position: 0, total: 5_000_000_000, locale: Self.es) == "0,00 s · 0:00,00")
        // A sequence of an hour or more reads its times with hours.
        #expect(TimelineDragRules.trimLabel(delta: 10_000_000, position: 3_600_000_000_000, total: 3_700_000_000_000, locale: Self.es) == "+0,01 s · 1:00:00,00")
    }

    @Test func aTrimmedEdgeIsTheSourceTheClipMapsThereToday() {
        // A clip from host 10 s at 2× that starts at output 4 s: output 5 s shows source 12 s.
        let start = HostTime(nanoseconds: 10_000_000_000)
        #expect(TimelineDragRules.sourceInstant(atOutput: 5_000_000_000, clipOutputStart: 4_000_000_000, clipStart: start, speed: 2).nanoseconds == 12_000_000_000)
        // Before its start, back in the source; at 0.5×, half as far.
        #expect(TimelineDragRules.sourceInstant(atOutput: 3_000_000_000, clipOutputStart: 4_000_000_000, clipStart: start, speed: 0.5).nanoseconds == 9_500_000_000)
        // Never before the start of the host's clock.
        #expect(TimelineDragRules.sourceInstant(atOutput: 0, clipOutputStart: 4_000_000_000, clipStart: HostTime(nanoseconds: 1_000_000_000), speed: 4).nanoseconds == 0)
        // Large host times keep their nanoseconds.
        let late = HostTime(nanoseconds: 9_007_199_254_740_993)
        #expect(TimelineDragRules.sourceInstant(atOutput: 1, clipOutputStart: 0, clipStart: late, speed: 1).nanoseconds == 9_007_199_254_740_994)
    }

    @Test func snappingIsOnUnlessCommandFlipsIt() {
        #expect(TimelineDragRules.snapActive(enabled: true, commandHeld: false))
        #expect(!TimelineDragRules.snapActive(enabled: true, commandHeld: true))
        #expect(!TimelineDragRules.snapActive(enabled: false, commandHeld: false))
        #expect(TimelineDragRules.snapActive(enabled: false, commandHeld: true))
    }

    @Test func snapsToTheClosestPointWithinTolerance() {
        let points = [0, 2_000_000_000, 5_000_000_000] as [Int64]
        let playhead: Int64 = 3_500_000_000
        func snap(_ t: Int64, active: Bool = true) -> Int64 {
            TimelineDragRules.snap(t, points: points, extra: [playhead], tolerance: 80_000_000, active: active)
        }
        #expect(snap(2_050_000_000) == 2_000_000_000)
        #expect(snap(3_450_000_000) == playhead)
        #expect(snap(2_100_000_000) == 2_100_000_000)
        #expect(snap(2_050_000_000, active: false) == 2_050_000_000)
        // Of two as close, the earlier.
        #expect(TimelineDragRules.snap(10, points: [0, 20], extra: [], tolerance: 10, active: true) == 0)
    }

    @Test func aMovedBlockSnapsWithTheEdgeThatIsCloser() {
        let range: Range<Int64> = 1_000_000_000..<3_000_000_000
        let points = [0, 4_030_000_000, 6_000_000_000] as [Int64]
        func shift(_ delta: Int64, tolerance: Int64 = 80_000_000) -> Int64 {
            TimelineDragRules.snapShift(of: range, by: delta, points: points, extra: [], tolerance: tolerance, active: true)
        }
        // Moved 1.05 s: its end is at 4.05 s, 20 ms from a point.
        #expect(shift(1_050_000_000) == 1_030_000_000)
        // Its start at 0.02 s from the first point.
        #expect(shift(-980_000_000) == -1_000_000_000)
        // Nothing near.
        #expect(shift(500_000_000) == 500_000_000)
        // Both edges near a point: the smaller change.
        #expect(TimelineDragRules.snapShift(of: 10..<20, by: 3, points: [14, 25], extra: [], tolerance: 5, active: true) == 4)
        #expect(TimelineDragRules.snapShift(of: 10..<20, by: 3, points: [14, 25], extra: [], tolerance: 5, active: false) == 3)
    }

    @Test func aBlockMadeByDraggingNeedsThreeTenthsOfASecond() {
        let duration: Int64 = 60_000_000_000
        #expect(TimelineDragRules.creationRange(from: 10_000_000_000, to: 11_000_000_000, duration: duration) == 10_000_000_000..<11_000_000_000)
        // Dragged to the left.
        #expect(TimelineDragRules.creationRange(from: 11_000_000_000, to: 10_000_000_000, duration: duration) == 10_000_000_000..<11_000_000_000)
        #expect(TimelineDragRules.creationRange(from: 10_000_000_000, to: 10_299_999_999, duration: duration) == nil)
        #expect(TimelineDragRules.creationRange(from: 10_000_000_000, to: 10_300_000_000, duration: duration) == 10_000_000_000..<10_300_000_000)
        // Cut to the output.
        #expect(TimelineDragRules.creationRange(from: -5_000_000_000, to: 2_000_000_000, duration: duration) == 0..<2_000_000_000)
        #expect(TimelineDragRules.creationRange(from: 59_000_000_000, to: 70_000_000_000, duration: duration) == 59_000_000_000..<60_000_000_000)
    }

    @Test func marksFollowTheDragInEitherDirection() {
        let duration: Int64 = 10_000_000_000
        #expect(TimelineDragRules.marks(from: 2_000_000_000, to: 5_000_000_000, duration: duration) == TimelineDragRules.Marks(in: 2_000_000_000, out: 5_000_000_000))
        #expect(TimelineDragRules.marks(from: 5_000_000_000, to: 2_000_000_000, duration: duration) == TimelineDragRules.Marks(in: 2_000_000_000, out: 5_000_000_000))
        #expect(TimelineDragRules.marks(from: 5_000_000_000, to: 5_000_000_000, duration: duration) == nil)
        #expect(TimelineDragRules.marks(from: -1_000_000_000, to: 20_000_000_000, duration: duration) == TimelineDragRules.Marks(in: 0, out: duration))
        #expect(TimelineDragRules.marks(from: 12_000_000_000, to: 20_000_000_000, duration: duration) == nil)
    }

    @Test func aDragStartsAfterThreePoints() {
        #expect(!TimelineDragRules.isDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 11)))
        #expect(TimelineDragRules.isDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 13, y: 10)))
        #expect(TimelineDragRules.isDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 6)))
    }

    @Test func theScaleSliderIsLogarithmic() {
        // Fitted at 10 pt/s: the slider's two ends are the fit and 600 pt/s, and the middle is the geometric mean.
        #expect(TimelineDragRules.sliderValue(scale: 10, fit: 10) == 0)
        #expect(TimelineDragRules.sliderValue(scale: 600, fit: 10) == 1)
        #expect(abs(TimelineDragRules.sliderScale(value: 0.5, fit: 10) - (10 * 600).squareRoot()) < 1e-9)
        for value in [0.0, 0.25, 0.7, 1] {
            let back = TimelineDragRules.sliderValue(scale: TimelineDragRules.sliderScale(value: value, fit: 3), fit: 3)
            #expect(abs(back - value) < 1e-12)
        }
        // Outside the range, or with nothing to fit, it holds to the ends.
        #expect(TimelineDragRules.sliderValue(scale: 5000, fit: 10) == 1)
        #expect(TimelineDragRules.sliderValue(scale: 1, fit: 10) == 0)
        #expect(TimelineDragRules.sliderValue(scale: 100, fit: 600) == 0)
        #expect(TimelineDragRules.sliderScale(value: 0.5, fit: 600) == 600)
    }
}
