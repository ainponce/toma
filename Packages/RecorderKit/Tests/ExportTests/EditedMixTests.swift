// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Render
import Testing

// The takes here start their display at `base`, which is then frame 0 of the take's timeline (`TakeTimeline.bounds`),
// the start of its legacy document; `at(_:)` is a time in seconds from there.

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// A take of the display and a microphone, `seconds` long: the microphone's segments are `mic` (by default one of 440 Hz
/// at 1/4 of full scale over the whole take), and system audio's `systemAudio` when there are any.
private func take(
    in dir: URL, name: String, seconds: Double = 3, mic: [AudioSegmentSpec]? = nil, systemAudio: [AudioSegmentSpec] = [],
    events: [InputEvent] = []
) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addAudioTrack(id: micID, source: micSource, segments: mic ?? [AudioSegmentSpec(start: base, seconds: seconds)])
    if !systemAudio.isEmpty {
        try await builder.addAudioTrack(id: systemAudioID, kind: .systemAudio, source: systemAudioSource, segments: systemAudio)
    }
    try builder.addEvents(events)
    return try builder.write()
}

/// The legacy document of `project` with its clips over `spans` (seconds from the take's start), at `speed`, changed by
/// `change`.
private func edited(
    _ project: LoadedProject, clips spans: [(from: Double, to: Double)], speed: Double = 1, _ change: (inout EditDocument) -> Void = { _ in }
) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.sequence = spans.enumerated().map { i, span in
        Clip(id: String(format: "c-%08x", i + 1), take: project.take.id, start: at(span.from), end: at(span.to), speed: speed)
    }
    change(&document)
    return document
}

/// Replaces every frame of a block of a mono audio segment by `value` (an `AudioSegmentSpec.transform`).
private func constant(_ value: Float) -> @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer {
    { _, sample in
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
        let values = [Float](repeating: value, count: CMSampleBufferGetNumSamples(sample))
        let status = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
        }
        precondition(status == noErr, "constant block: \(status)")
        return sample
    }
}

/// Replaces every frame of a block of an audio segment by noise from a hash of the block and the sample, at up to 1/4 of
/// full scale (an `AudioSegmentSpec.transform`): a frame read from the wrong place never matches.
private func noise(_ block: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
    var state = UInt64(truncatingIfNeeded: block) &* 0x9E37_79B9_7F4A_7C15 &+ 1
    let values = (0..<(CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size)).map { _ -> Float in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int64(state >> 33) % 2_001 - 1_000) / 4_000
    }
    let status = values.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
    }
    precondition(status == noErr, "noise block: \(status)")
    return sample
}

private func mouseDown(_ button: MouseButton, at seconds: Double) -> InputEvent {
    InputEvent(t: at(seconds), kind: .mouseDown(button, x: 100, y: 100))
}

/// `mix.render` of `frames` (by default the whole mix), read off the cooperative pool.
private func rendered(_ mix: EditedMix, _ frames: Range<Int64>? = nil) async throws -> [Float] {
    let range = frames ?? 0..<mix.totalFrames
    return try await offThePool {
        var samples: [Float] = []
        mix.render(outputFrames: range, into: &samples)
        return samples
    }
}

private func bits(_ samples: some Collection<Float>) -> [UInt32] { samples.map(\.bitPattern) }

/// Channel 0 of interleaved stereo `samples`.
private func left(_ samples: [Float]) -> [Float] { stride(from: 0, to: samples.count, by: 2).map { samples[$0] } }

/// How much of `samples` (mono, 48 kHz) is a sine of `frequency` Hz at any phase: 1 for that sine alone, near 0 for
/// anything orthogonal to it.
private func correlation(_ samples: [Float], frequency: Double) -> Double {
    var s = 0.0, c = 0.0, energy = 0.0
    for (n, x) in samples.enumerated() {
        let phase = 2 * Double.pi * frequency * Double(n) / 48_000
        s += Double(x) * sin(phase)
        c += Double(x) * cos(phase)
        energy += Double(x) * Double(x)
    }
    return (s * s + c * c).squareRoot() / (energy * Double(samples.count) / 2).squareRoot()
}

/// A seeded generator (SplitMix64), so the "random" positions are the same on every run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Gains, cuts and fades

