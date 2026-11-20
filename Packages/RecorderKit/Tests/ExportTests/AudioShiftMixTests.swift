// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
@testable import Render
import Testing

/// The cut of the sound moved, a J or an L cut, in the mix (phase 3 design §7.3, plan 3c task U5 and decision 10): the
/// sound of clip `k` starts `Clip.audioShift` from its picture, held to half of each clip next to it and to what its take
/// has (`AudioCuts`, with each source's `editable`); what is heard sooner or longer comes from the source outside the
/// clip, a stretched clip is fed it too, the fade of 192 frames goes with the cut of the sound and no frame of the
/// picture moves.
///
/// The takes start their display at `base`, frame 0 of the take's timeline and the start of its legacy document; their
/// microphone is `marker(n)` at each source frame `n` (`markedTake`), so each output frame tells which source frame it
/// plays, or a sine (`toneTake`) where a stretch plays it.
@Suite struct AudioShiftMixTests {
    /// A J cut of −0.2 s at clip 1 (clips [0, 1) and [2, 3) s): output frames [0.8, 1.0) s play the source [1.8, 2.0)
    /// s, the clip before stops there, and the fade of 192 frames is at 0.8 s on both sides.
    @Test func jCutPlaysTheNextClipEarly() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await markedTake(in: dir, name: "j")
            let mix = try await EditedMix.make(
                project: project, document: edited(project, [(0, 1), (2, 3)], shifts: [1: -200_000_000]), framesPerSecond: 60)
            #expect(mix.cuts.starts == [0, 38_400] && mix.cuts.sourceShift == [0, -9_600])
            #expect(mix.cuts.clip(atOutputFrame: 38_399) == 0 && mix.cuts.clip(atOutputFrame: 38_400) == 1)
            #expect(mix.cuts.clip(atOutputFrame: -1) == nil && mix.cuts.clip(atOutputFrame: 96_000) == nil)
            // The source heard there, in host time: 1.8 s of the take, and before the clip's own start too.
            #expect(mix.cuts.sourceNanoseconds(ofClip: 1, atOutputFrame: 38_400) == Int64(at(1.8).nanoseconds))
            let samples = try await rendered(mix)
            let expected = expectation(96_000, pieces: [
                (0..<38_400, 0, fadesIn: false, fadesOut: true), (38_400..<96_000, 48_000, fadesIn: true, fadesOut: true),
            ])
            #expect(worst(samples, expected) <= 1e-7)
            #expect(samples[38_399] == 0 && samples[38_400] == 0, "the fade is at the cut of the sound")
            #expect(abs(samples[38_207] - marker(38_207)) <= 1e-7 && abs(samples[38_592] - marker(38_592 + 48_000)) <= 1e-7)
            // [0.8, 1.0) s is the source [1.8, 2.0) s, not [0.8, 1.0) s as without the cut.
            #expect(abs(samples[39_000] - marker(87_000)) <= 1e-7)
        }
    }

    /// An L cut of +0.2 s at clip 1: output frames [1.0, 1.2) s go on with the source [1.0, 1.2) s of clip 0, past its
    /// end, and clip 1 starts at 2.2 s of its source, faded there.
    @Test func lCutKeepsTheClipBeforeOn() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await markedTake(in: dir, name: "l")
            let mix = try await EditedMix.make(
                project: project, document: edited(project, [(0, 1), (2, 3)], shifts: [1: 200_000_000]), framesPerSecond: 60)
            #expect(mix.cuts.starts == [0, 57_600] && mix.cuts.sourceShift == [0, 9_600])
            #expect(mix.cuts.sourceNanoseconds(ofClip: 0, atOutputFrame: 57_600) == Int64(at(1.2).nanoseconds))
            let samples = try await rendered(mix)
            let expected = expectation(96_000, pieces: [
                (0..<57_600, 0, fadesIn: false, fadesOut: true), (57_600..<96_000, 48_000, fadesIn: true, fadesOut: true),
            ])
            #expect(worst(samples, expected) <= 1e-7)
            #expect(abs(samples[50_000] - marker(50_000)) <= 1e-7, "1.04 s plays the source past the end of clip 0")
            #expect(samples[57_599] == 0 && samples[57_600] == 0 && abs(samples[57_792] - marker(57_792 + 48_000)) <= 1e-7)
        }
    }

    /// A clip at 2× whose next clip has an L cut is stretched over the whole of its sound: its stretch is fed the source
    /// past the clip's end up to where the sound stops, so the extension is not silent. A clip at 2× with a J cut is
    /// heard from its early start too.
    @Test func aStretchedClipStretchesItsExtension() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await toneTake(in: dir, name: "stretched")
            // [0, 2) s at 2× (1 s of output) and [3, 4) s; the sound of clip 0 goes on 0.4 s: to 2.8 s of its source.
            var document = edited(project, [(0, 2), (3, 4)], shifts: [1: 400_000_000])
            document.sequence[0].speed = 2
            let lCut = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            #expect(lCut.cuts.starts == [0, 67_200])
            #expect(lCut.playDescription.contains("run 0..<67200 from 0 heard 0..<134400 at 2.0"), "\(lCut.playDescription)")
            let extended = try await rendered(lCut)
            // From the clip's own end (1 s) to 20 ms before the fade of the cut of the sound.
            for window in stride(from: 48_000, to: 67_200 - 960, by: 480) {
                let level = rms(extended[window..<(window + 480)])
                #expect(level > 0.1, "\(Double(window) / 48_000) s: \(level)")
            }

            // [0, 1) s and [2, 4) s at 2×, the second heard 0.4 s sooner: from 1.2 s of its source.
            var early = edited(project, [(0, 1), (2, 4)], shifts: [1: -400_000_000])
            early.sequence[1].speed = 2
            let jCut = try await EditedMix.make(project: project, document: early, framesPerSecond: 60)
            #expect(jCut.cuts.starts == [0, 28_800] && jCut.cuts.sourceShift == [0, -38_400])
            #expect(jCut.playDescription.contains("run 28800..<96000 from 57600 heard 57600..<192000 at 2.0"), "\(jCut.playDescription)")
            let sooner = try await rendered(jCut)
            for window in stride(from: 28_800 + 960, to: 48_000, by: 480) {
                let level = rms(sooner[window..<(window + 480)])
                #expect(level > 0.1, "\(Double(window) / 48_000) s: \(level)")
            }
        }
    }

    /// A cut of the sound moved at an edge that is no cut (a clip split, the second part going on with the first's
    /// source at the same speed) leaves the mix the clip's unsplit, bit for bit: at 1× and stretched at 2×, with the
    /// limiter and without.
    @Test func aSplitWithoutACutStaysSeamless() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await markedTake(in: dir, name: "split")
            for limiter in [false, true] {
                for (speed, from, seam, to) in [(1.0, 0.1, 1.5, 2.9), (2.0, 0.1, 2.0, 3.9)] {
                    func plan(_ spans: [(Double, Double)], shifts: [Int: Int64]) -> EditDocument {
                        var document = edited(project, spans, shifts: shifts)
                        document.audio.limiter = limiter
                        for k in document.sequence.indices { document.sequence[k].speed = speed }
                        return document
                    }
                    let mix = try await EditedMix.make(project: project, document: plan([(from, to)], shifts: [:]), framesPerSecond: 60)
                    let unsplit = try await rendered(mix)
                    for shift: Int64 in [-300_000_000, 300_000_000] {
                        let document = plan([(from, seam), (seam, to)], shifts: [1: shift])
                        let split = mix.with(document: document, framesPerSecond: 60)
                        let picture = TimeMap(sequence: document.sequence).clipOutputStarts[1]
                        #expect(split.cuts.starts[1] == EditedMix.frames(ofNanoseconds: picture + shift), "the cut of the sound moved")
                        #expect(bits(try await rendered(split)) == bits(unsplit), "\(speed)×, limiter \(limiter), shift \(shift)")
                    }
                }
            }
        }
    }

    /// A cut of the sound is held where it is read: to half of the shorter clip at its edge (0.9 s next to a clip of
    /// 0.4 s is 0.2 s), to none next to a frozen frame, and to what each take has (the J of the first clip of take-002
    /// from that take's start is none, and so is the L after a clip of take-001 that ends at its take's end), as
    /// `SequenceRules.audioShiftRange(of:at:takeBounds:)` holds it with the takes' editable bounds.
    @Test func shiftIsHeldToTheNeighborsAndTheTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await markedTake(in: dir, name: "held")
            for (asked, held) in [(Int64(900_000_000), Int64(200_000_000)), (-900_000_000, -200_000_000)] {
                let mix = try await EditedMix.make(
                    project: project, document: edited(project, [(0, 0.4), (1, 3)], shifts: [1: asked]), framesPerSecond: 60)
                #expect(mix.cuts.starts[1] == EditedMix.frames(ofNanoseconds: 400_000_000 + held))
                let exact = mix.with(document: edited(project, [(0, 0.4), (1, 3)], shifts: [1: held]), framesPerSecond: 60)
                #expect(bits(try await rendered(mix)) == bits(try await rendered(exact)), "\(asked)")
            }

            // A frozen frame at 1 s between [0, 1) s and [1, 2) s: no cut of the sound moves at either of its edges.
            var frozen = edited(project, [(0, 1), (1, 2)])
            frozen.sequence.insert(
                Clip(id: "c-00000009", take: takeID, start: at(1), end: at(1), speed: 1, content: .freeze(duration: 500_000_000),
                     audioShift: 300_000_000), at: 1)
            let plain = try await EditedMix.make(project: project, document: frozen, framesPerSecond: 60)
            frozen.sequence[2].audioShift = -300_000_000
            let shifted = plain.with(document: frozen, framesPerSecond: 60)
            let timeMap = TimeMap(sequence: frozen.sequence)
            #expect(shifted.cuts.sourceShift == [0, 0, 0])
            #expect(shifted.cuts.starts == timeMap.clipOutputStarts.map(EditedMix.frames(ofNanoseconds:)))
            #expect(bits(try await rendered(shifted)) == bits(try await rendered(plain)))
        }
        try await withTemporaryDirectory { dir in
            let twoTakes = try await MultiTakeFixtures.twoTakes(in: dir)
            // take-002 from its own start, heard 0.9 s sooner: nothing of it is there before.
            var document = MultiTakeFixtures.sequence(of: twoTakes, [("take-001", 0, 2), ("take-002", 0, 2)])
            let plain = try await EditedMix.make(project: twoTakes, document: document, framesPerSecond: 60)
            document.sequence[1].audioShift = -900_000_000
            #expect(TimeMap(sequence: document.sequence).audioStarts[1] == 1_100_000_000, "the shift alone is in its range")
            let early = plain.with(document: document, framesPerSecond: 60)
            #expect(early.cuts.starts == [0, 96_000] && early.cuts.sourceShift == [0, 0])
            #expect(bits(try await rendered(early)) == bits(try await rendered(plain)))

            // take-001 up to its own end, then take-002 with an L cut: nothing of take-001 is there after.
            let first = try #require(twoTakes.focused(on: "take-001"))
            let end = TakeTimeline.editableBounds(take: first.take, events: first.events).end
            var late = MultiTakeFixtures.sequence(of: twoTakes, [("take-001", 0, 1), ("take-002", 1, 3)])
            late.sequence[0].start = end.adding(seconds: -1)
            late.sequence[0].end = end
            let ending = plain.with(document: late, framesPerSecond: 60)
            late.sequence[1].audioShift = 400_000_000
            let lCut = plain.with(document: late, framesPerSecond: 60)
            #expect(lCut.cuts.starts == [0, 48_000] && lCut.cuts.sourceShift == [0, 0])
            #expect(bits(try await rendered(lCut)) == bits(try await rendered(ending)))
        }
    }

    /// A cut of the sound moves no frame of the picture, the camera nor the cursor: the frames of golden 3's
    /// `cutsAndSpeed` (with its camera) with a J and an L cut at its second clip are its own, frame for frame.
    @Test func audioShiftMovesNoFrame() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await GoldenDocuments.makeProject("cutsAndSpeed", in: dir)
            let document = try GoldenDocuments.makeDocument("cutsAndSpeed", for: project)
            let size: SIMD2<Int> = [640, 360]
            let own = FrameEvaluator(take: project.take, events: project.events, document: document, outputSize: size)
            let frameCount = TimeMap(sequence: document.sequence).frameCount(frameRate: 60)
            for shift: Int64 in [-400_000_000, 400_000_000] {
                var moved = document
                moved.sequence[1].audioShift = shift
                #expect(SequenceRules.audioShift(of: moved.sequence, at: 1) == shift)
                let evaluator = FrameEvaluator(take: project.take, events: project.events, document: moved, outputSize: size)
                for n in 0..<frameCount {
                    let t = Double(TimeMap.frameTime(n, frameRate: 60)) / 1e9
                    #expect(evaluator.frame(at: t) == own.frame(at: t), "frame \(n), shift \(shift)")
                }
            }
        }
    }
}

