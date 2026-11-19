// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

// The players here render into an engine in manual rendering mode, which the test pulls as an output would; nothing
// paces the pulls but the test, which waits for the player to have the frames buffered (a real output never waits).

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// A take of the display and a microphone of noise (of a 440 Hz tone at 1/4 of full scale with `tone`), `seconds`
/// long, with system audio of 1 kHz in stereo when `systemAudio`.
private func take(
    in dir: URL, name: String, seconds: Double, tone: Bool = false, systemAudio: Bool = false, events: [InputEvent] = []
) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addAudioTrack(
        id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: seconds, transform: tone ? nil : noise)])
    if systemAudio {
        try await builder.addAudioTrack(
            id: systemAudioID, kind: .systemAudio, source: systemAudioSource,
            segments: [AudioSegmentSpec(start: base, seconds: seconds, channels: 2, frequency: 1000)])
    }
    try builder.addEvents(events)
    return try builder.write()
}

/// Replaces every frame of a block of a mono audio segment by noise from a hash of the block and the sample, at up to
/// 1/4 of full scale: a frame from the wrong place never matches.
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

/// `mix.render` of `frames` with `preroll`, as the export renders it (by default), read off the cooperative pool.
private func rendered(_ mix: EditedMix, _ frames: Range<Int64>, preroll: Double = 0) async throws -> [Float] {
    try await offThePool {
        var samples: [Float] = []
        mix.render(outputFrames: frames, into: &samples, preroll: preroll)
        return samples
    }
}

private func bits(_ samples: some Collection<Float>) -> [UInt32] { samples.map(\.bitPattern) }

/// The host clock in seconds, the one `PlaybackClock` is read with.
private func hostSeconds() -> Double { Double(HostTime.now().nanoseconds) / 1e9 }

/// An engine rendering by hand, at 48 kHz with `channels` channels, as an output of the mix's own format.
private func manualEngine(channels: Int) throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels)))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
    return engine
}

/// Pulls `frames` frames out of `engine`, `chunk` at a time, interleaved: before each pull, unless `waiting` is false,
/// it waits for `player` to have them buffered.
private nonisolated(nonsending) func pull(
    _ frames: Int, from engine: AVAudioEngine, of player: PreviewAudioPlayer, chunk: Int = 512, waiting: Bool = true
) async throws -> [Float] {
    let format = engine.manualRenderingFormat
    let channels = Int(format.channelCount)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
    var samples: [Float] = []
    while samples.count < frames * channels {
        let count = min(chunk, frames - samples.count / channels)
        if waiting {
            let buffered = await eventually { player.bufferedFrames >= count }
            try #require(buffered, "the player did not buffer \(count) frames")
        }
        let status = try engine.renderOffline(AVAudioFrameCount(count), to: buffer)
        try #require(status == .success && Int(buffer.frameLength) == count)
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<count {
            for channel in 0..<channels { samples.append(data[channel][frame]) }
        }
    }
    return samples
}

// MARK: - The clock

/// While there is audio, the clock is where the samples delivered have got to, less the output's latency: 48 000
/// frames delivered with 10 ms of latency from 5 s stand at 5.99 s when they are delivered, however they come.
@Test func clockFollowsDeliveredSamplesMinusLatency() {
    var clock = PlaybackClock(startSeconds: 5, sampleRate: 48_000)
    #expect(clock.seconds(atHost: 100) == 5)
    clock.delivered(frames: 48_000, latency: 0.010, hostSeconds: 100)
    #expect(abs(clock.seconds(atHost: 100) - 5.99) < 1e-9)
    var inTwo = PlaybackClock(startSeconds: 5, sampleRate: 48_000)
    inTwo.delivered(frames: 24_000, latency: 0.010, hostSeconds: 99.5)
    inTwo.delivered(frames: 24_000, latency: 0.010, hostSeconds: 100)
    #expect(abs(inTwo.seconds(atHost: 100) - 5.99) < 1e-9)
    // Before the first samples come out of the output, it waits where it starts.
    var first = PlaybackClock(startSeconds: 5, sampleRate: 48_000)
    first.delivered(frames: 0, latency: 0.010, hostSeconds: 100)
    #expect(first.seconds(atHost: 100.004) == 5)
    #expect(abs(first.seconds(atHost: 100.110) - 5.1) < 1e-9)
}