/// Each track has its gain (0 to 2) and can be muted, one apart from the other.
@Test func gainAndMuteApplyPerTrack() async throws {
    try await withTemporaryDirectory { dir in
        // The microphone's 440 Hz and system audio's 1000 Hz, both at 1/4 of full scale.
        let project = try await take(
            in: dir, name: "gains", systemAudio: [AudioSegmentSpec(start: base, seconds: 3, channels: 2, frequency: 1000)])
        let mic = AudioPlan.key(take: takeID, track: micID), system = AudioPlan.key(take: takeID, track: systemAudioID)
        func plan(mic micGain: TrackGain, system systemGain: TrackGain) -> EditDocument {
            edited(project, clips: [(0, 3)]) {
                $0.audio.tracks[mic] = micGain
                $0.audio.tracks[system] = systemGain
            }
        }

        // The microphone alone at half its level.
        let mix = try await EditedMix.make(
            project: project, document: plan(mic: TrackGain(gain: 0.5, muted: false), system: TrackGain(gain: 1, muted: true)),
            framesPerSecond: 60)
        #expect(mix.channels == 2)
        let half = try await rendered(mix)
        let peak = half.map(abs).max() ?? 0
        #expect(abs(peak - 0.125) <= 0.001, "peak \(peak)")

        // The microphone muted and system audio at twice its level.
        let other = try await rendered(
            mix.with(document: plan(mic: TrackGain(gain: 0.5, muted: true), system: TrackGain(gain: 2, muted: false)), framesPerSecond: 60))
        #expect(toneAmplitude(left(other), start: 0, frequency: 440, from: 0.5, to: 2.5) < 1e-4)
        #expect(abs(toneAmplitude(left(other), start: 0, frequency: 1000, from: 0.5, to: 2.5) - 0.5) < 0.002)

        // Both muted: silence.
        let silent = try await rendered(
            mix.with(document: plan(mic: TrackGain(gain: 1, muted: true), system: TrackGain(gain: 1, muted: true)), framesPerSecond: 60))
        #expect(silent.count == half.count && silent.allSatisfy { $0 == 0 })
    }
}

/// Between two clips the first fades out over its last 192 frames (4 ms) and the second fades in over its first 192,
/// linearly; the start and the end of the output never fade (plan decision 7).
@Test func cutsFadeFourMillisecondsOnEachSide() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "fades", mic: [AudioSegmentSpec(start: base, seconds: 3, transform: constant(0.25))])
        let mix = try await EditedMix.make(project: project, document: edited(project, clips: [(0, 1), (2, 3)]), framesPerSecond: 60)
        let samples = try await rendered(mix)
        try #require(samples.count == 96_000)
        var expected = [Float](repeating: 0.25, count: 96_000)
        for j in 0..<192 { expected[47_999 - j] = 0.25 * (Float(j) / 192) }
        for i in 0..<192 { expected[48_000 + i] = 0.25 * (Float(i) / 192) }
        let worst = zip(samples, expected).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-7, "\(worst) off the fades")
        #expect(samples[0] == 0.25 && samples[95_999] == 0.25, "no fade at the start or the end")
        #expect(samples[47_999] == 0 && samples[48_000] == 0 && samples[47_807] == 0.25 && samples[48_192] == 0.25)
    }
}

/// A tone recorded only within the cut is not in the output, not even at its edges.
@Test func nothingFromACutIsHeard() async throws {
    try await withTemporaryDirectory { dir in
        // 440 Hz, but 1000 Hz from 1 to 2 s.
        let burst = toneBurst(at: at(1), start: base, skewPPM: 0, frequency: 1000, channels: 1, amplitude: 0.25, seconds: 1)
        let project = try await take(in: dir, name: "cut", mic: [AudioSegmentSpec(start: base, seconds: 3, transform: burst)])
        let mix = try await EditedMix.make(project: project, document: edited(project, clips: [(0, 1), (2, 3)]), framesPerSecond: 60)
        let samples = try await rendered(mix)
        #expect(samples.count == 96_000)
        let cut = correlation(samples, frequency: 1000), kept = correlation(samples, frequency: 440)
        #expect(cut < 0.01, "1000 Hz: \(cut)")
        #expect(kept > 0.9, "440 Hz: \(kept)")
    }
}

