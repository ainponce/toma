// SPDX-License-Identifier: GPL-3.0-or-later
import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

// Phase 3 (base plan, Task B3, decision 12; design §7.1, §11): a take with a track of system audio per app is mixed by
// the mixer of phase 2 as it is, each track by its own key at 1 when the document has none, with the channels of the
// widest. So such a take keeps its version: nothing a reader of phase 2 does with it needs a new one.

private let safariID = "system-audio-com-apple-Safari"
private let spotifyID = "system-audio-com-spotify-client"

/// `mix.render` of the whole mix, read off the cooperative pool.
private func rendered(_ mix: EditedMix) async throws -> [Float] {
    try await offThePool {
        var samples: [Float] = []
        mix.render(outputFrames: 0..<mix.totalFrames, into: &samples)
        return samples
    }
}

/// Channel 0 of interleaved stereo `samples`.
private func left(_ samples: [Float]) -> [Float] { stride(from: 0, to: samples.count, by: 2).map { samples[$0] } }

@Test func threeAppTracksMixAsTheirSum() async throws {
    try await withTemporaryDirectory { dir in
        // The microphone's 440 Hz, Safari's 660 Hz and Spotify's 880 Hz, each at 1/4 of full scale; the apps in stereo.
        let builder = try TakeBuilder(in: dir, name: "Apps")
        try await builder.addVideoTrack(
            id: displayID, source: displaySource,
            segments: [VideoSegmentSpec(start: base, seconds: 3, framesPerSecond: 10, width: 320, height: 180)])
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3, frequency: 440)])
        try await builder.addAudioTrack(
            id: safariID, kind: .systemAudio, source: TrackSource(name: "Safari", includedBundleIDs: ["com.apple.Safari"]),
            segments: [AudioSegmentSpec(start: base, seconds: 3, channels: 2, frequency: 660)])
        try await builder.addAudioTrack(
            id: spotifyID, kind: .systemAudio, source: TrackSource(name: "Spotify", includedBundleIDs: ["com.spotify.client"]),
            segments: [AudioSegmentSpec(start: base, seconds: 3, channels: 2, frequency: 880)])
        let project = try builder.write()
        #expect(project.manifest.formatVersion == 3)

        let legacy = EditDocument.legacy(for: project)
        let mix = try await EditedMix.make(project: project, document: legacy, framesPerSecond: 60)
        #expect(mix.channels == 2)
        let all = try await rendered(mix)

        // Each alone: the other two muted.
        let ids = [micID, safariID, spotifyID]
        var alone: [[Float]] = []
        for id in ids {
            var document = legacy
            for other in ids where other != id {
                document.audio.tracks[AudioPlan.key(take: takeID, track: other)] = TrackGain(gain: 1, muted: true)
            }
            alone.append(try await rendered(mix.with(document: document, framesPerSecond: 60)))
        }
        for (samples, frequency) in zip(alone, [440.0, 660, 880]) {
            #expect(samples.count == all.count)
            #expect(abs(toneAmplitude(left(samples), start: 0, frequency: frequency, from: 0.5, to: 2.5) - 0.25) < 0.002, "\(frequency) Hz")
            for other in [440.0, 660, 880] where other != frequency {
                #expect(toneAmplitude(left(samples), start: 0, frequency: other, from: 0.5, to: 2.5) < 1e-3, "\(other) Hz in \(frequency) Hz")
            }
        }
        // The whole mix is their sum, added in the order of the take's tracks as the mixer adds them: bit for bit.
        let sum = all.indices.map { i in alone[0][i] + alone[1][i] + alone[2][i] }
        #expect(all.map(\.bitPattern) == sum.map(\.bitPattern))
    }
}