/// With no audio after the last delivery (the buffer empty, or the output stopped), the clock goes on by the host's: at
/// host + 0.5 s after 48 000 frames delivered from 5 s with 10 ms of latency, 5.99 + 0.5 s.
@Test func clockFallsBackToHostTimeOnUnderrun() {
    var clock = PlaybackClock(startSeconds: 5, sampleRate: 48_000)
    clock.delivered(frames: 48_000, latency: 0.010, hostSeconds: 100)
    #expect(abs(clock.seconds(atHost: 100.5) - 6.49) < 1e-9)
}

/// The player's clock stands where the node's frames have got to (it starts where `play` was asked to, and counts every
/// frame the node gives, at 48 kHz), goes on by the host's between them, and stops where `stop` found it.
@Test func thePlayersClockFollowsTheFramesTheNodeGave() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "clock", seconds: 3)
        let mix = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 60)
        let engine = try manualEngine(channels: mix.channels)
        let player = PreviewAudioPlayer(mix: mix, engine: engine)
        #expect(player.clock.seconds(atHost: hostSeconds()) == 0)
        try await player.play(fromSeconds: 1.5)
        #expect(player.clock.seconds(atHost: hostSeconds() + 10) == 1.5)
        _ = try await pull(24_000, from: engine, of: player, chunk: 4_000)
        // The last pull gave frames 20 000 to 24 000: it began at 1.5 + 20 000 / 48 000 s.
        let now = hostSeconds(), playing = player.clock.seconds(atHost: now)
        #expect(playing >= 1.5 + 20_000 / 48_000 && playing < 1.5 + 20_000 / 48_000 + 2, "\(playing)")
        player.stop()
        let stopped = player.clock.seconds(atHost: hostSeconds())
        #expect(stopped >= playing && stopped < playing + 2)
        #expect(player.clock.seconds(atHost: hostSeconds() + 10) == stopped)
    }
}

/// When the output changes (`AVAudioEngineConfigurationChange`), the player starts again from where the clock is, with
/// the mix it was playing: the frames after it are the export's from there.
@Test func whenTheOutputChangesItPlaysOnFromTheClock() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "change", seconds: 4)
        let mix = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 60)
        let engine = try manualEngine(channels: 1)
        let player = PreviewAudioPlayer(mix: mix, engine: engine)
        try await player.play(fromSeconds: 0.5)
        let playing = try #require(player.runGeneration)
        _ = try await pull(10_000, from: engine, of: player)
        let before = player.clock.seconds(atHost: hostSeconds())
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        let restarted = await eventually { (player.runGeneration ?? playing) != playing && player.bufferedFrames >= 4_096 }
        try #require(restarted)
        // Nothing heard yet of the new run: its clock stands where it starts, where the old one had got to.
        let position = player.clock.seconds(atHost: hostSeconds() + 10)
        #expect(position >= before && position < before + 5, "\(before) → \(position)")
        let played = try await pull(4_096, from: engine, of: player)
        let start = PreviewAudioPlayer.frame(ofSeconds: position)
        let reference = try await rendered(mix.with(document: .legacy(for: project), framesPerSecond: 60), start..<(start + 4_096))
        #expect(bits(played) == bits(reference))
        player.stop()
    }
}

// MARK: - The mix