// MARK: - Helpers

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// What the microphone of `markedTake` holds at source frame `n` (from the take's start): a value no other frame has.
private func marker(_ n: Int) -> Float { Float(n + 1) / 400_000 }

/// Replaces each frame of a block of a mono segment by its `marker` (an `AudioSegmentSpec.transform`).
@Sendable private func marking(_ block: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
    let frames = CMSampleBufferGetNumSamples(sample)
    let values = (0..<frames).map { marker(block * frames + $0) }
    let status = values.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
    }
    precondition(status == noErr, "marker block: \(status)")
    return sample
}

/// A take of 4 s of the display and a microphone of `marker`s.
private func markedTake(in dir: URL, name: String) async throws -> LoadedProject {
    try await take(in: dir, name: name, mic: AudioSegmentSpec(start: base, seconds: 4, transform: marking))
}

/// A take of 4 s of the display and a microphone of the 440 Hz sine at 1/4 of full scale.
private func toneTake(in dir: URL, name: String) async throws -> LoadedProject {
    try await take(in: dir, name: name, mic: AudioSegmentSpec(start: base, seconds: 4))
}

private func take(in dir: URL, name: String, mic: AudioSegmentSpec) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: mic.seconds, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addAudioTrack(id: micID, source: micSource, segments: [mic])
    return try builder.write()
}

