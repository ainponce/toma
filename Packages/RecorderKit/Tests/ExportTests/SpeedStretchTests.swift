// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

// The takes here start their display at `base`, which is then frame 0 of the take's timeline (`TakeTimeline.bounds`);
// `at(_:)` is a time in seconds from there.

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// A take of the display and a microphone, `seconds` long: the microphone's segments are `mic` (by default one of 440 Hz
/// at 1/4 of full scale over the whole take), and system audio's `systemAudio` when there are any.
private func take(
    in dir: URL, name: String, seconds: Double = 3, mic: [AudioSegmentSpec]? = nil, systemAudio: [AudioSegmentSpec] = []
) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addAudioTrack(id: micID, source: micSource, segments: mic ?? [AudioSegmentSpec(start: base, seconds: seconds)])
    if !systemAudio.isEmpty {
        try await builder.addAudioTrack(id: systemAudioID, kind: .systemAudio, source: systemAudioSource, segments: systemAudio)
    }
    return try builder.write()
}

/// The legacy document of `project` with its clips over `spans` (seconds from the take's start, and a speed), changed by
/// `change`.
private func edited(
    _ project: LoadedProject, _ spans: [(from: Double, to: Double, speed: Double)], _ change: (inout EditDocument) -> Void = { _ in }
) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.sequence = spans.enumerated().map { i, span in
        Clip(id: String(format: "c-%08x", i + 1), take: project.take.id, start: at(span.from), end: at(span.to), speed: span.speed)
    }
    change(&document)
    return document
}

/// A microphone that is silent but for a burst of 1 kHz at half of full scale, `seconds` long, from `start` seconds.
private func burst(at start: Double, seconds: Double = 0.05, takeSeconds: Double) -> [AudioSegmentSpec] {
    let tone = toneBurst(at: at(start), start: base, skewPPM: 0, frequency: 1000, channels: 1, amplitude: 0.5, seconds: seconds)
    return [AudioSegmentSpec(start: base, seconds: takeSeconds, amplitude: 0, transform: tone)]
}

/// Runs `body` on a thread of its own: reading the mix decodes, which blocks in `copyNextSampleBuffer`, and many tests
/// blocking Swift's cooperative pool at once hang the run.
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// `mix.render` of `frames` (by default the whole mix) with `preroll`, read off the cooperative pool.
private func rendered(_ mix: EditedMix, _ frames: Range<Int64>? = nil, preroll: Double = 0) async throws -> [Float] {
    let range = frames ?? 0..<mix.totalFrames
    return try await offThePool {
        var samples: [Float] = []
        mix.render(outputFrames: range, into: &samples, preroll: preroll)
        return samples
    }
}

/// The whole of `mix` asked for in blocks of 4096 frames, one after the other, as the export asks for it.
private func blockwise(_ mix: EditedMix) async throws -> [Float] {
    try await offThePool {
        var all: [Float] = [], block: [Float] = []
        var position: Int64 = 0
        while position < mix.totalFrames {
            let end = min(position + 4_096, mix.totalFrames)
            mix.render(outputFrames: position..<end, into: &block)
            all += block
            position = end
        }
        return all
    }
}

private func bits(_ samples: some Collection<Float>) -> [UInt32] { samples.map(\.bitPattern) }

/// Channel 0 of interleaved stereo `samples`.
private func left(_ samples: [Float]) -> [Float] { stride(from: 0, to: samples.count, by: 2).map { samples[$0] } }

/// The frequency of the tone in frames `frames` of `samples` (mono, 48 kHz): its upward zero crossings, each placed
/// between its two samples, counted over the time from the first to the last.
private func dominantFrequency(_ samples: [Float], _ frames: Range<Int>) -> Double {
    var crossings: [Double] = []
    for n in (frames.lowerBound + 1)..<frames.upperBound {
        let a = Double(samples[n - 1]), b = Double(samples[n])
        if a < 0, b >= 0 { crossings.append(Double(n - 1) + a / (a - b)) }
    }
    guard crossings.count > 1, let first = crossings.first, let last = crossings.last else { return 0 }
    return Double(crossings.count - 1) / ((last - first) / 48_000)
}

/// Root mean square of frames `frames` of `samples`.
private func rms(_ samples: [Float], _ frames: Range<Int>) -> Double {
    (samples[frames].reduce(0) { $0 + Double($1) * Double($1) } / Double(frames.count)).squareRoot()
}

