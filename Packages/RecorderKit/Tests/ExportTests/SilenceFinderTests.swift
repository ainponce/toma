// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// The peak amplitude of a sine whose RMS level is `dBFS`.
private func sinePeak(rms dBFS: Double) -> Float { Float(2.0.squareRoot() * pow(10, dBFS / 20)) }

/// The microphone is quiet where its RMS over a window of 50 ms is under −45 dBFS: a tone, a pause with nothing
/// recorded, a tone at −50 dBFS RMS and one at −40 give one quiet span from the end of the first tone to the end of the
/// one at −50, exact to its windows, merged across the pause and the quiet tone.
@Test func quietSpansFollowTheRMS() async throws {
    try await withTemporaryDirectory { dir in
        let quiet = sinePeak(rms: -50), loud = sinePeak(rms: -40)
        let project = try await voiceTake(in: dir, name: "quiet", seconds: 7, mic: [
            AudioSegmentSpec(start: base, seconds: 2),
            // 10 ms blocks: 1 s at −50 dBFS RMS, then 1 s at −40.
            AudioSegmentSpec(start: voiceAt(5), seconds: 2, transform: voiceSine { $0 < 100 ? quiet : loud }),
        ])
        let audio = try await TrackAudio.load(project, track: micID)
        #expect(try await SilenceFinder.quietSpans(audio) == [voiceAt(2)..<voiceAt(6)])
    }
}

/// Before the first segment and after the last, to the end of the take's timeline, the microphone is quiet; a window
/// that is partly sound is measured over all of its frames.
@Test func quietBeforeAndAfterTheMicrophone() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "edges", seconds: 4, mic: [
            AudioSegmentSpec(start: voiceAt(0.5), seconds: 2.5),
        ])
        let audio = try await TrackAudio.load(project, track: micID)
        #expect(try await SilenceFinder.quietSpans(audio) == [base..<voiceAt(0.5), voiceAt(3)..<voiceAt(4)])
    }
}

/// Silences the right channel of every block of a stereo segment, keeping the left (an `AudioSegmentSpec.transform`).
private func leftOnly(_ block: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
    var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size)
    _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
    for i in stride(from: 1, to: values.count, by: 2) { values[i] = 0 }
    let status = values.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
    }
    precondition(status == noErr, "left only: \(status)")
    return sample
}

/// The RMS is over every channel of the track: a sine at −44 dBFS RMS is loud on a mono microphone, and quiet on one
/// channel of a stereo track whose other channel is silent (−47 dBFS RMS over the two).
@Test func theRMSIsOverEveryChannel() async throws {
    try await withTemporaryDirectory { dir in
        let level = sinePeak(rms: -44)
        let project = try await voiceTake(
            in: dir, name: "stereo", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2, amplitude: level)],
            systemAudio: [AudioSegmentSpec(start: base, seconds: 2, channels: 2, amplitude: level, transform: leftOnly)])
        let stereo = try await TrackAudio.load(project, track: systemAudioID)
        #expect(stereo.channels == 2)
        #expect(try await SilenceFinder.quietSpans(stereo) == [base..<voiceAt(2)])
        let mono = try await TrackAudio.load(project, track: micID)
        #expect(mono.channels == 1)
        #expect(try await SilenceFinder.quietSpans(mono) == [])
    }
}

/// A task that is cancelled stops looking.
@Test func findingSilencesStopsWhenCancelled() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "cancel", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2)])
        let audio = try await TrackAudio.load(project, track: micID)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SilenceFinder.quietSpans(audio)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let span = try #require(audio.spans.first)
        let measuring = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Loudness.measure(audio, span: span, clean: nil)
        }
        await #expect(throws: CancellationError.self) { try await measuring.value }
    }
}
