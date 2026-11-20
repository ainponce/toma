// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Synchronization
import SyntheticCapture
import Testing

// The Replay end to end (fases 4 y 5 plan 5c, R2 with R3): the real ring of `ReplayCoordinator`, from synthetic sources,
// saved by `ReplaySaver`. Here because this target sees both Recording and Editing.

@Suite(.serialized) struct ReplayRoundTripTests {
    /// The shortcut pressed twice: two saves at once of the live ring, each a whole project of the last N seconds.
    @Test func savesOfTheLiveRingAreProjectsOfTheLastNSeconds() async throws {
        try await withTemporaryDirectory { dir in
            let display = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30)
            let camera = SyntheticVideoSource(trackID: "camera", kind: .camera, width: 320, height: 180, framesPerSecond: 30)
            let mic = SyntheticAudioSource()
            let disk = FakeDisk()
            let coordinator = ReplayCoordinator(
                scratchRoot: dir.appending(path: "Replay", directoryHint: .isDirectory), app: AppInfo(name: "Tests", version: "0"),
                sources: [display, camera, mic], input: SyntheticInputRecorder(), diskMonitor: disk.monitor(volume: dir),
                configuration: ReplayConfiguration(seconds: 2, segmentDuration: .seconds(1), pruneMargin: .seconds(1)))
            let scratch = try await coordinator.start()
            try await Task.sleep(for: .milliseconds(4500))

            async let first = ReplaySaver.save(from: coordinator, Self.request(dir, name: "Replay A"))
            async let second = ReplaySaver.save(from: coordinator, Self.request(dir, name: "Replay B"))
            let results = try await [first, second]

            for result in results {
                #expect(abs(result.duration.seconds - 2) < 0.001, "\(result.duration)")
                let project = try LoadedProject.load(result.projectURL)
                #expect(project.take.status == .complete)
                #expect(project.take.tracks.map(\.kind) == [.display, .camera, .microphone])
                #expect(project.take.cameraStyle == .default)
                for track in project.take.tracks {
                    #expect(!track.segments.isEmpty, "\(track.id)")
                    #expect(track.segments.map(\.index) == Array(1...track.segments.count), "\(track.id)")
                    #expect(!track.segments.contains { $0.endReason == .rotated }, "\(track.id)")
                    for segment in track.segments {
                        #expect(FileManager.default.fileExists(atPath: project.package.url.appending(path: segment.file).path))
                    }
                }
                let screen = try #require(project.take.track("display-1")).segments
                let span = try #require(screen.compactMap(\.endHostTime).max()).seconds(since: try #require(screen.first).startHostTime)
                #expect(span >= 2, "the saved screen lasts \(span) s")
                #expect(project.events.contains { if case .cursor = $0.kind { true } else { false } })
                #expect(project.events.contains { if case .cursorImage = $0.kind { true } else { false } })
                #expect(project.events.contains { if case .displayGeometry(1, _, _) = $0.kind { true } else { false } })
            }
            #expect(Set(results.map(\.projectURL.lastPathComponent)) == ["Replay A.toma", "Replay B.toma"])

            // Both thawed: the ring prunes again, and goes on until it is discarded.
            let oldest = scratch.segmentURL(take: ReplayScratch.takeID, track: "display-1", index: 2)
            #expect(await eventually { !FileManager.default.fileExists(atPath: oldest.path) })
            await coordinator.stopAndDiscard()
            #expect(!FileManager.default.fileExists(atPath: scratch.url.path))
        }
    }

    private static func request(_ dir: URL, name: String) -> ReplaySaveRequest {
        let count = Mutex(0)
        let context = EditContext(
            app: AppInfo(name: "Toma", version: "0.5.0"), cachesRoot: dir.appending(path: "Caches", directoryHint: .isDirectory),
            defaultStyle: .toma, now: { Date(timeIntervalSince1970: 1_794_773_523) },
            makeID: { prefix in
                count.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            },
            styleDirectory: nil)
        return ReplaySaveRequest(
            seconds: 2, projectsFolder: dir.appending(path: "Projects", directoryHint: .isDirectory), name: name, context: context)
    }
}
