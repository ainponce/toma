// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

private let tone: Float = 0.3

/// What is not quiet is voice: a tone, 2 s of silence, a tone, in one segment.
@Test func voicedIsWhatIsNotQuiet() async throws {
    try await withTemporaryDirectory { dir in
        // 10 ms blocks: tone for the first 100, silence for 200, tone for 100.
        let project = try await voiceTake(in: dir, name: "voiced", seconds: 4, mic: [
            AudioSegmentSpec(start: base, seconds: 4, transform: voiceSine { $0 < 100 || $0 >= 300 ? tone : 0 }),
        ])
        let audio = try await TrackAudio.load(project, track: micID)
        let activity = try await VoiceActivityFinder.voiced(audio)
        #expect(activity.spans == [voiceAt(0)..<voiceAt(1), voiceAt(3)..<voiceAt(4)])
    }
}

/// A pause between two segments, where nothing was recorded, is not voice.
@Test func pausesBetweenSegmentsAreNotVoice() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "pause", seconds: 4, mic: [
            AudioSegmentSpec(start: base, seconds: 1, amplitude: tone),
            AudioSegmentSpec(start: voiceAt(3), seconds: 1, amplitude: tone),
        ])
        let audio = try await TrackAudio.load(project, track: micID)
        let activity = try await VoiceActivityFinder.voiced(audio)
        #expect(activity.spans == [voiceAt(0)..<voiceAt(1), voiceAt(3)..<voiceAt(4)])
        // Twice, the same.
        #expect(try await VoiceActivityFinder.voiced(audio) == activity)
    }
}

@Test func cancellationStops() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "cancel", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2)])
        let audio = try await TrackAudio.load(project, track: micID)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VoiceActivityFinder.voiced(audio)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