/// When a burst of `frequency` Hz begins within `window` seconds of `time` in `samples` (mono, 48 kHz, from output 0):
/// the first time, in steps of 0.25 ms, where the tone's amplitude over 20 ms centred on it reaches half of its largest
/// there (the rule of `toneOnset`).
private func onset(in samples: [Float], frequency: Double = 1000, near time: Double, window: Double = 0.1) throws -> Double {
    let half = 0.010, step = 0.000_25
    let times = stride(from: time - window, through: time + window, by: step).filter {
        $0 - half >= 0 && $0 + half <= Double(samples.count) / 48_000
    }
    let amplitudes = times.map { toneAmplitude(samples, start: 0, frequency: frequency, from: $0 - half, to: $0 + half) }
    let peak = try #require(amplitudes.max(), "no audio near \(time) s")
    #expect(peak > 0.3, "the \(frequency) Hz burst stands out: \(peak)")
    return times[try #require(amplitudes.firstIndex { $0 >= peak / 2 })]
}

// MARK: - Length, pitch and alignment

/// 1 s of 440 Hz at 2× lasts exactly 24 000 frames, still at 440 Hz and at its level.
@Test func doubleSpeedLastsHalfWithThePitchKept() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "double")
        let mix = try await EditedMix.make(project: project, document: edited(project, [(0, 1, 2)]), framesPerSecond: 60)
        #expect(mix.totalFrames == 24_000 && mix.contentFrames == 24_000)
        let samples = try await rendered(mix)
        try #require(samples.count == 24_000)
        let frequency = dominantFrequency(samples, 2_400..<21_600)
        #expect(abs(frequency - 440) <= 5, "\(frequency) Hz")
        let level = rms(samples, 2_400..<21_600)
        #expect(abs(level - 0.25 / 2.0.squareRoot()) < 0.01, "RMS \(level)")
    }
}

/// Clips at 1.5×, 1× and 3×, one after the other in the source: the mixed content lasts `round(D × 48 000 / 10⁹)` frames
/// and each clip `round(O_{k+1} × 48 000 / 10⁹) − round(O_k × 48 000 / 10⁹)`, its fades' zeros exactly at its edges; past
/// the content, the silence that makes up `totalFrames`.
@Test func exactFrameCountsAcrossClips() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "counts", seconds: 4)
        let document = edited(project, [(0, 1.0101, 1.5), (1.0101, 2, 1), (2, 3.21, 3)])
        let timeMap = TimeMap(sequence: document.sequence)
        let edges = timeMap.clipOutputStarts.map(EditedMix.frames(ofNanoseconds:)).map(Int.init)
        let content = Int(EditedMix.frames(ofNanoseconds: timeMap.duration))
        // 32 323.2, 79 838.4 and 99 198.4 frames: none of them whole.
        #expect(edges == [0, 32_323, 79_838] && content == 99_198)
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        #expect(mix.contentFrames == Int64(content) && mix.totalFrames == 99_200)
        let samples = try await rendered(mix)
        try #require(samples.count == 99_200)
        let lengths = zip(edges, edges.dropFirst() + [content]).map { $1 - $0 }
        #expect(lengths == [32_323, 47_515, 19_360])
        // Each seam is a jump (another speed): the clip before ends faded to 0 on its last frame and the one after starts
        // faded from 0, with sound on either side of those two frames.
        for edge in edges.dropFirst() {
            #expect(samples[edge - 1] == 0 && samples[edge] == 0, "seam at \(edge)")
            #expect(samples[(edge - 6)..<(edge - 1)].contains { $0 != 0 }, "seam at \(edge)")
            #expect(samples[(edge + 1)..<(edge + 6)].contains { $0 != 0 }, "seam at \(edge)")
        }
        for (k, (start, end)) in zip(edges, edges.dropFirst() + [content]).enumerated() {
            let level = rms(samples, (start + 1_000)..<(end - 1_000))
            #expect(abs(level - 0.25 / 2.0.squareRoot()) < 0.01, "clip \(k): RMS \(level)")
        }
        #expect(samples[(content - 6)..<content].contains { $0 != 0 }, "the content goes on to its last frame")
        #expect(samples[content...].allSatisfy { $0 == 0 }, "silence after the content")
    }
}

