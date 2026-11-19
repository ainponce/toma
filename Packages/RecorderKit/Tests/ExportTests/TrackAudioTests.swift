// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

// The takes here start their display at `base`, frame 0 of the take's timeline (`TakeTimeline.bounds`); `voiceAt(_:)` is
// a time in seconds from there. The helpers are shared with `LoudnessTests` and `SilenceFinderTests`.

func voiceAt(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// A take of the display, `seconds` long from `base`, and a microphone of `mic` (and system audio of `systemAudio`, when
/// there is any).
func voiceTake(
    in dir: URL, name: String, seconds: Double, mic: [AudioSegmentSpec], systemAudio: [AudioSegmentSpec] = []
) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addAudioTrack(id: micID, source: micSource, segments: mic)
    if !systemAudio.isEmpty {
        try await builder.addAudioTrack(id: systemAudioID, kind: .systemAudio, source: systemAudioSource, segments: systemAudio)
    }
    return try builder.write()
}

/// Replaces every frame of a block of an audio segment by noise from a hash of the block and the sample, at up to 1/4 of
/// full scale (an `AudioSegmentSpec.transform`): a frame read from the wrong place never matches.
func voiceNoise(_ block: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
    var state = UInt64(truncatingIfNeeded: block) &* 0x9E37_79B9_7F4A_7C15 &+ 7
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

/// Replaces every frame of a block of a mono 48 kHz segment by a 440 Hz sine, continuous across the blocks, at the peak
/// amplitude `amplitude` gives for the block's number (an `AudioSegmentSpec.transform`).
func voiceSine(_ amplitude: @escaping @Sendable (Int) -> Float) -> @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer {
    { block, sample in
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
        let frames = CMSampleBufferGetNumSamples(sample), level = amplitude(block)
        let values = (0..<frames).map { i in
            level * Float(sin(2 * Double.pi * 440 * Double(block * frames + i) / 48_000))
        }
        let status = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
        }
        precondition(status == noErr, "sine block: \(status)")
        return sample
    }
}

/// Frames `frames` of `audio`, read off the cooperative pool by a reader of its own.
func voiceRead(_ audio: TrackAudio, _ frames: Range<Int64>) async throws -> [Float] {
    try await offThePool {
        let reader = audio.makeReader()
        var samples: [Float] = []
        reader.read(frames, into: &samples)
        return samples
    }
}

/// The bits of `samples`, with −0 as +0: the mix adds each track into zeros.
private func bits(_ samples: [Float]) -> [UInt32] { samples.map { ($0 + 0).bitPattern } }

/// What the analysis reads of a track is what the mix plays of it: the legacy document of a take with only that track, at
/// gain 1, mixes its timeline frame for frame, a segment at 44.1 kHz after a gap of 10 ms (closed) included.
@Test func trackAudioReadsWhatTheMixReads() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "mix", seconds: 3, mic: [
            AudioSegmentSpec(start: base, seconds: 1.5, transform: voiceNoise),
            AudioSegmentSpec(start: voiceAt(1.51), seconds: 1.49, sampleRate: 44_100, transform: voiceNoise),
        ])
        let audio = try await TrackAudio.load(project, track: micID)
        #expect(audio.track == micID && audio.channels == 1 && audio.spans.count == 2)
        // The gap of 10 ms is closed: the second segment follows on where the first one's audio ends.
        #expect(audio.spans.count == 2 && audio.spans[1].frames.lowerBound == audio.spans[0].frames.upperBound)
        let mix = try await EditedMix.make(project: project, document: .legacy(for: project), framesPerSecond: 60)
        let frames = 0..<min(mix.contentFrames, mix.totalFrames)
        let mixed = try await offThePool {
            var samples: [Float] = []
            mix.render(outputFrames: frames, into: &samples)
            return samples
        }
        let read = try await voiceRead(audio, frames)
        #expect(read.contains { $0 != 0 } && read.count == frames.count)
        #expect(bits(read) == bits(mixed))
        // Asked for two channels, a mono track is on both.
        let stereo = try await TrackAudio.load(project, track: micID, channels: 2)
        let both = try await voiceRead(stereo, 40_000..<41_000)
        let one = try await voiceRead(audio, 40_000..<41_000)
        #expect(stereo.channels == 2 && both == one.flatMap { [$0, $0] })
    }
}

/// The spans are the segments the track places on the timeline, each with its file, in order, and frame 0 is the start
/// of the take's timeline.
@Test func spansAreThePlacedSegments() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "spans", seconds: 5, mic: [
            AudioSegmentSpec(start: voiceAt(0.25), seconds: 1),
            AudioSegmentSpec(start: voiceAt(3.25), seconds: 1, frequency: 660),
        ])
        let audio = try await TrackAudio.load(project, track: micID)
        #expect(audio.origin == TakeTimeline.bounds(take: project.take, events: project.events).start && audio.origin == base)
        let files = try #require(project.take.tracks.first { $0.id == micID }).segments.map(\.file)
        #expect(audio.spans.map(\.segment) == files)
        #expect(audio.spans == audio.timeline.placed.map { TrackAudioSpan(segment: $0.segment.file, frames: $0.start..<$0.end) })
        #expect(audio.spans.map(\.frames.lowerBound) == [12_000, 156_000])
        #expect(abs(audio.spans[0].frames.upperBound - 60_000) <= 1 && abs(audio.spans[1].frames.upperBound - 204_000) <= 1)
        #expect(audio.host(atFrame: 156_000) == voiceAt(3.25) && audio.host(atFrame: 0) == base)
        // 1 frame is 20 833.3 ns: rounded to the nearest.
        #expect(audio.host(atFrame: 1) == HostTime(nanoseconds: base.nanoseconds + 20_833))
        #expect(audio.host(atFrame: 2) == HostTime(nanoseconds: base.nanoseconds + 41_667))
        #expect(audio.host(atFrame: -3) == HostTime(nanoseconds: base.nanoseconds - 62_500))
    }
}

/// Only an audio track of the take can be loaded.
@Test func aTrackThatIsNotAudioIsNotLoaded() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "video", seconds: 1, mic: [AudioSegmentSpec(start: base, seconds: 1)])
        await #expect(throws: TrackAudioError.noAudioTrack(displayID)) { try await TrackAudio.load(project, track: displayID) }
        await #expect(throws: TrackAudioError.noAudioTrack("nothing")) { try await TrackAudio.load(project, track: "nothing") }
    }
}