/// The legacy document of `project` with its clips over `spans` (seconds from the take's start) at 1×, the cut of the
/// sound of clip `k` moved by `shifts[k]` ns.
private func edited(_ project: LoadedProject, _ spans: [(Double, Double)], shifts: [Int: Int64] = [:]) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.sequence = spans.enumerated().map { k, span in
        Clip(id: String(format: "c-%08x", k + 1), take: project.take.id, start: at(span.0), end: at(span.1), speed: 1,
             audioShift: shifts[k] ?? 0)
    }
    return document
}

/// What the mix of a `markedTake` plays over `count` frames: each piece's frames, the source frame its first one plays
/// minus its output frame (`offset`), and its fades of 192 frames, as `EditedMix` fades them.
private func expectation(
    _ count: Int, pieces: [(frames: Range<Int>, offset: Int, fadesIn: Bool, fadesOut: Bool)]
) -> [Float] {
    var samples = [Float](repeating: 0, count: count)
    for piece in pieces {
        for frame in piece.frames {
            var fade: Float = 1
            if piece.fadesIn, frame - piece.frames.lowerBound < 192 { fade = Float(frame - piece.frames.lowerBound) / 192 }
            if piece.fadesOut, piece.frames.upperBound - 1 - frame < 192 {
                fade = min(fade, Float(piece.frames.upperBound - 1 - frame) / 192)
            }
            samples[frame] = marker(frame + piece.offset) * (1 * fade)
        }
    }
    return samples
}

/// The largest difference between `samples` and `expected`, frame for frame (infinity for another count).
private func worst(_ samples: [Float], _ expected: [Float]) -> Float {
    guard samples.count == expected.count else { return .infinity }
    return zip(samples, expected).map { abs($0 - $1) }.max() ?? 0
}

private func rms(_ samples: ArraySlice<Float>) -> Double {
    (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
}

/// `mix.render` of the whole mix, read off the cooperative pool.
private func rendered(_ mix: EditedMix) async throws -> [Float] {
    try await offThePool {
        var samples: [Float] = []
        mix.render(outputFrames: 0..<mix.totalFrames, into: &samples)
        return samples
    }
}

private func bits(_ samples: [Float]) -> [UInt32] { samples.map(\.bitPattern) }