/// A burst of 1 kHz at 0.5 s of the source, in a clip from the source's start, begins at `0.5 / speed` s of the output
/// within what the effect allows: the stretched sound keeps time with the picture and the clicks. A burst, not an
/// impulse: the effect spreads an impulse over some 50 ms each way, its peak up to 6 ms from where it belongs depending
/// on where the impulse falls between the effect's hops, which says nothing about the stretch's timing.
///
/// The tolerances are what the effect does with bursts at 12 places between its hops: within 1 ms at 0.7× (0 to
/// +0.5 ms) and at 2× (−0.75 to +0.25 ms, the brief's case); at 4× within 4 ms (±2.25 ms, of a burst 50 ms long once
/// sped up); at 0.25× within 6 ms (−4.5 to −3.75 ms: slowed down, the burst's rise spreads over the effect's window,
/// while the centre of its energy stays where it belongs). A latency the effect left unaccounted would show here.
@Test(arguments: [(0.25, 0.05, 0.006), (0.7, 0.05, 0.001), (2, 0.05, 0.001), (4, 0.2, 0.004)])
func stretchedOnsetIsAligned(speed: Double, burstSeconds: Double, tolerance: Double) async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "onset", seconds: 2, mic: burst(at: 0.5, seconds: burstSeconds, takeSeconds: 2))
        let mix = try await EditedMix.make(project: project, document: edited(project, [(0, 2, speed)]), framesPerSecond: 60)
        let samples = try await rendered(mix)
        let begins = try onset(in: samples, near: 0.5 / speed, window: 0.05)
        #expect(abs(begins - 0.5 / speed) <= tolerance, "\(speed)×: the burst begins at \(begins) s, for \(0.5 / speed) s")
    }
}

/// At a speed the effect cannot step its input by exactly (1.3 × 256 frames is not whole), the stretched sound does not
/// drift from the picture over a long clip: a burst at 1 s and one at 27 s of the source begin where the time map puts
/// them within 1 ms, the late one off by what the early one is within 1 ms.
@Test func aLongClipAtAnUnevenSpeedDoesNotDrift() async throws {
    try await withTemporaryDirectory { dir in
        let seconds = 28.0
        let early = toneBurst(at: at(1), start: base, skewPPM: 0, frequency: 1000, channels: 1, amplitude: 0.5, seconds: 0.05)
        let late = toneBurst(at: at(27), start: base, skewPPM: 0, frequency: 1000, channels: 1, amplitude: 0.5, seconds: 0.05)
        let project = try await take(
            in: dir, name: "drift", seconds: seconds,
            mic: [AudioSegmentSpec(start: base, seconds: seconds, amplitude: 0) { late($0, early($0, $1)) }])
        let mix = try await EditedMix.make(project: project, document: edited(project, [(0, seconds, 1.3)]), framesPerSecond: 60)
        let samples = try await rendered(mix)
        let first = try onset(in: samples, near: 1 / 1.3) - 1 / 1.3, last = try onset(in: samples, near: 27 / 1.3) - 27 / 1.3
        #expect(abs(first) <= 0.001 && abs(last) <= 0.001 && abs(last - first) <= 0.001, "off by \(first) s at 1 s, \(last) s at 27 s")
    }
}

/// The stretch is never fed what was cut: a tone recorded only within a cut between two clips at 2× is not in the
/// output, not even at the end of the clip before it, whose stretch takes in silence past its source.
@Test func nothingCutIsStretchedIn() async throws {
    try await withTemporaryDirectory { dir in
        // 440 Hz, but 1000 Hz from 1 to 2 s.
        let burst = toneBurst(at: at(1), start: base, skewPPM: 0, frequency: 1000, channels: 1, amplitude: 0.25, seconds: 1)
        let project = try await take(in: dir, name: "cut", mic: [AudioSegmentSpec(start: base, seconds: 3, transform: burst)])
        let mix = try await EditedMix.make(project: project, document: edited(project, [(0, 1, 2), (2, 3, 2)]), framesPerSecond: 60)
        let samples = try await rendered(mix)
        try #require(samples.count == 48_000)
        // Around the seam, where the stretch of the clip before would take in the cut.
        let cut = toneAmplitude(samples, start: 0, frequency: 1000, from: 0.45, to: 0.5)
        #expect(cut < 1e-3, "1000 Hz at the end of the first clip: \(cut)")
        #expect(toneAmplitude(samples, start: 0, frequency: 440, from: 0.1, to: 0.4) > 0.2)
    }
}

