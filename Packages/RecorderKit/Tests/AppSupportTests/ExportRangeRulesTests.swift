// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import Testing

@Suite struct ExportRangeRulesTests {
    private static let second: Int64 = 1_000_000_000

    @Test func defaultRangeByKind() {
        let duration = 30 * Self.second
        let whole: Range<Int64> = 0..<duration
        let marks: Range<Int64> = (12 * Self.second)..<(22 * Self.second + 400_000_000)
        // With marks: the GIF's, the marks; the MP4's, the whole video.
        #expect(ExportRangeRules.defaultRange(kind: .gif, marks: marks, duration: duration) == marks)
        #expect(ExportRangeRules.defaultRange(kind: .mp4, marks: marks, duration: duration) == whole)
        // Without marks, both the whole video.
        #expect(ExportRangeRules.defaultRange(kind: .gif, marks: nil, duration: duration) == whole)
        #expect(ExportRangeRules.defaultRange(kind: .mp4, marks: nil, duration: duration) == whole)
        // Marks left past the end by an edit are cut to the video.
        let pastTheEnd: Range<Int64> = (20 * Self.second)..<(40 * Self.second)
        #expect(ExportRangeRules.defaultRange(kind: .gif, marks: pastTheEnd, duration: duration) == (20 * Self.second)..<duration)
    }

    @Test func theMarkedRangeIsCutToTheVideo() {
        let duration = 10 * Self.second
        // Without both marks, nothing is marked.
        #expect(ExportRangeRules.markedRange(TimelineMarks(), duration: duration) == nil)
        #expect(ExportRangeRules.markedRange(TimelineMarks(in: Self.second), duration: duration) == nil)
        #expect(ExportRangeRules.markedRange(TimelineMarks(out: Self.second), duration: duration) == nil)
        // From the in to the out.
        let marked: Range<Int64> = Self.second..<(3 * Self.second)
        #expect(ExportRangeRules.markedRange(TimelineMarks(in: Self.second, out: 3 * Self.second), duration: duration) == marked)
        // An out past the end ends with the video; both past it leave nothing, at the end.
        let toTheEnd: Range<Int64> = (8 * Self.second)..<duration
        #expect(ExportRangeRules.markedRange(TimelineMarks(in: 8 * Self.second, out: 12 * Self.second), duration: duration) == toTheEnd)
        let nothing: Range<Int64> = duration..<duration
        #expect(ExportRangeRules.markedRange(TimelineMarks(in: 11 * Self.second, out: 12 * Self.second), duration: duration) == nothing)
        // An in before 0 (never set so, but cut anyway) starts with the video.
        let fromTheStart: Range<Int64> = 0..<Self.second
        #expect(ExportRangeRules.markedRange(TimelineMarks(in: -5, out: Self.second), duration: duration) == fromTheStart)
    }

    @Test func rangeOfLessThanAFrameCannotExport() {
        // 50 ms at 15 fps is less than a frame (66.7 ms); 67 ms is more.
        #expect(!ExportRangeRules.canExport(0..<50_000_000, fps: 15))
        #expect(ExportRangeRules.canExport(0..<67_000_000, fps: 15))
        // Exactly a frame, give or take the marks' nanosecond (`ExportRange.lastsAFrame`); 2 ns short is not.
        #expect(ExportRangeRules.canExport(0..<66_666_667, fps: 15))
        #expect(ExportRangeRules.canExport(0..<66_666_666, fps: 15))
        #expect(!ExportRangeRules.canExport(0..<66_666_665, fps: 15))
        #expect(ExportRangeRules.canExport(1_000..<(1_000 + 33_333_333), fps: 30))
        // Nothing, or no frame rate, never exports; a range too long to multiply does.
        #expect(!ExportRangeRules.canExport(5..<5, fps: 30))
        #expect(!ExportRangeRules.canExport(0..<Self.second, fps: 0))
        #expect(!ExportRangeRules.canExport(0..<Self.second, fps: -15))
        #expect(ExportRangeRules.canExport(0..<Int64.max, fps: 60))
    }

    /// The rule of `ExportRange.lastsAFrame(fps:)` (Export: Task 23's sweep): marks `k` frames of the document apart, on
    /// its grid, last a frame of the export exactly when `k × export ≥ document` frames per second, at every rate.
    @Test func marksOnTheGridLastAFrameAsTheExporterSays() {
        var wrong: [String] = []
        for document in EditDocument.frameRates {
            for export in [10, 15, 20, 24, 25, 30, 50, 60] {
                for i in 0..<document {
                    for k in 1...(2 * document) {
                        let start = TimeMap.frameTime(i, frameRate: document)
                        let end = TimeMap.frameTime(i + k, frameRate: document)
                        let expected = k * export >= document
                        if ExportRangeRules.canExport(start..<end, fps: export) != expected {
                            wrong.append("\(document) → \(export) fps, frames \(i) to \(i + k)")
                        }
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) mark pairs: \(wrong.prefix(5))")
    }
}
