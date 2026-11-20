// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import Transcription

// Which track a take without a microphone is transcribed from when By App recorded a track of system audio for each app
// (phase 3 design §7.1): the one with the most speech. The takes start at `base` (`TranscriberTests`).

private let displaySource = TrackSource(
    name: "Synthetic Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 320, height: 180), pixelScale: 1)

/// The level of a 10 ms block of a track, by its number from the start of the segment.
private typealias Level = @Sendable (Int) -> Float

/// A steady tone, as music sounds to the measure: never a dip.
private let steady: Level = { _ in 0.25 }
/// Syllables, as speech sounds to it: 150 ms of tone and 100 ms of nothing, four times a second.
private let syllables: Level = { $0 % 25 < 15 ? 0.25 : 0 }
/// `syllables` for the first half of 6 s, then nothing: a call where someone speaks a while.
private let someSpeech: Level = { $0 < 300 ? syllables($0) : 0 }

/// A take of the display, 6 s from `base`, with a track of system audio of each app of `apps` (its id
/// `system-audio-<app>`, as By App names them, in that order), sounding as its level says, and a microphone if `mic`
/// gives its level.
private func appsTake(in dir: URL, name: String, apps: [(app: String, level: Level)], mic: Level? = nil) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: "display-1", source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: 6, framesPerSecond: 10, width: 320, height: 180)])
    if let mic {
        try await builder.addAudioTrack(
            id: micID, source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
            segments: [AudioSegmentSpec(start: base, seconds: 6, transform: sine(mic))])
    }
    for (app, level) in apps {
        try await builder.addAudioTrack(
            id: "system-audio-\(app)", kind: .systemAudio, source: TrackSource(name: app, includedBundleIDs: [app]),
            segments: [AudioSegmentSpec(start: base, seconds: 6, transform: sine(level))])
    }
    return try builder.write()
}

/// Replaces every frame of a 10 ms block of a mono 48 kHz segment by a 440 Hz sine, continuous across the blocks, at
/// the peak `level` gives for the block's number (an `AudioSegmentSpec.transform`).
private func sine(_ level: @escaping Level) -> @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer {
    { block, sample in
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
        let frames = CMSampleBufferGetNumSamples(sample), amplitude = level(block)
        let values = (0..<frames).map { i in amplitude * Float(sin(2 * Double.pi * 440 * Double(block * frames + i) / 48_000)) }
        let status = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
        }
        precondition(status == noErr, "sine block: \(status)")
        return sample
    }
}

/// An engine that hears one word in each span it is given.
private struct OneWordEngine: SpeechEngine {
    func transcribe(_ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechRun] {
        progress(1)
        return audio.spans.map { SpeechRun(text: "hola", start: Double($0.frames.lowerBound) / 48_000, end: Double($0.frames.upperBound) / 48_000) }
    }
}

/// The track the transcript of `project` names.
private func heard(_ project: LoadedProject) async throws -> String? {
    try await Transcriber.transcribe(project, language: "es-MX", engine: OneWordEngine()) { _ in }.takes.first?.track
}

/// Without a microphone, every track of system audio that recorded is a candidate, in the manifest's order; the
/// transcription's job is named by the first, as in phase 2.
@Test func everySystemAudioTrackIsACandidateWithoutAMicrophone() {
    func track(_ id: String, _ kind: TrackKind, segments: Int = 1) -> TrackRecord {
        TrackRecord(
            id: id, kind: kind, source: TrackSource(name: id),
            segments: (0..<segments).map {
                SegmentRecord(
                    index: $0 + 1, file: "takes/take-001/\(id)/seg-000\($0 + 1).m4a", startHostTime: base,
                    endHostTime: base.adding(seconds: 1), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
            })
    }
    func take(_ tracks: [TrackRecord]) -> TakeRecord {
        TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks)
    }
    let display = track("display-1", .display)
    let apps = take([
        display, track("system-audio-com-apple-Music", .systemAudio), track("mic-1", .microphone, segments: 0),
        track("system-audio-us-zoom-xos", .systemAudio), track("system-audio-com-apple-Safari", .systemAudio, segments: 0),
    ])
    #expect(Transcriber.candidates(for: apps).map(\.id) == ["system-audio-com-apple-Music", "system-audio-us-zoom-xos"])
    #expect(Transcriber.track(for: apps)?.id == "system-audio-com-apple-Music")
    let withMic = take([display, track("system-audio-us-zoom-xos", .systemAudio), track("mic-1", .microphone)])
    #expect(Transcriber.candidates(for: withMic).map(\.id) == ["mic-1"])
    let device = take([display, track("device-audio", .deviceAudio), track("device-audio-2", .deviceAudio)])
    #expect(Transcriber.candidates(for: device).map(\.id) == ["device-audio"])
    #expect(Transcriber.candidates(for: take([display])).isEmpty)
}

/// Music and a call, each in its track and no microphone: the call is transcribed, whichever comes first, though the
/// music sounds the whole take and the call half of it.
@Test func theSystemAudioWithTheMostSpeechIsHeard() async throws {
    try await withTemporaryDirectory { dir in
        let musicFirst = try await appsTake(in: dir, name: "music-first", apps: [("com-apple-Music", steady), ("us-zoom-xos", someSpeech)])
        #expect(try await heard(musicFirst) == "system-audio-us-zoom-xos")
        let callFirst = try await appsTake(in: dir, name: "call-first", apps: [("us-zoom-xos", someSpeech), ("com-apple-Music", steady)])
        #expect(try await heard(callFirst) == "system-audio-us-zoom-xos")
        // More speech wins over some.
        let two = try await appsTake(in: dir, name: "two-calls", apps: [("us-zoom-xos", someSpeech), ("com-microsoft-teams2", syllables)])
        #expect(try await heard(two) == "system-audio-com-microsoft-teams2")
    }
}

/// Two tracks with as much speech: the first of the manifest, as in phase 2. A microphone is always the one heard.
@Test func aTieOrAMicrophoneIsTheRuleOfPhase2() async throws {
    try await withTemporaryDirectory { dir in
        let music = try await appsTake(in: dir, name: "two-musics", apps: [("com-apple-Music", steady), ("com-spotify-client", steady)])
        #expect(try await heard(music) == "system-audio-com-apple-Music")
        let quiet = try await appsTake(in: dir, name: "quiet", apps: [("com-apple-Music", { _ in 0 }), ("us-zoom-xos", { _ in 0 })])
        #expect(try await heard(quiet) == "system-audio-com-apple-Music")
        let mic = try await appsTake(in: dir, name: "mic", apps: [("us-zoom-xos", syllables)], mic: steady)
        #expect(try await heard(mic) == micID)
    }
}