/// After a stretched clip, a clip that goes on with its source can be shorter than the effect's window: the effect is
/// fed that clip's source and no further, so a loud tone in the cut after it never reaches the stretched clip, not even
/// at −90 dB, at 2× or at 4×.
@Test func nothingCutAfterAShortClipIsStretchedIn() async throws {
    try await withTemporaryDirectory { dir in
        // Silence, but 1000 Hz at 0.9 of full scale from 1.005 s.
        let loud = toneBurst(at: at(1.005), start: base, skewPPM: 0, frequency: 1000, channels: 1, amplitude: 0.9, seconds: 1.5)
        let project = try await take(in: dir, name: "short", mic: [AudioSegmentSpec(start: base, seconds: 3, amplitude: 0, transform: loud)])
        let mix = try await EditedMix.make(project: project, document: edited(project, [(0, 3, 1)]), framesPerSecond: 60)
        #expect(try await rendered(mix).contains { abs($0) > 0.8 }, "the tone is there to cut")
        for speed in [2.0, 4] {
            // The clip at `speed`, then 5 ms of the source after it at 1×, then the cut.
            let samples = try await rendered(mix.with(document: edited(project, [(0, 1, speed), (1, 1.005, 1)]), framesPerSecond: 60))
            let peak = samples.map(abs).max() ?? 0
            #expect(peak < 3.2e-5, "\(speed)×: the cut tone at \(20 * log10(Double(peak))) dB")
        }
    }
}

/// A stretched clip that goes on with the source of the clip before is under way at the seam: past the fade in, each
/// 2 ms of its first 20 ms is at its level within 1 dB, at 0.5×, 2× and 4×, instead of rising from silence. (2 ms hold
/// less than a period of 440 Hz, so even a steady tone reads up to ±0.57 dB in them.)
@Test func aStretchGoingOnFromTheClipBeforeIsUnderWayAtTheSeam() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "seam", seconds: 4)
        let mix = try await EditedMix.make(project: project, document: edited(project, [(0, 1, 1)]), framesPerSecond: 60)
        for speed in [0.5, 2, 4] {
            let samples = try await rendered(mix.with(document: edited(project, [(0, 1, 1), (1, 3, speed)]), framesPerSecond: 60))
            let seam = 48_000 + Int(EditedMix.fadeFrames)
            for window in stride(from: seam, to: seam + 960, by: 96) {
                let level = 20 * log10(rms(samples, window..<(window + 96)) / (0.25 / 2.0.squareRoot()))
                #expect(abs(level) < 1, "\(speed)×: \(level) dB at \(window - 48_000) frames from the seam")
            }
        }
    }
}

// MARK: - Above 4× and at 1×

/// A clip faster than 4× is silent, its neighbour fading out into it; at 4× it still plays.
@Test func aboveFourTimesIsSilent() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "fast")
        let mix = try await EditedMix.make(project: project, document: edited(project, [(0, 1, 1), (1, 3, 8)]), framesPerSecond: 60)
        let samples = try await rendered(mix)
        try #require(samples.count == 60_000)
        #expect(abs(rms(samples, 4_800..<43_200) - 0.25 / 2.0.squareRoot()) < 0.005)
        #expect(samples[48_000...].allSatisfy { $0 == 0 })
        #expect(samples[47_999] == 0 && samples[47_000] != 0, "the clip before fades out")

        let eight = try await rendered(mix.with(document: edited(project, [(0, 2, 8)]), framesPerSecond: 60))
        #expect(eight.count == 12_000 && eight.allSatisfy { $0 == 0 })
        let four = try await rendered(mix.with(document: edited(project, [(0, 2, 4)]), framesPerSecond: 60))
        #expect(four.count == 24_000 && abs(rms(four, 2_400..<21_600) - 0.25 / 2.0.squareRoot()) < 0.01)
    }
}