/// A clip split without a cut (the second part starting where the first ends, at the same speed) mixes the clip
/// unsplit, bit for bit: no fade at the seam, and the source read on from where the first part left off. Split at
/// instants that fall between samples, in two and in three, with click sounds and the limiter too.
@Test func aSplitWithoutACutIsTheClipUnsplit() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(
            in: dir, name: "split", systemAudio: [AudioSegmentSpec(start: base, seconds: 3, channels: 2, frequency: 1000, amplitude: 0.7)],
            events: [mouseDown(.left, at: 0.9), mouseDown(.left, at: 1.234_567_890)])
        for limiter in [false, true] {
            func plan(_ spans: [(from: Double, to: Double)]) -> EditDocument {
                edited(project, clips: spans) {
                    $0.cursor.clickSound = "soft-1"
                    $0.audio.limiter = limiter
                }
            }
            let mix = try await EditedMix.make(project: project, document: plan([(0.1, 2.9)]), framesPerSecond: 60)
            let whole = try await rendered(mix)
            for spans in [[(0.1, 1.234_567_890), (1.234_567_890, 2.9)], [(0.1, 0.700_000_013), (0.700_000_013, 2.222_222_222), (2.222_222_222, 2.9)]] {
                let split = try await rendered(mix.with(document: plan(spans), framesPerSecond: 60))
                #expect(bits(split) == bits(whole), "limiter \(limiter): \(spans)")
            }
        }
    }
}

// MARK: - Clipping and the limiter

/// Without the limiter the sum is clipped, as it always was: the legacy document of `twoAudioTracks` (0.6 and 0.7 of
/// full scale) is exactly ±1 wherever the two tones add up past full scale, and the tones as they are elsewhere.
@Test func withoutLimiterItClipsAsToday() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await GoldenProjects.make("twoAudioTracks", in: dir)
        let mix = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 60)
        let samples = try await rendered(mix)
        try #require(mix.channels == 2 && samples.count == 2 * 144_000)
        // What the encoder gets is this mix, block by block (the golden mix holds it bit for bit).
        #expect(bits(try await MP4Exporter.mixSamples(of: project)) == bits(samples))
        // `SampleFactory`'s sines, whose phase comes from the host time of each 10 ms block.
        var clipped = 0, compared = 0
        for n in 0..<144_000 {
            let start = Double(base.adding(seconds: Double(n / 480 * 480) / 48_000).nanoseconds) / 1e9
            func tone(_ frequency: Double, _ amplitude: Double) -> Double {
                let cycles = frequency * (start + Double(n % 480) / 48_000)
                return Double(Float(amplitude * sin(2 * Double.pi * (cycles - cycles.rounded(.down)))))
            }
            let sum = tone(440, 0.6) + tone(1000, 0.7)
            for c in 0..<2 {
                let x = samples[2 * n + c]
                if abs(sum) > 1.001 {
                    clipped += 1
                    #expect(x == (sum > 0 ? 1 : -1), "frame \(n): \(x) for \(sum)")
                } else if abs(sum) < 0.999 {
                    compared += 1
                    if abs(Double(x) - sum) >= 1e-5 { Issue.record("frame \(n): \(x) for \(sum)") }
                }
            }
        }
        #expect(clipped > 1_000 && compared > 200_000, "\(clipped) clipped, \(compared) compared")
    }
}

/// With the limiter, the same document mixes to the same bits in two new mixes, under −1 dBFS; and asked for block by
/// block, as the export asks, the same bits as in one piece.
@Test func limiterIsDeterministicAcrossRuns() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await GoldenProjects.make("twoAudioTracks", in: dir)
        let document = edited(project, clips: [(0, 1.4), (1.6, 3)]) { $0.audio.limiter = true }
        let first = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let second = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let a = try await rendered(first), b = try await rendered(second)
        #expect(bits(a) == bits(b))
        let peak = a.map(abs).max() ?? 0
        #expect(peak <= PeakLimiter.ceiling + 1e-6 && peak > 0.8, "peak \(peak)")
        // The tones are still there, turned down, not clipped away.
        #expect(toneAmplitude(left(a), start: 0, frequency: 440, from: 0.2, to: 1.2) > 0.25)

        let blocks = first.with(document: document, framesPerSecond: 60)
        let blockwise = try await offThePool {
            var all: [Float] = [], block: [Float] = []
            var position: Int64 = 0
            while position < blocks.totalFrames {
                let end = min(position + 4_096, blocks.totalFrames)
                blocks.render(outputFrames: position..<end, into: &block)
                all += block
                position = end
            }
            return all
        }
        #expect(bits(blockwise) == bits(a))
    }
}

