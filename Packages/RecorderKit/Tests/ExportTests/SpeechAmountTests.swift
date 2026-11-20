// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

// The takes start at `base` (`TrackAudioTests`); the levels are by 10 ms block of the segment (`voiceSine`).

/// Syllables: 150 ms of tone and 100 ms of nothing, four times a second.
private let syllables: @Sendable (Int) -> Float = { $0 % 25 < 15 ? 0.25 : 0 }

/// A steady tone never dips, so none of it is speech; syllables are, every second of them, and only those.
@Test func syllablesAreSpeechAndASteadyToneIsNot() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "speech", seconds: 6, mic: [AudioSegmentSpec(start: base, seconds: 6)])
        #expect(try await SpeechAmount.seconds(try await TrackAudio.load(project, track: micID)) == 0)
        // 3 s of syllables, 1 s of steady tone, 2 s of nothing.
        let spoken = try await voiceTake(in: dir, name: "spoken", seconds: 6, mic: [
            AudioSegmentSpec(start: base, seconds: 6, transform: voiceSine { $0 < 300 ? syllables($0) : $0 < 400 ? 0.25 : 0 }),
        ])
        let audio = try await TrackAudio.load(spoken, track: micID)
        #expect(try await SpeechAmount.seconds(audio) == 3)
        // Twice, the same.
        #expect(try await SpeechAmount.seconds(audio) == 3)
    }
}

/// Syllables too quiet to be heard (under −45 dBFS) are not speech, nor is what was not recorded: a second wholly in a
/// pause between two segments is not read, and one partly in a segment is measured over all of its frames.
@Test func quietAndPausesAreNotSpeech() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "quiet", seconds: 8, mic: [
            AudioSegmentSpec(start: base, seconds: 2, transform: voiceSine { syllables($0) * 0.01 }),
            AudioSegmentSpec(start: voiceAt(4), seconds: 2, transform: voiceSine(syllables)),
            // Half a second of steady tone: the second it is in is half nothing, which dips as speech does.
            AudioSegmentSpec(start: voiceAt(7), seconds: 0.5),
        ])
        #expect(try await SpeechAmount.seconds(try await TrackAudio.load(project, track: micID)) == 3)
        #expect(SpeechAmount.lowEnergyShare == 0.3)
    }
}

@Test func speechAmountCancellationStops() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "cancel", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2)])
        let audio = try await TrackAudio.load(project, track: micID)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SpeechAmount.seconds(audio)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