/// A clip at 1× is never stretched: its frames are the track's own, as the mix of Task 28 reads them, bit for bit, and
/// the same whether the clip next to it is stretched or silent.
@Test func oneTimesIsBitIdenticalToNoStretch() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "once")
        let mix = try await EditedMix.make(project: project, document: edited(project, [(0, 3, 1)]), framesPerSecond: 60)
        let samples = try await rendered(mix)
        let track = try #require(project.take.tracks.first { $0.id == micID })
        let timeline = try await AudioTrackTimeline.load(project, track: track, origin: base, channels: 1)
        let read = try await offThePool {
            var frames: [Float] = []
            AudioTrackTimeline.Reader(timeline).read(0..<144_000, into: &frames)
            return frames
        }
        #expect(samples.count == 144_000 && bits(samples) == bits(read.map { 0 + $0 }))

        let stretchedNext = try await rendered(mix.with(document: edited(project, [(0, 1, 1), (1, 3, 2)]), framesPerSecond: 60))
        let silentNext = try await rendered(mix.with(document: edited(project, [(0, 1, 1), (1, 3, 8)]), framesPerSecond: 60))
        #expect(stretchedNext[48_000...].contains { $0 != 0 })
        #expect(bits(stretchedNext[..<48_000]) == bits(silentNext[..<48_000]))
    }
}

/// A speed out of its range is read as the picture reads it (`ClipSpeed.clamped(_:)`): one that is not a number plays
/// at 1×, 0.1× at 0.25×, and 32× at 16×, silent; each mix as long as the time map makes the clip.
@Test func outOfRangeSpeedsAreReadAsThePictureReadsThem() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "range")
        let mix = try await EditedMix.make(project: project, document: edited(project, [(0, 0.5, 1)]), framesPerSecond: 60)
        for (speed, read) in [(Double.nan, 1.0), (0.1, 0.25), (32, 16)] {
            let document = edited(project, [(0, 0.5, speed)]), clamped = edited(project, [(0, 0.5, read)])
            let out = mix.with(document: document, framesPerSecond: 60), within = mix.with(document: clamped, framesPerSecond: 60)
            #expect(out.contentFrames == EditedMix.frames(ofNanoseconds: TimeMap.outputDuration(of: document.sequence[0])))
            #expect(out.totalFrames == within.totalFrames && out.contentFrames == within.contentFrames, "\(speed)×")
            let samples = try await rendered(out)
            #expect(bits(samples) == bits(try await rendered(within)), "\(speed)× is \(read)×")
            #expect(samples.contains { $0 != 0 } == (read <= 4), "\(speed)×")
        }
    }
}

// MARK: - Determinism and random access

/// The same document mixes to the same bits in two new mixes, asked for at once or block by block, from several threads
/// at once, and any range asked for on its own (forward, then back) is that range of the whole: with two tracks, stereo,
/// a clip at 2× split in two without a cut (stretched as the clip unsplit), one at 1× and one at 0.7×, with and without
/// the limiter.
@Test func stretchIsDeterministic() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(
            in: dir, name: "determinism", seconds: 4,
            systemAudio: [AudioSegmentSpec(start: base, seconds: 4, channels: 2, frequency: 1000, amplitude: 0.5)])
        let spans: [(from: Double, to: Double, speed: Double)] = [(0, 0.8, 2), (0.8, 1.6, 2), (1.9, 2.6, 1), (2.6, 3.9, 0.7)]
        for limiter in [false, true] {
            let document = edited(project, spans) { $0.audio.limiter = limiter }
            let first = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            let second = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            func another(_ document: EditDocument = document) -> EditedMix { first.with(document: document, framesPerSecond: 60) }
            #expect(first.channels == 2)
            let whole = try await rendered(first)
            #expect(left(whole).contains { $0 != 0 })
            #expect(bits(try await rendered(second)) == bits(whole), "limiter \(limiter): two runs")
            #expect(bits(try await blockwise(another())) == bits(whole), "limiter \(limiter): by blocks")

            let unsplit = edited(project, [(from: 0, to: 1.6, speed: 2)] + Array(spans.dropFirst(2))) { $0.audio.limiter = limiter }
            #expect(bits(try await rendered(another(unsplit))) == bits(whole), "limiter \(limiter): unsplit")

            let n = first.totalFrames
            // Renders from several threads at once take turns: each gives the bits of its range.
            let shared = another()
            let ranges: [Range<Int64>] = [0..<40_000, 30_000..<90_000, 70_000..<n, 15_000..<16_000]
            try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
                for (i, range) in ranges.enumerated() {
                    group.addTask { (i, try await rendered(shared, range)) }
                }
                for try await (i, samples) in group {
                    let span = Int(ranges[i].lowerBound) * 2..<Int(ranges[i].upperBound) * 2
                    #expect(bits(samples) == bits(whole[span]), "limiter \(limiter): \(ranges[i]) from another thread")
                }
            }
            let again = another()
            // In the first half of the 2× clip, in its second half, in the 0.7× clip; then back.
            for k: Int64 in [9_000, 30_001, 120_000, 20_000] {
                let tail = Array(whole[(Int(k) * 2)...])
                #expect(bits(try await rendered(another(), k..<n)) == bits(tail), "limiter \(limiter): \(k)..<\(n) first")
                #expect(bits(try await rendered(again, k..<n)) == bits(tail), "limiter \(limiter): \(k)..<\(n) after another range")
            }
        }
    }
}