/// The limiter's lookahead is made up for inside the mix: under the ceiling, the limited mix is the mix without it, bit
/// for bit, every transient (each click sound) at its own sample, not 240 frames late.
@Test func theLimiterKeepsTheMixInTime() async throws {
    try await withTemporaryDirectory { dir in
        // At most 0.25 of the microphone and 0.42 × 0.5 of a click: under −1 dBFS.
        let project = try await take(in: dir, name: "inTime", events: [mouseDown(.left, at: 0.25), mouseDown(.left, at: 1.7)])
        let plain = edited(project, clips: [(0, 1.1), (1.3, 3)]) { $0.cursor.clickSound = "mechanical-1" }
        var limited = plain
        limited.audio.limiter = true
        let mix = try await EditedMix.make(project: project, document: plain, framesPerSecond: 60)
        let off = try await rendered(mix), on = try await rendered(mix.with(document: limited, framesPerSecond: 60))
        #expect(off.contains { abs($0) > 0.3 }, "the clicks are there")
        #expect(bits(on) == bits(off))
    }
}

/// With the limiter, a render that starts in the middle of the mix gives the same span of a render from the start,
/// bit for bit: the limiter it starts settles on the frames before it. `twoAudioTracks` passes the ceiling all along.
@Test func aLimitedRenderFromTheMiddleIsTheSpanOfTheWhole() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await GoldenProjects.make("twoAudioTracks", in: dir)
        let document = edited(project, clips: [(0, 1.4), (1.6, 3)]) { $0.audio.limiter = true }
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let whole = try await rendered(mix)
        let n = mix.totalFrames
        let again = mix.with(document: document, framesPerSecond: 60)
        // Before the limiter's settling time from the start, at it, and well after it; then backwards.
        for k: Int64 in [1, 20_000, 48_000, 70_001, 100_000, 133_000, 60_000] {
            let tail = Array(whole[(Int(k) * 2)...])
            #expect(bits(try await rendered(mix.with(document: document, framesPerSecond: 60), k..<n)) == bits(tail), "\(k)..<\(n) first")
            #expect(bits(try await rendered(again, k..<n)) == bits(tail), "\(k)..<\(n) after another range")
        }
    }
}

// MARK: - Click sounds

/// One sound per left or right `mouseDown` kept, from its output frame, at `clickSoundGain`; a second click 30 ms after
/// another is not heard again, another button's never is.
@Test func clickSoundsPlayAtTheirOutputTimesOnceWithin40ms() async throws {
    try await withTemporaryDirectory { dir in
        let events = [
            mouseDown(.left, at: 1.0), InputEvent(t: at(1.01), kind: .mouseUp(.left, x: 100, y: 100)),
            mouseDown(.right, at: 1.030), mouseDown(.left, at: 2.0), mouseDown(.other, at: 2.5),
        ]
        let project = try await take(in: dir, name: "clicks", mic: [AudioSegmentSpec(start: base, seconds: 3, amplitude: 0)], events: events)
        let document = edited(project, clips: [(0, 3)]) {
            $0.cursor.clickSound = "soft-1"
            $0.cursor.clickSoundGain = 0.5
        }
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let samples = try await rendered(mix)
        let sound = try #require(ClickSounds.samples("soft-1"))
        var expected = [Float](repeating: 0, count: 144_000)
        for start in [48_000, 96_000] {
            for (n, x) in sound.enumerated() { expected[start + n] = x * 0.5 }
        }
        #expect(bits(samples) == bits(expected))
    }
}

/// A click at the first instant of a clip after a cut sounds once, at that clip's output start; one at the end of the
/// clip before, which the clip leaves out, does not.
@Test func clickOnTheFirstKeptInstantSoundsOnce() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(
            in: dir, name: "edge", mic: [AudioSegmentSpec(start: base, seconds: 3, amplitude: 0)],
            events: [mouseDown(.left, at: 1.0), mouseDown(.left, at: 2.0)])
        let document = edited(project, clips: [(0, 1), (2, 3)]) {
            $0.cursor.clickSound = "mechanical-1"
            $0.cursor.clickSoundGain = 1
        }
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let samples = try await rendered(mix)
        let sound = try #require(ClickSounds.samples("mechanical-1"))
        var expected = [Float](repeating: 0, count: 96_000)
        for (n, x) in sound.enumerated() { expected[48_000 + n] = x }
        #expect(bits(samples) == bits(expected))
    }
}

