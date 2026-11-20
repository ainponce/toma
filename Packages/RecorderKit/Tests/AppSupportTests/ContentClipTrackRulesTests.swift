// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat
import Testing

@Suite struct ContentClipTrackRulesTests {
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }
    private static func output(_ s: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: s) }

    private static let take = TakeRecord(
        id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base, endHostTime: at(20),
                        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ])
        ])

    private static let stretch = Clip(id: "c-00000001", take: "take-001", start: base, end: at(10), speed: 1)
    private static let freeze = Clip(
        id: "c-00000002", take: "take-001", start: at(10), end: at(10), speed: 1, content: .freeze(duration: 2_000_000_000))
    private static func card(_ title: String) -> Clip {
        Clip(
            id: "c-00000003", take: "take-001", start: at(10), end: at(10), speed: 1,
            content: .card(TitleCard(title: title, style: .centered, background: .stage), duration: 3_000_000_000))
    }
    private static let media = Clip(
        id: "c-00000004", take: "take-001", start: at(10), end: at(10), speed: 1,
        content: .media(MediaClip(asset: "assets/0123456789abcdef0123456789abcdef.mov", start: 1_000_000_000, end: 5_000_000_000)))

    /// The take from 0 to 10 s, then a frozen frame (10–12 s of output), a card (12–15 s) and an imported clip (15–19 s).
    private static func document() -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = [stretch, freeze, card("Intro"), media]
        return document
    }

    @Test func freezeAndCardRightEdgeSetTheDuration() throws {
        for clip in [Self.freeze, Self.card("Intro")] {
            #expect(ContentClipTrackRules.drag(for: .end, of: clip) == .duration)
            // Its left edge is where the clip before it ends: nothing to drag there.
            #expect(ContentClipTrackRules.drag(for: .start, of: clip) == nil)
        }
        let start = Self.output(10)
        let freeze = Self.freeze
        #expect(ContentClipTrackRules.duration(dragging: freeze, toOutputEnd: start + Self.output(2.7), start: start) == Self.output(2.7))
        // Held to 0.1 … 60 s.
        #expect(ContentClipTrackRules.duration(dragging: freeze, toOutputEnd: start + Self.output(0.05), start: start) == Self.output(0.1))
        #expect(ContentClipTrackRules.duration(dragging: freeze, toOutputEnd: start - Self.output(1), start: start) == Self.output(0.1))
        #expect(ContentClipTrackRules.duration(dragging: freeze, toOutputEnd: start + Self.output(90), start: start) == Self.output(60))
        #expect(ContentClipTrackRules.duration(dragging: freeze, toOutputEnd: .max, start: .min) == Self.output(60))
        #expect(ContentClipTrackRules.duration(dragging: freeze, toOutputEnd: .min, start: .max) == Self.output(0.1))

        // As the drag's step makes it: the frozen frame lasts 2.7 s and the clips after it move by 0.7 s.
        let document = Self.document()
        let duration = ContentClipTrackRules.duration(dragging: freeze, toOutputEnd: start + Self.output(2.7), start: start)
        let step = try #require(ContentClipCommands.setDuration(document, clipID: freeze.id, duration))
        let changed = try document.applying(step.changes)
        #expect(TimeMap.outputDuration(of: changed.sequence[1]) == Self.output(2.7))
        #expect(TimeMap(sequence: changed.sequence).clipOutputStarts[2] == Self.output(12.7))
    }

    @Test func mediaEdgesTrimTheFile() throws {
        #expect(ContentClipTrackRules.drag(for: .start, of: Self.media) == .mediaStart)
        #expect(ContentClipTrackRules.drag(for: .end, of: Self.media) == .mediaEnd)
        // Its length is its file's: a drag of its edges trims the file, never sets a duration.
        #expect(ContentClipTrackRules.duration(dragging: Self.media, toOutputEnd: Self.output(30), start: Self.output(15)) == Self.output(4))

        let document = Self.document()
        let step = try #require(ContentClipCommands.trimMedia(
            document, clipID: Self.media.id, edge: .start, toOutput: Self.output(15.5), fileDuration: Self.output(8)))
        let changed = try document.applying(step.changes)
        guard case let .media(trimmed)? = changed.sequence[3].content else {
            Issue.record("not an imported clip")
            return
        }
        #expect(trimmed.start == 1_500_000_000)
        #expect(trimmed.end == 5_000_000_000)
    }

    @Test func takeClipsKeepTheirTrim() {
        // A stretch of the take is trimmed as in 1b (`SequenceCommands.trim`).
        #expect(ContentClipTrackRules.drag(for: .start, of: Self.stretch) == nil)
        #expect(ContentClipTrackRules.drag(for: .end, of: Self.stretch) == nil)
        #expect(ContentClipTrackRules.duration(dragging: Self.stretch, toOutputEnd: Self.output(4), start: 0) == Self.output(10))
        #expect(ContentClipTrackRules.label(of: Self.stretch) == nil)
    }

    @Test func aCardSaysItsTitle() {
        #expect(ContentClipTrackRules.label(of: Self.card("Intro")) == "Intro")
        #expect(ContentClipTrackRules.label(of: Self.card("  Intro\nParte 2 ")) == "Intro Parte 2")
        // Without a title the app names it.
        #expect(ContentClipTrackRules.label(of: Self.card(" \n ")) == nil)
        #expect(ContentClipTrackRules.label(of: Self.freeze) == nil)
        #expect(ContentClipTrackRules.label(of: Self.media) == nil)
    }

    @Test func typedDurations() {
        #expect(ContentClipTrackRules.duration(fromTyped: "2,5") == Self.output(2.5))
        #expect(ContentClipTrackRules.duration(fromTyped: " 2.5 s ") == Self.output(2.5))
        #expect(ContentClipTrackRules.duration(fromTyped: "3") == Self.output(3))
        // Held to 0.1 … 60 s.
        #expect(ContentClipTrackRules.duration(fromTyped: "0,05") == Self.output(0.1))
        #expect(ContentClipTrackRules.duration(fromTyped: "90") == Self.output(60))
        for text in ["", "s", "abc", "0", "-1", "nan", "inf"] {
            #expect(ContentClipTrackRules.duration(fromTyped: text) == nil, "\(text)")
        }
    }

    @Test func tilesOfAFrozenFrameAndAClip() {
        // At 100 pt/s, 50 pt tiles: a step of 2²⁸ ns (26.8 pt), as the take's grid has (`TimelineLayout.thumbnailTiles`).
        let step: Int64 = 1 << 28
        let start = Self.output(10)
        let frozen = ContentClipTrackRules.tiles(
            of: Self.freeze, outputStart: start, visible: 0..<Self.output(100), scale: 100, tileWidth: 50, minimumWidth: 16)
        // Two seconds: seven whole tiles and a last one of 12 pt, too narrow to have one.
        #expect(frozen.map(\.index) == Array(0..<7))
        #expect(frozen.map(\.output) == (0..<7).map { start + Int64($0) * step })
        #expect(frozen.last?.end == start + 7 * step)
        // Every one shows the same frame, the take's at its point.
        #expect(frozen.allSatisfy { $0.frame == Self.at(10).nanoseconds })

        let clipStart = Self.output(15)
        let clip = ContentClipTrackRules.tiles(
            of: Self.media, outputStart: clipStart, visible: Self.output(16)..<Self.output(17), scale: 100, tileWidth: 50,
            minimumWidth: 16)
        // Only those in sight, each the file's frame at its left edge: from 1 s of the file on.
        #expect(clip.first?.index == 3)
        #expect(clip.map(\.frame) == clip.map { UInt64(1_000_000_000 + Int64($0.index) * step) })
        #expect(clip.allSatisfy { $0.output < Self.output(17) && $0.end > Self.output(16) })
        // At 2×, the file goes twice as fast under the tiles.
        var fast = Self.media
        fast.content = .media(MediaClip(asset: "assets/0123456789abcdef0123456789abcdef.mov", start: 1_000_000_000, end: 5_000_000_000, speed: 2))
        let fastTiles = ContentClipTrackRules.tiles(
            of: fast, outputStart: clipStart, visible: 0..<Self.output(100), scale: 100, tileWidth: 50, minimumWidth: 16)
        #expect(fastTiles.map(\.frame) == fastTiles.map { UInt64(1_000_000_000 + 2 * Int64($0.index) * step) })
        #expect(fastTiles.last.map { $0.end <= clipStart + Self.output(2) } == true)

        // A title card and a stretch of the take have none (the take's tiles are `TimelineLayout.thumbnailTiles`).
        for other in [Self.card("Intro"), Self.stretch] {
            #expect(ContentClipTrackRules.tiles(
                of: other, outputStart: 0, visible: 0..<Self.output(100), scale: 100, tileWidth: 50, minimumWidth: 16).isEmpty)
        }
    }

    @Test func videoFilesAreDropped() {
        for name in ["clip.mov", "Clip.MOV", "clip.mp4", "clip.m4v"] {
            #expect(ContentClipTrackRules.isVideoFile(URL(filePath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["clip.png", "clip.mov.zip", "clip", "clip.m4a"] {
            #expect(!ContentClipTrackRules.isVideoFile(URL(filePath: "/tmp/\(name)")), "\(name)")
        }
        #expect(!ContentClipTrackRules.isVideoFile(URL(string: "https://example.com/clip.mov")!))
    }
}