/// Starting in the middle of a clip at 2× of 440 Hz with a preroll of 0.2 s, as the preview does after a jump, the sound
/// is the export's after 200 ms in what matters: the level of every 10 ms within 1 dB and the same pitch within 5 Hz (the
/// phase can differ, since the stretch depends on where it started). The block after it goes on with that stretch; a
/// jump close to the clip's start, within the preroll, stretches from the start, as the export does.
@Test func seekPrerollConverges() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "preroll", seconds: 6)
        let document = edited(project, [(0, 6, 2)])
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let export = try await rendered(mix)
        try #require(export.count == 144_000)

        let k = 72_000, length = 48_000
        let preview = try await rendered(mix.with(document: document, framesPerSecond: 60), Int64(k)..<Int64(k + length), preroll: 0.2)
        try #require(preview.count == length)
        let reference = Array(export[k..<(k + length)])
        for window in stride(from: 9_600, to: length, by: 480) {
            let difference = 20 * log10(rms(preview, window..<(window + 480)) / rms(reference, window..<(window + 480)))
            #expect(abs(difference) < 1, "\(difference) dB at \(k + window)")
        }
        let heard = dominantFrequency(preview, 9_600..<length), expected = dominantFrequency(reference, 9_600..<length)
        #expect(abs(heard - expected) <= 5 && abs(heard - 440) <= 5, "\(heard) Hz for \(expected) Hz")

        let blocks = mix.with(document: document, framesPerSecond: 60)
        let head = try await rendered(blocks, Int64(k)..<Int64(k + 4_096), preroll: 0.2)
        let next = try await rendered(blocks, Int64(k + 4_096)..<Int64(k + 8_192))
        #expect(bits(head + next) == bits(preview[..<8_192]), "the next block goes on")

        let nearStart = try await rendered(mix.with(document: document, framesPerSecond: 60), 4_800..<20_000, preroll: 0.2)
        #expect(bits(nearStart) == bits(export[4_800..<20_000]))
    }
}

/// Where a stretch starts its stream: a range that follows on goes on with the stream under way, whatever the preroll;
/// one that does not, with a preroll, starts a stream that far before it (or rolls on, when the range is that close
/// ahead), and without one, starts a stream at the run's start (or rolls on, when the stream under way started there and
/// the range is ahead of it).
@Test func aStretchStartsAtItsRunOrItsPreroll() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "streams", seconds: 6)
        let track = try #require(project.take.tracks.first { $0.id == micID })
        let timeline = try await AudioTrackTimeline.load(project, track: track, origin: base, channels: 1)
        let run = SpeedStretch.Run(output: 0..<144_000, source: 0, heard: 0..<288_000, speed: 2)
        let steps: [(frames: Range<Int64>, preroll: Int64)] = [
            (72_000..<76_096, 9_600), (76_096..<80_192, 0), (85_000..<86_000, 9_600), (100_000..<101_000, 9_600),
            (110_000..<111_000, 0), (130_000..<131_000, 0), (5_000..<6_000, 9_600),
        ]
        let streams = try await offThePool {
            var stretch = SpeedStretch(timeline)
            var samples: [Float] = []
            return steps.map { step -> [Int64] in
                stretch.read(run, frames: step.frames, preroll: step.preroll, into: &samples)
                precondition(samples.count == step.frames.count)
                return [Int64(stretch.streamsStarted), stretch.lastStart ?? -1]
            }
        }
        #expect(streams == [[1, 62_400], [1, 62_400], [1, 62_400], [2, 90_400], [3, 0], [3, 0], [4, 0]])
    }
}