/// A click in a clip at another speed sounds at its output time, `O_k + round((x − s_k) / v_k)`: at 2× from source
/// 1 s, the click at source 2 s is at output 1.5 s, frame 72 000. It is not stretched.
@Test func aClickInAClipAtAnotherSpeedSoundsAtItsOutputTime() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(
            in: dir, name: "spedClick", mic: [AudioSegmentSpec(start: base, seconds: 3, amplitude: 0)], events: [mouseDown(.left, at: 2.0)])
        var document = edited(project, clips: [(0, 1)]) {
            $0.cursor.clickSound = "soft-1"
            $0.cursor.clickSoundGain = 1
        }
        document.sequence.append(Clip(id: "c-00000002", take: takeID, start: at(1), end: at(3), speed: 2))
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let samples = try await rendered(mix)
        let sound = try #require(ClickSounds.samples("soft-1"))
        var expected = [Float](repeating: 0, count: 96_000)
        for (n, x) in sound.enumerated() { expected[72_000 + n] = x }
        #expect(bits(samples) == bits(expected))
    }
}

/// A click in a cut makes no sound.
@Test func clicksInACutAreSilent() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(
            in: dir, name: "cutClick", mic: [AudioSegmentSpec(start: base, seconds: 3, amplitude: 0)], events: [mouseDown(.left, at: 1.5)])
        let document = edited(project, clips: [(0, 1), (2, 3)]) { $0.cursor.clickSound = "soft-1" }
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let samples = try await rendered(mix)
        #expect(samples.count == 96_000 && samples.allSatisfy { $0 == 0 })
    }
}

// MARK: - Random access, revisions and length

/// Without the limiter, any range of the mix is the same whatever was asked for before it: a new mix asked for
/// `k..<N` first, the same mix asked for `0..<k` and then `k..<N`, and `k..<N` again from behind where the mix is, all
/// give the bits of `0..<N`. Also across a pause cut out of `pausedTake`, and across gaps of 12 and 3 ms that the
/// timeline closes from where the audio before ended.
@Test func randomAccessEqualsSequential() async throws {
    try await withTemporaryDirectory { dir in
        let clicked = try await take(
            in: dir, name: "random", events: [mouseDown(.left, at: 0.5), mouseDown(.left, at: 1.2), mouseDown(.right, at: 2.6)])
        let gaps = try await take(in: dir, name: "gaps", mic: [
            AudioSegmentSpec(start: base, seconds: 1),
            AudioSegmentSpec(start: at(1.012), seconds: 1, frequency: 660),
            AudioSegmentSpec(start: at(2.015), seconds: 0.98),
        ])
        let paused = try await GoldenProjects.make("pausedTake", in: dir)
        let cases: [(String, LoadedProject, EditDocument)] = [
            ("clicks", clicked, edited(clicked, clips: [(0, 0.8), (1.1, 1.9), (2.2, 3)]) {
                $0.audio.tracks[AudioPlan.key(take: takeID, track: micID)] = TrackGain(gain: 0.7, muted: false)
                $0.cursor.clickSound = "soft-1"
            }),
            ("gaps legacy", gaps, .legacy(for: gaps)),
            ("gaps cut", gaps, edited(gaps, clips: [(0.2, 1.5), (1.7, 2.9)])),
            ("pausedTake legacy", paused, .legacy(for: paused)),
            ("pausedTake without the pause", paused, edited(paused, clips: [(0, 1), (2, 3)])),
        ]
        var generator = SplitMix(state: 28)
        for (name, project, document) in cases {
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            let n = mix.totalFrames, channels = mix.channels
            let whole = try await rendered(mix)
            #expect(whole.contains { $0 != 0 }, "\(name)")
            for _ in 0..<3 {
                let k = Int64.random(in: 1..<n, using: &generator)
                let tail = Array(whole[(Int(k) * channels)...])
                let cold = try await rendered(mix.with(document: document, framesPerSecond: 60), k..<n)
                #expect(bits(cold) == bits(tail), "\(name): \(k)..<\(n) first")
                let split = mix.with(document: document, framesPerSecond: 60)
                let head = try await rendered(split, 0..<k)
                let rest = try await rendered(split, k..<n)
                #expect(bits(head + rest) == bits(whole), "\(name): 0..<\(k), then \(k)..<\(n)")
                let again = try await rendered(split, k..<n)
                #expect(bits(again) == bits(tail), "\(name): \(k)..<\(n) again")
            }
        }
    }
}

