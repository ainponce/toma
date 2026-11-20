// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

// Milestone 5c, Task R3 (fases 4 y 5 design §10.3.4): a saved Replay's document is the one of a take just recorded,
// starting at the cut.

private enum ReplayDocumentFixture {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    /// `c-00000001`, `c-00000002`… from 1 for each new instance.
    final class IDs: Sendable {
        private let count = Mutex(0)

        func make(_ prefix: String) -> String {
            count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            }
        }
    }

    /// 8 s of one display, 640 × 360 pt, in two segments (as a Replay saves the one across the cut whole), the cursor
    /// moving across it and a click at each of `clicks` (in seconds from the start), its button up 0.2 s later.
    static func take(in dir: URL, clicks: [Double]) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: "Replay")
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [
                VideoSegmentSpec(start: base, seconds: 4, framesPerSecond: 10),
                VideoSegmentSpec(start: base.adding(seconds: 4), seconds: 4, framesPerSecond: 10),
            ])
        try builder.addEvents([InputEvent(t: base, kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        try builder.addEvents((0..<80).map { i in
            InputEvent(t: base.adding(seconds: Double(i) / 10), kind: .cursor(x: 40 + Double(i % 40) * 14, y: 180))
        })
        for click in clicks {
            let x = 40 + Double(Int((click * 10).rounded()) % 40) * 14
            try builder.addEvents([
                InputEvent(t: base.adding(seconds: click), kind: .mouseDown(.left, x: x, y: 180)),
                InputEvent(t: base.adding(seconds: click + 0.2), kind: .mouseUp(.left, x: x, y: 180)),
            ])
        }
        return try builder.write()
    }
}

@Suite struct ReplayDocumentTests {
    @Test func documentIsTheNewDocumentFromTheCut() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await ReplayDocumentFixture.take(in: dir, clicks: [1, 2.5, 5.5, 7])
            let cut = ReplayDocumentFixture.base.adding(seconds: 5)
            let document = ReplayDocument.make(
                project: project, cut: cut, defaultStyle: .toma, makeID: ReplayDocumentFixture.IDs().make,
                cameraLook: .newProjects)
            var expected = NewDocument.make(
                project: project, defaultStyle: .toma, makeID: ReplayDocumentFixture.IDs().make, cameraLook: .newProjects)

            // One clip, from the cut to the end of the take, with the new document's id.
            let whole = try #require(expected.sequence.first)
            #expect(expected.sequence.count == 1)
            #expect(document.sequence.count == 1)
            let clip = try #require(document.sequence.first)
            #expect(clip.start == cut)
            #expect(clip.end == whole.end)
            #expect(clip.id == whole.id && clip.take == whole.take && clip.speed == 1)
            #expect(TimeMap(sequence: document.sequence).duration == 3_000_000_000)

            // The zoom blocks are planned again over that sequence: as `autoZoom-1` plans them for it.
            var unplanned = document
            unplanned.zoom.regions = []
            #expect(document.zoom.regions == AutoZoomPlanner.plan(take: project.take, events: project.events, document: unplanned))
            #expect(!document.zoom.regions.isEmpty)
            #expect(document.zoom.regions != expected.zoom.regions)

            // Everything else is the new document's.
            expected.sequence = document.sequence
            expected.zoom.regions = document.zoom.regions
            #expect(document == expected)
        }
    }

    @Test func noZoomBlockEndsBeforeTheCut() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await ReplayDocumentFixture.take(in: dir, clicks: [0.5, 1.5, 2.5, 3.5, 6.5])
            let cut = ReplayDocumentFixture.base.adding(seconds: 5)
            let full = NewDocument.make(
                project: project, defaultStyle: .toma, makeID: ReplayDocumentFixture.IDs().make, cameraLook: .newProjects)
            // Without the cut there are blocks before it.
            #expect(full.zoom.regions.contains { $0.end <= cut })

            let document = ReplayDocument.make(
                project: project, cut: cut, defaultStyle: .toma, makeID: ReplayDocumentFixture.IDs().make,
                cameraLook: .newProjects)
            #expect(!document.zoom.regions.isEmpty)
            #expect(document.zoom.regions.allSatisfy { $0.start >= cut && $0.end > cut })
        }
    }

    @Test func aButtonHeldAcrossTheCutDrawsNoClick() async throws {
        try await withTemporaryDirectory { dir in
            // The button goes down 0.1 s before the cut and up 0.1 s after it.
            let project = try await ReplayDocumentFixture.take(in: dir, clicks: [4.9])
            let cut = ReplayDocumentFixture.base.adding(seconds: 5)
            let document = ReplayDocument.make(
                project: project, cut: cut, defaultStyle: .toma, makeID: ReplayDocumentFixture.IDs().make,
                cameraLook: .newProjects)
            let path = CursorPath(
                take: project.take, events: project.events, style: document.cursor, timeMap: TimeMap(sequence: document.sequence))
            #expect(path.clicks.isEmpty)

            // The same click after the cut is drawn.
            let later = ReplayDocument.make(
                project: project, cut: ReplayDocumentFixture.base.adding(seconds: 4.5), defaultStyle: .toma,
                makeID: ReplayDocumentFixture.IDs().make, cameraLook: .newProjects)
            let drawn = CursorPath(
                take: project.take, events: project.events, style: later.cursor, timeMap: TimeMap(sequence: later.sequence))
            #expect(drawn.clicks.count == 1)
        }
    }

    @Test func clipsThatEndBeforeTheCutAreLeftOut() async throws {
        try await withTemporaryDirectory { dir in
            // [0, 1) and [2, 3) s, paused in between.
            let project = try await GoldenProjects.make("pausedTake", in: dir, formatVersion: 3)
            let start = try #require(project.take.track("display-1")?.segments.first?.startHostTime)
            let full = NewDocument.make(
                project: project, defaultStyle: .toma, makeID: ReplayDocumentFixture.IDs().make, cameraLook: .newProjects)
            #expect(full.sequence.count == 2)

            let across = ReplayDocument.make(
                project: project, cut: start.adding(seconds: 2.5), defaultStyle: .toma,
                makeID: ReplayDocumentFixture.IDs().make, cameraLook: .newProjects)
            #expect(across.sequence.map(\.start) == [start.adding(seconds: 2.5)])
            #expect(across.sequence.map(\.end) == [full.sequence[1].end])
            #expect(across.sequence.map(\.id) == [full.sequence[1].id])

            // A cut in the pause keeps the clip after it as it is.
            let inPause = ReplayDocument.make(
                project: project, cut: start.adding(seconds: 1.5), defaultStyle: .toma,
                makeID: ReplayDocumentFixture.IDs().make, cameraLook: .newProjects)
            #expect(inPause.sequence == [full.sequence[1]])
        }
    }
}