/// At 1×, the preview gives the export's samples: an edited document (cuts, gains, click sounds and the limiter) in
/// stereo, played from its start for 2 s and, after a pause, from the middle for 1 s, is `EditedMix.render` of the
/// export bit for bit.
@Test func oneTimesPreviewEqualsExport() async throws {
    try await withTemporaryDirectory { dir in
        let clicks = [0.3, 1.2, 1.9, 2.8].map { InputEvent(t: at($0), kind: .mouseDown(.left, x: 100, y: 100)) }
        let project = try await take(in: dir, name: "same", seconds: 4, systemAudio: true, events: clicks)
        let document = edited(project, clips: [(0, 0.8), (1.1, 2.4), (2.6, 4)]) {
            $0.audio.tracks[AudioPlan.key(take: takeID, track: micID)] = TrackGain(gain: 1.6, muted: false)
            $0.audio.tracks[AudioPlan.key(take: takeID, track: systemAudioID)] = TrackGain(gain: 1.3, muted: false)
            $0.audio.limiter = true
            $0.cursor.clickSound = "soft-1"
        }
        let export = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let mix = export.with(document: document, framesPerSecond: 60)
        #expect(mix.channels == 2)
        let engine = try manualEngine(channels: 2)
        let player = PreviewAudioPlayer(mix: mix, engine: engine)
        try await player.play(fromSeconds: 0)
        let fromTheStart = try await pull(96_000, from: engine, of: player)
        let reference = try await rendered(export.with(document: document, framesPerSecond: 60), 0..<96_000)
        #expect(reference.contains { $0 != 0 })
        #expect(bits(fromTheStart) == bits(reference))
        player.stop()
        try await player.play(fromSeconds: 1.25)
        let fromTheMiddle = try await pull(48_000, from: engine, of: player)
        let middle = try await rendered(export.with(document: document, framesPerSecond: 60), 60_000..<108_000)
        #expect(bits(fromTheMiddle) == bits(middle))
        player.stop()
    }
}

/// `setMix` rules from the next `play`: a mix with the microphone muted, set while playing, leaves what plays the same
/// (the frames already filled and the ones after them); stopped and played again from the same second, it is silence.
@Test func newMixRulesFromTheNextPlay() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "next", seconds: 3)
        let mix = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 60)
        let reference = try await rendered(mix.with(document: .legacy(for: project), framesPerSecond: 60), 0..<12_288)
        #expect(reference.contains { $0 != 0 })
        let engine = try manualEngine(channels: 1)
        let player = PreviewAudioPlayer(mix: mix, engine: engine)
        try await player.play(fromSeconds: 0)
        let before = try await pull(4_096, from: engine, of: player)
        let muted = edited(project, clips: [(0, 3)]) {
            $0.audio.tracks[AudioPlan.key(take: takeID, track: micID)] = TrackGain(gain: 0, muted: false)
        }
        player.setMix(mix.with(document: muted, framesPerSecond: 60))
        let after = try await pull(8_192, from: engine, of: player)
        #expect(bits(before + after) == bits(reference))
        player.stop()
        try await player.play(fromSeconds: 0)
        let again = try await pull(4_096, from: engine, of: player)
        #expect(again.allSatisfy { $0 == 0 })
        player.stop()
    }
}

/// When the output has run past what the player filled (its feeder fell behind), the player skips to a little past
/// where the output is, with a short silence, instead of playing late or rendering what was already missed: every frame
/// the node gives is the export's frame at that place or silence, so the sound keeps time with the clock.
@Test func anUnderrunKeepsTheSoundInTime() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "underrun", seconds: 4)
        let mix = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 60)
        let reference = try await rendered(mix.with(document: .legacy(for: project), framesPerSecond: 60), 0..<140_000)
        let engine = try manualEngine(channels: 1)
        let player = PreviewAudioPlayer(mix: mix, engine: engine)
        try await player.play(fromSeconds: 0)
        let first = try await pull(10_000, from: engine, of: player)
        // The output goes on for 90 000 frames the player has not filled, as if it had stalled behind it.
        let ring = try #require(player.ring)
        var lost = [Float](repeating: 0, count: 90_000)
        _ = lost.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        let place = 100_000, skip = PreviewAudioPlayer.skipFrames
        let buffered = await eventually { ring.writePosition >= place + skip + 4_096 }
        try #require(buffered)
        let rest = try await pull(40_000, from: engine, of: player)
        #expect(bits(first) == bits(reference[..<10_000]))
        let inTime = rest.indices.allSatisfy { rest[$0] == 0 || rest[$0].bitPattern == reference[place + $0].bitPattern }
        #expect(inTime)
        // The silence of the skip, then the export's frames from where they belong.
        let heard = try #require(rest.firstIndex { $0 != 0 })
        #expect(heard >= skip && heard < skip + 64)
        #expect(bits(rest[skip...]) == bits(reference[(place + skip)..<(place + 40_000)]))
        player.stop()
    }
}