/// Renders asked for from several threads at once take turns (`render` holds a lock while it reads): each gives the
/// bits of its range.
@Test func rendersFromSeveralThreadsTakeTurns() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "threads", events: [mouseDown(.left, at: 0.4), mouseDown(.left, at: 2.2)])
        let document = edited(project, clips: [(0, 1.2), (1.5, 3)]) { $0.cursor.clickSound = "soft-1" }
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let whole = try await rendered(mix)
        let ranges: [Range<Int64>] = [0..<30_000, 20_000..<70_000, 50_000..<mix.totalFrames, 10_000..<11_000, 65_000..<66_000]
        try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            for (i, range) in ranges.enumerated() {
                group.addTask { (i, try await rendered(mix, range)) }
            }
            for try await (i, samples) in group {
                #expect(bits(samples) == bits(whole[Int(ranges[i].lowerBound)..<Int(ranges[i].upperBound)]), "\(ranges[i])")
            }
        }
    }
}

/// A track's reader starts the file near the frame asked for, at least one ALAC packet before it, and reads the samples
/// a reader from the file's start does: right after the segment's start, across packets, in the middle and at its very
/// end. A segment at 48 kHz is started one packet before; one the reader resamples (a microphone at 44.1 kHz, mono or
/// stereo, or at 24, 16, 11.025 or 8 kHz), at the last frame before that where one of its samples and a decoded frame
/// fall at the same time (every 160, 2, 3, 640 and 6 frames), from where the resampler gives the frames it gives from
/// the start once it has taken in a few, and to the very end (where it may run out a few frames early).
@Test(arguments: [(48_000.0, 1), (44_100.0, 1), (44_100.0, 2), (24_000.0, 1), (16_000.0, 1), (11_025.0, 1), (8_000.0, 1)])
func aTrackIsReadFromNearTheFrameAskedFor(rate: Double, channels: Int) async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(
            in: dir, name: "seek\(Int(rate))", seconds: 20,
            mic: [AudioSegmentSpec(start: base, seconds: 20, sampleRate: rate, channels: channels, transform: noise)])
        let track = try #require(project.take.tracks.first { $0.id == micID })
        let timeline = try await AudioTrackTimeline.load(project, track: track, origin: base, channels: channels)
        let placed = try #require(timeline.placed.first)
        #expect(placed.seekOrigin != nil, "\(rate) Hz")
        let step = try #require(AudioTrackTimeline.seekGrid(sourceRate: rate)).decoded
        #expect(step == [48_000: 1, 44_100: 160, 24_000: 2, 16_000: 3, 11_025: 640, 8_000: 6][Int(rate)])
        // The whole segment, read in order from its start.
        let all = placed.start..<placed.end
        let whole = try await offThePool {
            let reader = AudioTrackTimeline.Reader(timeline)
            var samples: [Float] = [], block: [Float] = []
            var frame = all.lowerBound
            while frame < all.upperBound {
                let end = min(frame + 4_096, all.upperBound)
                reader.read(frame..<end, into: &block)
                samples += block
                frame = end
            }
            return samples
        }
        #expect(whole.count == all.count * channels && whole.contains { $0 != 0 })
        let length = all.count
        for offset in [1, 100, 4_095, 4_097, 4_257, 8_193, 250_001, length / 2, length - 4_000, length - 10, length - 1] {
            let from = all.lowerBound + Int64(offset), to = min(from + 3_000, all.upperBound)
            let (part, opening) = try await offThePool {
                let reader = AudioTrackTimeline.Reader(timeline)
                var samples: [Float] = []
                reader.read(from..<to, into: &samples)
                return (samples, reader.lastOpening)
            }
            let range = (offset * channels)..<((offset + Int(to - from)) * channels)
            #expect(bits(part) == bits(whole[range]), "\(rate) Hz from \(offset)")
            let needed = Int64(placed.segment.map.decoded(atOutput: Double(from)).rounded(.down))
            let start = (needed - AudioTrackTimeline.seekPreroll) / step * step
            let expected = needed > AudioTrackTimeline.seekPreroll && start > 0 ? start : 0
            #expect(opening == expected, "\(rate) Hz from \(offset): started at \(String(describing: opening))")
        }
    }
}

