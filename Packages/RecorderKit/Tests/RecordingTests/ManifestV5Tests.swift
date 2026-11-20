// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import SyntheticCapture
import Testing

@testable import Recording

// Phase 3 (base plan, Task B3, decision 12; design §11): a take added to a package that has one raises it to version 5
// first, and never touches the takes before it; tracks of one app each keep the take's version.

/// Records a take of a display and a microphone (or `sources`) into `package` for `seconds`, and gives its id.
private func record(
    into package: ProjectPackage, in directory: URL, sources: [any CaptureSource]? = nil, seconds: Double = 0.6
) async throws -> String {
    let disk = FakeDisk()
    let coordinator = RecordingCoordinator(
        package: package,
        sources: sources ?? [SyntheticAudioSource(), SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30)],
        input: NoInputRecorder(), diskMonitor: disk.monitor(volume: directory),
        systemActivity: AsyncStream { $0.finish() })
    let id = try await coordinator.start()
    try await Task.sleep(for: .seconds(seconds))
    let record = try await coordinator.stop()
    #expect(record.status == .complete)
    return id
}

private func manifest(of package: ProjectPackage) throws -> Manifest {
    try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
}

extension RealTimeRecordingTests {
    @Suite struct ManifestV5RecordingTests {
        @Test func secondTakeRaisesTheManifestTo5() async throws {
            try await withTemporaryDirectory { directory in
                let package = try ProjectPackage.create(in: directory, name: "Takes", app: AppInfo(name: "Tests", version: "0"), now: Date())
                #expect(try await record(into: package, in: directory) == "take-001")
                let one = try manifest(of: package)
                // One take: a package of 3 stays at 3, which the app of phase 2 opens.
                #expect(one.formatVersion == 3)
                #expect(!one.needsFormatVersion5)

                #expect(try await record(into: package, in: directory) == "take-002")
                let two = try manifest(of: package)
                #expect(two.formatVersion == 5)
                #expect(two.projectID == one.projectID)
                #expect(two.takes.map(\.id) == ["take-001", "take-002"])
                #expect(two.takes.map(\.status) == [.complete, .complete])
                #expect(two.takes[0] == one.takes[0])

                // A third keeps it at 5.
                #expect(try await record(into: package, in: directory) == "take-003")
                #expect(try manifest(of: package).formatVersion == 5)
                #expect(try LoadedProject.load(package.url).manifest.formatVersion == 5)
            }
            // A package of 4 (an iPhone's take) goes to 5 with its second take too.
            try await withTemporaryDirectory { directory in
                let package = try ProjectPackage.create(in: directory, name: "Four", app: AppInfo(name: "Tests", version: "0"), now: Date())
                _ = try await record(into: package, in: directory)
                try ManifestStore(package: package).raiseFormatVersion(to: 4)
                _ = try await record(into: package, in: directory)
                #expect(try manifest(of: package).formatVersion == 5)
            }
        }

        @Test func aSecondTakeNeverTouchesTheFirst() async throws {
            try await withTemporaryDirectory { directory in
                let package = try ProjectPackage.create(in: directory, name: "Takes", app: AppInfo(name: "Tests", version: "0"), now: Date())
                _ = try await record(into: package, in: directory, sources: [
                    SyntheticAudioSource(), SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30),
                    SyntheticVideoSource(trackID: "camera", kind: .camera, width: 320, height: 180, framesPerSecond: 30),
                ])
                // The editor's files, as an edit left them.
                try Data(#"{"documentVersion":3}"#.utf8).write(to: package.editURL)
                try Data("{\"seq\":1}\n".utf8).write(to: package.editLogURL)
                let first = try #require(try manifest(of: package).takes.first)
                let recordBefore = try ProjectJSON.encoder().encode(first)
                let folderBefore = try treeHash(package.takeDirectory("take-001"))
                let edits = (try Data(contentsOf: package.editURL), try Data(contentsOf: package.editLogURL))

                _ = try await record(into: package, in: directory)

                let after = try manifest(of: package)
                #expect(after.formatVersion == 5)
                #expect(try ProjectJSON.encoder().encode(try #require(after.takes.first)) == recordBefore)
                #expect(try treeHash(package.takeDirectory("take-001")) == folderBefore)
                #expect(try Data(contentsOf: package.editURL) == edits.0)
                #expect(try Data(contentsOf: package.editLogURL) == edits.1)
                #expect(try LoadedProject.load(package.url, take: "take-001").take == first)
                #expect(try LoadedProject.load(package.url, take: "take-002").take.status == .complete)
            }
        }

        @Test func aTakeWithAppTracksStaysAtItsVersion() async throws {
            try await withTemporaryDirectory { directory in
                let package = try ProjectPackage.create(in: directory, name: "Apps", app: AppInfo(name: "Tests", version: "0"), now: Date())
                var taken: Set<String> = []
                var apps: [any CaptureSource] = []
                for bundle in ["com.apple.Safari", "com.spotify.client", "com.apple.Music"] {
                    let id = TrackRecord.systemAudioTrackID(bundleID: bundle, taken: taken)
                    taken.insert(id)
                    apps.append(SyntheticAudioSource(trackID: id, kind: .systemAudio, channels: 2))
                }
                _ = try await record(into: package, in: directory, sources: [
                    SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30), SyntheticAudioSource(),
                ] + apps)
                let written = try manifest(of: package)
                #expect(written.formatVersion == 3)
                #expect(!written.needsFormatVersion4 && !written.needsFormatVersion5)
                let tracks = try #require(written.takes.first).tracks.filter { $0.kind == .systemAudio }
                #expect(tracks.map(\.id) == ["system-audio-com-apple-Safari", "system-audio-com-spotify-client", "system-audio-com-apple-Music"])
                #expect(tracks.allSatisfy { !$0.segments.isEmpty })
                #expect(throws: Never.self) { try written.validatePaths() }
            }
        }
    }
}
