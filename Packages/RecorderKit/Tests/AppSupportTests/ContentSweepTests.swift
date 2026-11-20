// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import Editing
import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Render
import Testing

/// Every reader of the sequence takes a clip with content (phase 3 base plan, B5): the render, the mix, the motion
/// paths, the thumbnails and the commands of the transcript and of typing, over a take with a frozen frame, a title card
/// and an imported clip between its stretches. None of them traps; in the take's stretches each draws and sounds what the
/// same stretches without the content draw and sound, later by the content before them, but for the fades of the sound
/// on each side of a content; and the content is silent. (In this target, the one that sees every reader.)
@Suite struct ContentSweepTests {
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static let second: Int64 = 1_000_000_000

    /// A take of 4 s: a display with the cursor at rest on it, and the microphone (a sine).
    private static func take(in dir: URL) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: "content")
        let frame = Rect(x: 0, y: 0, width: 320, height: 180)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 4, framesPerSecond: 10, width: 320, height: 180)])
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
            segments: [AudioSegmentSpec(start: base, seconds: 4)])
        try builder.addEvents([
            InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1)),
            InputEvent(t: base, kind: .cursor(x: 160, y: 90)),
        ])
        return try builder.write()
    }

    /// The take's clips over `[0, 1.5 s)`, `[1.5 s, 2.5 s)` and `[2.5 s, 4 s)` of the take, one going on from the other;
    /// with `content`, a frozen frame of 2 s after the first and a title card of 1 s and an imported clip of 2 s at 2×
    /// after the second, so the second starts 2 s later in the output and the third 4 s later.
    private static func document(_ project: LoadedProject, content: Bool) -> EditDocument {
        var document = EditDocument.legacy(for: project)
        let start = document.sequence[0].start
        func at(_ seconds: Double) -> HostTime { start.adding(seconds: seconds) }
        func clip(_ id: String, _ from: Double, _ to: Double) -> Clip {
            Clip(id: id, take: project.take.id, start: at(from), end: at(to), speed: 1)
        }
        func point(_ id: String, _ seconds: Double, _ content: ClipContent) -> Clip {
            Clip(id: id, take: project.take.id, start: at(seconds), end: at(seconds), speed: 1, content: content)
        }
        let media = MediaClip(asset: "assets/9a8b7c6d5e4f30211203f4e5d6c7b8a9.mov", start: 0, end: 2 * second, speed: 2)
        document.sequence = content
            ? [
                clip("c-00000001", 0, 1.5), point("c-0000000a", 1.5, .freeze(duration: 2 * second)), clip("c-00000002", 1.5, 2.5),
                point("c-0000000b", 2.5, .card(TitleCard(title: "Toma", style: .centered, background: .stage), duration: second)),
                point("c-0000000c", 2.5, .media(media)), clip("c-00000003", 2.5, 4),
            ]
            : [clip("c-00000001", 0, 1.5), clip("c-00000002", 1.5, 2.5), clip("c-00000003", 2.5, 4)]
        document.transcript = Transcript(
            language: "es-AR", engine: "speechTranscriber-1",
            takes: [TranscriptTake(take: project.take.id, track: "mic", words: [
                TranscriptWord(start: at(0.2), end: at(0.6), text: "Hola,"),
                TranscriptWord(start: at(1.0), end: at(1.4), text: "esto"),
                TranscriptWord(start: at(1.6), end: at(2.0), text: "es"),
                TranscriptWord(start: at(2.6), end: at(3.0), text: "una"),
                TranscriptWord(start: at(3.2), end: at(3.6), text: "toma."),
            ])])
        return document
    }

    /// The output stretches of the take's clips without the content, and how much later each is with it, in ns.
    private static let stretches: [(output: Range<Int64>, shift: Int64)] = [
        (0..<(3 * second / 2), 0), ((3 * second / 2)..<(5 * second / 2), 2 * second), ((5 * second / 2)..<(4 * second), 4 * second),
    ]

    @Test func everyReaderTakesAContentClip() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.take(in: dir)
            let (withContent, plain) = (Self.document(project, content: true), Self.document(project, content: false))
            let map = TimeMap(sequence: withContent.sequence)
            #expect(map.duration == 8 * Self.second)
            #expect(DocumentRules.problems(in: withContent) == [])

            // The render: every frame, and in the stretches of the take the frames without the content, later.
            let size = SIMD2(320, 180)
            let drawn = FrameEvaluator(take: project.take, events: project.events, document: withContent, outputSize: size)
            let reference = FrameEvaluator(take: project.take, events: project.events, document: plain, outputSize: size)
            for n in 0..<map.frameCount(frameRate: 30) {
                let frame = drawn.frame(at: Double(TimeMap.frameTime(n, frameRate: 30)) / 1e9) { _ in true }
                #expect(frame.outputSize == size)
            }
            for (output, shift) in Self.stretches {
                for τ in stride(from: output.lowerBound, to: output.upperBound, by: 10_000_000) {
                    let frame = drawn.frame(at: Double(τ + shift) / 1e9) { _ in true }
                    #expect(frame == reference.frame(at: Double(τ) / 1e9) { _ in true }, "\(τ) + \(shift)")
                    #expect(frame.screen?.sourceTime == plain.sequence[0].start.adding(seconds: Double(τ) / 1e9), "\(τ)")
                    #expect(frame.cursor != nil, "\(τ)")
                }
            }
            // The motion paths, the automatic zoom's planner and the thumbnails, which show none in a content.
            _ = MotionPaths(take: project.take, events: project.events, document: withContent)
            _ = AutoZoomPlanner.plan(take: project.take, events: project.events, document: withContent)
            let tiles = TimelineLayout.thumbnailTiles(
                sequence: withContent.sequence, map: map, visible: 0..<map.duration, scale: 100, tileWidth: 40, minimumWidth: 4)
            #expect(Set(tiles.map(\.clip)) == [0, 2, 5])
            let plainTiles = TimelineLayout.thumbnailTiles(
                sequence: plain.sequence, map: TimeMap(sequence: plain.sequence), visible: 0..<(4 * Self.second), scale: 100,
                tileWidth: 40, minimumWidth: 4)
            #expect(tiles.map(\.source) == plainTiles.map(\.source))

            // The mix: silent in the content, and in the stretches the samples without it, but for the fades at its sides.
            let mixed = try await Self.samples(project, withContent)
            let reference2 = try await Self.samples(project, plain)
            #expect(mixed.count == 8 * 48_000)
            #expect(reference2.count == 4 * 48_000)
            #expect(reference2.map(abs).max() ?? 0 > 0.2)
            let fade = 192
            for (output, shift) in Self.stretches {
                // Nanoseconds to frames at 48 kHz: × 48 / 10⁶.
                let (from, to) = (Int(output.lowerBound * 48 / 1_000_000), Int(output.upperBound * 48 / 1_000_000))
                let moved = Int(shift * 48 / 1_000_000)
                let first = from == 0 ? from : from + fade
                let last = to == reference2.count ? to : to - fade
                var worst: Float = 0
                for i in first..<last { worst = max(worst, abs(mixed[i + moved] - reference2[i])) }
                #expect(worst == 0, "the stretch \(output) moved \(shift): \(worst)")
                // At the sides of a content, the sound fades: never louder than without it.
                for i in from..<first { #expect(abs(mixed[i + moved]) <= abs(reference2[i]) + 1e-6) }
                for i in last..<to { #expect(abs(mixed[i + moved]) <= abs(reference2[i]) + 1e-6) }
            }
            for silent in [(3 * 48_000 / 2)..<(7 * 48_000 / 2), (9 * 48_000 / 2)..<(13 * 48_000 / 2)] {
                #expect(mixed[silent].allSatisfy { $0 == 0 }, "\(silent)")
            }

            // The commands of the transcript cut and restore the take's stretches, and leave each point where it is.
            let cut = try #require(TranscriptCommands.cut(withContent, take: 0, words: 1...1, makeID: { _ in "c-0000f001" })).get()
            let cutDocument = try withContent.applying(cut.changes)
            let plainCut = try plain.applying(try #require(TranscriptCommands.cut(plain, take: 0, words: 1...1, makeID: { _ in "c-0000f001" })).get().changes)
            #expect(cutDocument.sequence.filter { $0.content == nil } == plainCut.sequence)
            #expect(cutDocument.sequence.filter { $0.content != nil } == withContent.sequence.filter { $0.content != nil })
            #expect(DocumentRules.problems(in: cutDocument) == [])
            let bounds = TakeTimeline.editableBounds(take: project.take, events: project.events)
            let restored = try cutDocument.applying(
                try #require(TranscriptCommands.restore(cutDocument, take: 0, words: 1...1, bounds: bounds.start...bounds.end, makeID: { _ in "c-0000f002" }))
                    .changes)
            #expect(restored.sequence == withContent.sequence)

            // Typing over the whole take: without the content, one span; with it, the content parts it into stretches
            // shorter than a span, and nothing is sped (`typingSpeedLeavesAPointAlone` speeds one beside a point).
            let typing = project.events + (0...15).map { InputEvent(t: Self.base.adding(seconds: Double($0) * 0.25), kind: .keyActivity) }
            #expect(!TypingSpeed.spans(plain, take: project.take, events: typing).isEmpty)
            #expect(TypingSpeed.spans(withContent, take: project.take, events: typing).isEmpty)
            #expect(TypingSpeed.summary(withContent, take: project.take, events: typing, speed: 3).count == 0)
            #expect(TypingSpeed.apply(withContent, take: project.take, events: typing, speed: 3, makeID: { _ in "c-0000f003" }) == nil)
        }
    }

    /// The whole mix of `document` of `project`, read off the pool.
    private static func samples(_ project: LoadedProject, _ document: EditDocument) async throws -> [Float] {
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 30)
        return try await offThePool {
            var samples: [Float] = []
            mix.render(outputFrames: 0..<mix.totalFrames, into: &samples)
            return samples
        }
    }
}
