// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// A microphone whose clock runs 2000 ppm fast: the builder logs the `audioClock` anchors the pipeline would,
/// one every 5 s of host time, each naming the first frame of a 10 ms block and that block's host time.
@Test func takeBuilderLogsAnchorsWithSkew() async throws {
    try await withTemporaryDirectory { dir in
        let start = HostTime(nanoseconds: 5_000_000_000_000)
        let skew = 2000.0
        let builder = try TakeBuilder(in: dir)
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
            segments: [AudioSegmentSpec(start: start, seconds: 12, clockSkewPPM: skew)])
        let project = try builder.write()

        let anchors = project.events.compactMap { event -> (frame: Int, t: HostTime)? in
            guard case let .audioClock(track, frame) = event.kind, track == "mic" else { return nil }
            return (frame, event.t)
        }
        try #require(anchors.count == 2, "\(anchors)")
        for anchor in anchors {
            #expect(anchor.frame % 480 == 0)
            let expected = Double(anchor.frame) / 48_000 * (1 + skew * 1e-6)
            #expect(abs(anchor.t.seconds(since: start) - expected) < 0.001, "frame \(anchor.frame) at \(anchor.t.seconds(since: start)) s")
        }
    }
}

/// A package an earlier version of the app created: the manifest says so before and after the take is written.
@Test func takeBuilderWritesAnOlderFormatVersion() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir, formatVersion: 1)
        let created = try Data(contentsOf: builder.package.manifestURL)
        #expect(try Manifest.formatVersion(of: created) == 1)
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
            segments: [AudioSegmentSpec(start: HostTime(nanoseconds: 5_000_000_000_000), seconds: 1)])
        let project = try builder.write()

        #expect(project.manifest.formatVersion == 1)
        #expect(try LoadedProject.load(builder.package.url).manifest == project.manifest)
        #expect(project.take.tracks.map(\.id) == ["mic"])
    }
}