/// The first block of each run, from a new mix (`with(document:)`) or after a jump, starts a stretched clip's stretch
/// 0.2 s before (design §7.7, faster than from the clip's start, which the export does) and the blocks after go on with
/// it: the preview from the middle of a clip at 2× is `render` with that preroll, not the export's.
@Test func aJumpIntoAStretchedClipStartsItsStretchAFifthOfASecondBefore() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "stretch", seconds: 8)
        let document = edited(project, clips: [(0, 8)], speed: 2)
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let start: Int64 = 120_000
        let withPreroll = try await rendered(mix.with(document: document, framesPerSecond: 60), start..<(start + 24_000), preroll: 0.2)
        let export = try await rendered(mix.with(document: document, framesPerSecond: 60), start..<(start + 24_000))
        #expect(bits(withPreroll) != bits(export))
        let engine = try manualEngine(channels: 1)
        let player = PreviewAudioPlayer(mix: mix.with(document: document, framesPerSecond: 60), engine: engine)
        try await player.play(fromSeconds: 2.5)
        let played = try await pull(24_000, from: engine, of: player)
        #expect(bits(played) == bits(withPreroll))
        player.stop()
    }
}

/// The editor drives the player from the main actor (`EditorModel`): `play` returns to it without sending the player
/// anywhere, and the engine starts off the main thread while the main actor goes on.
@MainActor @Test func thePlayerIsDrivenFromTheMainActor() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "main", seconds: 2)
        let mix = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 60)
        let engine = try manualEngine(channels: 1)
        let player = PreviewAudioPlayer(mix: mix, engine: engine)
        try await player.play(fromSeconds: 0.5)
        let samples = try await pull(4_096, from: engine, of: player)
        #expect(samples.contains { $0 != 0 })
        player.setMix(mix.with(document: .legacy(for: project), framesPerSecond: 60))
        player.stop()
        #expect(player.clock.seconds(atHost: hostSeconds()) >= 0.5)
    }
}

/// A seek while playing (the same for another mix) keeps the engine running and swaps what it plays: from where the
/// output is, the old sound fades out over 4 ms, silence follows until the new run starts `skipFrames` later, and the new
/// one fades in over 4 ms, then goes on as the export's frames from where it was asked to start. No step from one
/// sample to the next is larger than the tone's own and a fade's, and the gap is within that preroll.
@Test func aSeekWhilePlayingSwapsTheSoundWithShortFades() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "seek", seconds: 6, tone: true)
        let mix = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 60)
        let reference = try await rendered(mix.with(document: .legacy(for: project), framesPerSecond: 60), 0..<288_000)
        let engine = try manualEngine(channels: 1)
        let player = PreviewAudioPlayer(mix: mix, engine: engine)
        try await player.play(fromSeconds: 0)
        let starts = player.engineStarts
        let before = try await pull(20_000, from: engine, of: player)
        try await player.play(fromSeconds: 3)
        #expect(player.engineStarts == starts && engine.isRunning)
        let after = try await pull(30_000, from: engine, of: player)
        player.stop()
        #expect(bits(before) == bits(reference[..<20_000]))
        let fade = AudioRingBuffer.fadeFrames, skip = PreviewAudioPlayer.skipFrames, start = 144_000
        // The old sound fades out from where the output was, the new one fades in where its run starts.
        for k in 0..<fade {
            #expect(abs(after[k] - reference[20_000 + k] * (Float(fade - 1 - k) / Float(fade))) <= 1e-7, "fade out at \(k)")
            #expect(abs(after[skip + k] - reference[start + k] * (Float(k) / Float(fade))) <= 1e-7, "fade in at \(k)")
        }
        #expect(after[fade..<skip].allSatisfy { $0 == 0 })
        #expect(bits(after[(skip + fade)...]) == bits(reference[(start + fade)..<(start + 30_000 - skip)]))
        func steepest(_ samples: some Collection<Float>) -> Float {
            zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        }
        let toneStep = steepest(reference)
        #expect(steepest(before + after) <= toneStep + 0.25 / Float(fade) + 1e-6, "\(steepest(before + after)) vs \(toneStep)")
    }
}