/// What tells a segment the reader resamples it can be started in the middle: a reader started on a frame where one of
/// the file's samples falls gives the frames of a reader from the start, `seekPreroll` frames on; started 7 frames
/// later, off that grid, it never does (its resampler runs at another phase), and the check says so.
@Test func aResampledSegmentIsStartedOnlyWhereItGivesTheSameFrames() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(
            in: dir, name: "probe", seconds: 10, mic: [AudioSegmentSpec(start: base, seconds: 10, sampleRate: 44_100, transform: noise)])
        let track = try #require(project.take.tracks.first { $0.id == micID })
        let timeline = try await AudioTrackTimeline.load(project, track: track, origin: base, channels: 1)
        let placed = try #require(timeline.placed.first)
        let origin = try #require(placed.seekOrigin)
        let (onTheGrid, offTheGrid) = try await offThePool {
            (try AudioTrackTimeline.startsExactly(placed.segment, channels: 1, origin: origin, at: 160 * 1_000),
             try AudioTrackTimeline.startsExactly(placed.segment, channels: 1, origin: origin, at: 160 * 1_000 + 7))
        }
        #expect(onTheGrid && !offTheGrid)
    }
}

/// How long the first render of a revision takes at different points of a 10 min take with a microphone (at 48 kHz, or
/// at 44.1 kHz, which the reader resamples) and system audio at 48 kHz, one segment each, and how long making the mix
/// takes. Run by an agent, with `TOMA_BENCH=1`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"), arguments: [48_000.0, 44_100.0])
func seekLatencyOnALongTake(microphoneRate: Double) async throws {
    try await withTemporaryDirectory { dir in
        let minutes = 10.0
        let project = try await take(
            in: dir, name: "long", seconds: minutes * 60, mic: [AudioSegmentSpec(start: base, seconds: minutes * 60, sampleRate: microphoneRate)],
            systemAudio: [AudioSegmentSpec(start: base, seconds: minutes * 60, channels: 2, frequency: 1000)])
        let document = EditDocument.legacy(for: project)
        let clock = ContinuousClock()
        var made: EditedMix?
        let making = try await clock.measure { made = try await EditedMix.make(project: project, document: document, framesPerSecond: 60) }
        let mix = try #require(made)
        let name = "seekLatencyOnALongTake (microphone at \(Int(microphoneRate)) Hz)"
        print("\(name): make \(making) for \(minutes) min of microphone and system audio")
        for seconds in [1.0, 60, 300, minutes * 60 - 1] {
            let start = Int64(seconds * 48_000)
            let revision = mix.with(document: document, framesPerSecond: 60)
            let latency = try await offThePool {
                clock.measure {
                    var block: [Float] = []
                    revision.render(outputFrames: start..<(start + 4_096), into: &block)
                }
            }
            print("\(name): first block at \(seconds) s of a new revision: \(latency)")
        }
    }
}

/// Another revision of the document mixes as a new mix of it would, bit for bit, reusing where the audio of each
/// segment was found to end instead of decoding the segments again.
@Test func anotherRevisionReusesTheSourceIndex() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(
            in: dir, name: "revision",
            mic: [AudioSegmentSpec(start: base, seconds: 1.5), AudioSegmentSpec(start: at(1.51), seconds: 1.49, frequency: 660)],
            events: [mouseDown(.left, at: 0.7), mouseDown(.left, at: 2.1)])
        let mix = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 60)
        #expect(mix.prereadSegments == 2)
        let other = edited(project, clips: [(0.3, 1.0), (1.4, 2.9)]) {
            $0.audio.tracks[AudioPlan.key(take: takeID, track: micID)] = TrackGain(gain: 1.6, muted: false)
            $0.audio.limiter = true
            $0.cursor.clickSound = "mechanical-1"
        }
        let revised = mix.with(document: other, framesPerSecond: 60)
        #expect(revised.prereadSegments == 0 && revised.source === mix.source)
        let fresh = try await EditedMix.make(project: project, document: other, framesPerSecond: 60)
        #expect(fresh.prereadSegments == 2 && fresh.source !== mix.source)
        #expect(revised.totalFrames == fresh.totalFrames && revised.channels == fresh.channels)
        #expect(bits(try await rendered(revised)) == bits(try await rendered(fresh)))
    }
}