/// The clock never goes back within a run, though the output's own count would: when the output stops pulling for
/// 0.3 s and then goes on, the frames it counts are behind the host's time, and the clock holds where it was going.
@Test func thePlayersClockNeverGoesBack() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await take(in: dir, name: "monotonic", seconds: 3)
        let mix = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 60)
        let engine = try manualEngine(channels: 1)
        let player = PreviewAudioPlayer(mix: mix, engine: engine)
        try await player.play(fromSeconds: 0)
        _ = try await pull(4_096, from: engine, of: player, chunk: 4_096)
        try await Task.sleep(for: .milliseconds(300))
        let stalled = player.clock.seconds(atHost: hostSeconds())
        #expect(stalled >= 0.3)
        _ = try await pull(512, from: engine, of: player)
        let again = player.clock.seconds(atHost: hostSeconds())
        #expect(again >= stalled, "\(stalled) → \(again)")
        player.stop()
    }
}

/// A mix of other channels than the last (a revision that adds system audio to a take with the microphone alone) plays
/// on a new node and ring of its channels, the engine started again: mono, then stereo, each the export's bits.
@Test func aMixOfOtherChannelsPlaysOnANodeOfItsOwn() async throws {
    try await withTemporaryDirectory { dir in
        let mono = try await take(in: dir, name: "mono", seconds: 2)
        let stereo = try await take(in: dir, name: "stereo", seconds: 2, systemAudio: true)
        let monoMix = try await EditedMix.make(project: mono, document: .legacy(for: mono), framesPerSecond: 60)
        let stereoMix = try await EditedMix.make(project: stereo, document: .legacy(for: stereo), framesPerSecond: 60)
        #expect(monoMix.channels == 1 && stereoMix.channels == 2)
        let monoReference = try await rendered(monoMix.with(document: .legacy(for: mono), framesPerSecond: 60), 0..<8_192)
        let stereoReference = try await rendered(stereoMix.with(document: .legacy(for: stereo), framesPerSecond: 60), 0..<8_192)
        let engine = try manualEngine(channels: 2)
        let player = PreviewAudioPlayer(mix: monoMix, engine: engine)
        try await player.play(fromSeconds: 0)
        let starts = player.engineStarts
        let first = try await pull(8_192, from: engine, of: player)
        // The mixer gives a mono node to both channels at unity.
        #expect(bits(stride(from: 0, to: first.count, by: 2).map { first[$0] }) == bits(monoReference))
        #expect(bits(stride(from: 1, to: first.count, by: 2).map { first[$0] }) == bits(monoReference))
        player.setMix(stereoMix)
        try await player.play(fromSeconds: 0)
        #expect(player.engineStarts == starts + 1 && player.ring?.channels == 2)
        let second = try await pull(8_192, from: engine, of: player)
        #expect(bits(second) == bits(stereoReference))
        player.stop()
    }
}