/// The mix lasts what the video lasts at each frame rate, `round(frameCount / fps × 48 000)` frames; its content goes
/// on to `round(D × 48 000 / 10⁹)`, silence after it or cut before it.
@Test func audioLastsAsLongAsTheVideoAtEachFrameRate() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "length")
        // D = 1.0101 s: 61 frames at 60 fps, 24 at 24 fps; 48 484.8 frames of audio.
        let document = edited(project, clips: [(0, 1.0101)])
        let sixty = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        #expect(sixty.totalFrames == Int64((61.0 / 60 * 48_000).rounded()) && sixty.totalFrames == 48_800)
        #expect(sixty.contentFrames == 48_485)
        let samples = try await rendered(sixty)
        try #require(samples.count == 48_800)
        // The content to its end; its last 192 frames fade out, the clip's end being trimmed inside the take.
        #expect(abs(rms(samples, start: 0, from: 47_293.0 / 48_000, to: 48_293.0 / 48_000) - 0.25 / 2.0.squareRoot()) < 0.01)
        #expect(samples[48_484] == 0 && samples[48_292] != 0, "the content goes on to its end")
        #expect(samples[48_485...].allSatisfy { $0 == 0 }, "silence after the content")

        let twentyFour = sixty.with(document: document, framesPerSecond: 24)
        #expect(twentyFour.totalFrames == Int64((24.0 / 24 * 48_000).rounded()) && twentyFour.totalFrames == 48_000)
        #expect(bits(try await rendered(twentyFour)) == bits(samples[..<48_000]), "the content, cut at the end of the video")
    }
}

// MARK: - What could not be used, and the export

/// A segment that cannot be opened is listed where its span is in the output, with the cuts in it closed: not at all
/// when it is all cut, at its own time with the legacy document.
@Test func missingAudioIsListedInOutputTime() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir, name: "missing")
        try await builder.addVideoTrack(
            id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3, framesPerSecond: 10, width: 320, height: 180)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 1)])
        try builder.addEmptySegment(track: micID, index: 2, start: at(1), end: at(2), endReason: .stopped, file: .garbage(bytes: 4096))
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: at(2), seconds: 1)])
        let project = try builder.write()
        let file = "takes/take-001/mic/seg-0002.mov"

        let legacy = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 30)
        let listed = try #require(legacy.missingAudio.first)
        #expect(legacy.missingAudio.count == 1 && listed.file == file && listed.track == micID)
        #expect(abs(listed.start - 1) < 1e-6 && abs(listed.end - 2) < 1e-6, "\(listed)")
        guard case .cannotOpen = listed.reason else {
            Issue.record("\(listed.reason)")
            return
        }

        // Source 1.5 to 2 s is output 0.5 to 1 s.
        let partly = legacy.with(document: edited(project, clips: [(0, 0.5), (1.5, 3)]), framesPerSecond: 30)
        let moved = try #require(partly.missingAudio.first)
        #expect(partly.missingAudio.count == 1 && moved.file == file)
        #expect(abs(moved.start - 0.5) < 1e-6 && abs(moved.end - 1) < 1e-6, "\(moved)")

        let cut = legacy.with(document: edited(project, clips: [(0, 1), (2, 3)]), framesPerSecond: 30)
        #expect(cut.missingAudio.isEmpty, "\(cut.missingAudio)")
    }
}

/// The export plays the mix of its document: what `mixSamples` gives for it, and in the MP4 the cut tone is gone and
/// the audio lasts the 2 s the document does.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func theExportPlaysTheEditedMix() async throws {
    try await withTemporaryDirectory { dir in
        let burst = toneBurst(at: at(1), start: base, skewPPM: 0, frequency: 1000, channels: 1, amplitude: 0.25, seconds: 1)
        let project = try await take(in: dir, name: "export", mic: [AudioSegmentSpec(start: base, seconds: 3, transform: burst)])
        let document = edited(project, clips: [(0, 1), (2, 3)])
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 30)
        #expect(bits(try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 30)) == bits(try await rendered(mix)))

        let destination = dir.appending(path: "edited.mp4")
        let summary = try await MP4Exporter(project: project, document: document, settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30))
            .export(to: destination) { _ in }
        #expect(summary == ExportSummary())
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(abs(Double(samples.count) / 48_000 + start - 2) < 0.05, "\(samples.count) frames from \(start) s")
        let middle = Array(samples[Int((0.1 - start) * 48_000)..<Int((1.9 - start) * 48_000)])
        #expect(correlation(middle, frequency: 1000) < 0.02)
        #expect(correlation(middle, frequency: 440) > 0.9)
    }
}
