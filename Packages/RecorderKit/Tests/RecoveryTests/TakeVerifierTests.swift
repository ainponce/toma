// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Testing

@testable import Recovery

/// A closed take with a finished display segment and a finished mic segment of the given lengths. The
/// manifest says the display segment lasts `displayRecordedSeconds` (its file's length by default) and
/// dropped `displayDropped` frames.
private func completeTake(
    in dir: URL, status: TakeStatus = .complete, displaySeconds: Double, micSeconds: Double,
    displayRecordedSeconds: Double? = nil, displayDropped: Int = 0
) async throws -> ProjectPackage {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(id: "display-1", source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: displaySeconds)])
    try await builder.addAudioTrack(id: "mic", source: micSource, segments: [AudioSegmentSpec(start: base, seconds: micSeconds)])
    let package = try builder.write(status: status).package
    if displayRecordedSeconds != nil || displayDropped != 0 {
        try ManifestStore(package: package).update { manifest in
            manifest.takes[0].tracks[0].segments[0].endHostTime = base.adding(seconds: displayRecordedSeconds ?? displaySeconds)
            manifest.takes[0].tracks[0].segments[0].droppedFrames = displayDropped
        }
    }
    return package
}

@Test func verifyFailsOnEmptyMicSegment() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: "display-1", source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: "mic", source: micSource, segments: [])
        try builder.addEmptySegment(track: "mic", index: 1, start: base, endReason: .empty, file: .zeroBytes)
        let project = try builder.write(status: .recovered)

        let results = await TakeVerifier.verify(project, minDuration: 2, maxDropRatio: nil)

        try #require(results.map(\.trackID) == ["display-1", "mic"])
        let display = results[0], mic = results[1]
        #expect(display.ok && display.reason == nil)
        #expect(abs(display.seconds - 3) < 0.05)
        #expect(display.droppedFrames == 0)
        #expect(!mic.ok)
        #expect(mic.seconds == 0)
        let reason = try #require(mic.reason)
        #expect(reason.contains("seg-0001.mov") && reason.contains("empty"), "\(reason)")
    }
}

@Test func verifyFailsOnMissingOrUnreadableSegment() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await completeTake(in: dir, displaySeconds: 3, micSeconds: 3)
        try FileManager.default.removeItem(at: package.segmentURL(take: "take-001", track: "display-1", index: 1))
        try Data(repeating: 0xAB, count: 4096).write(to: package.segmentURL(take: "take-001", track: "mic", index: 1))

        let results = await TakeVerifier.verify(try LoadedProject.load(package.url), minDuration: 0, maxDropRatio: nil)

        try #require(results.count == 2)
        #expect(!results[0].ok && results[0].reason?.contains("seg-0001.mov is missing") == true, "\(results[0].reason ?? "")")
        #expect(!results[1].ok && results[1].reason?.contains("cannot be read") == true, "\(results[1].reason ?? "")")
    }
}

@Test func verifyAcceptsCompleteTake() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await completeTake(in: dir, displaySeconds: 3, micSeconds: 3)

        let results = await TakeVerifier.verify(try LoadedProject.load(package.url), minDuration: 2.5, maxDropRatio: 0.01)

        try #require(results.count == 2)
        for result in results {
            #expect(result.ok, "\(result.trackID): \(result.reason ?? "")")
            #expect(result.reason == nil)
            #expect(abs(result.seconds - 3) < 0.05)
            #expect(result.droppedFrames == 0)
        }
    }
}

@Test func verifyFailsTrackBelowMinimumOrEndingEarly() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await completeTake(in: dir, displaySeconds: 3, micSeconds: 1)
        let project = try LoadedProject.load(package.url)

        let results = await TakeVerifier.verify(project, minDuration: 0.5, maxDropRatio: nil)
        try #require(results.map(\.trackID) == ["display-1", "mic"])
        #expect(results[0].ok)
        #expect(!results[1].ok)
        #expect(results[1].reason?.contains("before the end of the take") == true, "\(results[1].reason ?? "")")

        let strict = await TakeVerifier.verify(project, minDuration: 5, maxDropRatio: nil)
        #expect(strict.allSatisfy { !$0.ok })
        #expect(strict[0].reason?.contains("minimum 5.00 s") == true, "\(strict[0].reason ?? "")")
    }
}

@Test func verifyAppliesMaxDropRatio() async throws {
    try await withTemporaryDirectory { dir in
        // About 90 frames in the file and 10 dropped: close to 10 % of the frames that reached the recorder.
        let package = try await completeTake(in: dir, displaySeconds: 3, micSeconds: 3, displayDropped: 10)
        let project = try LoadedProject.load(package.url)

        let unchecked = await TakeVerifier.verify(project, minDuration: 2, maxDropRatio: nil)
        #expect(unchecked.allSatisfy { $0.ok })
        #expect(unchecked[0].droppedFrames == 10)

        let loose = await TakeVerifier.verify(project, minDuration: 2, maxDropRatio: 0.2)
        #expect(loose.allSatisfy { $0.ok })

        let strict = await TakeVerifier.verify(project, minDuration: 2, maxDropRatio: 0.05)
        #expect(!strict[0].ok)
        #expect(strict[0].reason?.contains("dropped 10 of") == true, "\(strict[0].reason ?? "")")
        #expect(strict[1].ok)
    }
}

@Test func verifierCountsCameraFramesAndSystemAudioBlocks() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: cameraSource,
            segments: [VideoSegmentSpec(start: base, seconds: 3, framesPerSecond: 30)])
        try await builder.addAudioTrack(
            id: "system-audio", kind: .systemAudio, source: systemAudioSource,
            segments: [AudioSegmentSpec(start: base, seconds: 3, channels: 2)])
        let package = try builder.write().package

        let results = await TakeVerifier.verify(try LoadedProject.load(package.url), minDuration: 2.5, maxDropRatio: 0.01)

        #expect(results.map(\.trackID) == ["camera", "system-audio"])
        #expect(results.allSatisfy { $0.ok }, "\(results.map { $0.reason ?? "" })")

        // 2 dropped in each: over 1 % of the camera's 90 frames, under 1 % of the system audio's 300 blocks of 10 ms.
        try ManifestStore(package: package).update { manifest in
            for i in manifest.takes[0].tracks.indices { manifest.takes[0].tracks[i].segments[0].droppedFrames = 2 }
        }
        let dropped = await TakeVerifier.verify(try LoadedProject.load(package.url), minDuration: 2.5, maxDropRatio: 0.01)
        try #require(dropped.count == 2)
        #expect(dropped[0].reason?.contains("dropped 2 of 92 frames") == true, "\(dropped[0].reason ?? "")")
        #expect(dropped[1].ok, "\(dropped[1].reason ?? "")")
    }
}

@Test func verifyAllowsTwoSecondsBetweenTracksOfATakeACrashLeftOpen() async throws {
    #expect(TakeVerifier.openEndTolerance == 2 * FragmentedTrackWriter.defaultFragmentInterval.seconds)
    try await withTemporaryDirectory { dir in
        for name in ["recovered", "complete"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let recovered = try await completeTake(
            in: dir.appendingPathComponent("recovered"), status: .recovered, displaySeconds: 3, micSeconds: 1.5)
        let results = await TakeVerifier.verify(try LoadedProject.load(recovered.url), minDuration: 1, maxDropRatio: nil)
        #expect(results.allSatisfy { $0.ok }, "\(results.map { $0.reason ?? "" })")

        let complete = try await completeTake(
            in: dir.appendingPathComponent("complete"), displaySeconds: 3, micSeconds: 1.5)
        let strict = await TakeVerifier.verify(try LoadedProject.load(complete.url), minDuration: 1, maxDropRatio: nil)
        #expect(strict[0].ok)
        #expect(strict[1].reason == "ends 1.50 s before the end of the take")
    }
}

@Test func verifyFailsSegmentShorterThanTheManifestSays() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await completeTake(in: dir, displaySeconds: 3, micSeconds: 3, displayRecordedSeconds: 4.5)

        let results = await TakeVerifier.verify(try LoadedProject.load(package.url), minDuration: 1, maxDropRatio: nil)

        try #require(results.count == 2)
        #expect(!results[0].ok)
        #expect(results[0].reason?.contains("seg-0001.mov holds 3.00 s, 1.50 s less than the manifest says") == true,
                "\(results[0].reason ?? "")")
        #expect(results[1].ok)

        // Within the 2 s of a take a crash left open.
        try ManifestStore(package: package).update { $0.takes[0].status = .recovered }
        let open = await TakeVerifier.verify(try LoadedProject.load(package.url), minDuration: 1, maxDropRatio: nil)
        #expect(open.allSatisfy { $0.ok })
    }
}

// MARK: - LoadedProject

@Test func loadedProjectReadsLastTakeAndItsEvents() async throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try addTake(makeTake("take-001", status: .complete, tracks: [micTrack([])]), to: package)
        try addTake(makeTake("take-002", status: .complete, tracks: [displayTrack([])]), to: package)
        let events = [
            InputEvent(t: base, kind: .segmentStarted(track: "display-1", index: 1)),
            InputEvent(t: base.adding(seconds: 0.1), kind: .cursor(x: 1, y: 2)),
        ]
        try Data(try events.map { try $0.jsonLine() + "\n" }.joined().utf8).write(to: package.eventsURL(take: "take-002"))

        let last = try LoadedProject.load(package.url)
        #expect(last.package == package)
        #expect(last.manifest == (try manifestOnDisk(package)))
        #expect(last.take.id == "take-002")
        #expect(last.events == events)

        let first = try LoadedProject.load(package.url, take: "take-001")
        #expect(first.take.id == "take-001")
        #expect(first.events.isEmpty)  // take-001 has no events.jsonl

        #expect(throws: LoadedProjectError.takeNotFound("take-009")) {
            try LoadedProject.load(package.url, take: "take-009")
        }
        // Newer and not decodable as this version's `Manifest`: still recognized as newer.
        try Data(#"{"formatVersion":6,"projects":[]}"#.utf8).write(to: package.manifestURL)
        #expect(throws: LoadedProjectError.unsupportedFormatVersion(6)) { try LoadedProject.load(package.url) }
        // No version of the format is below 1.
        try Data(#"{"formatVersion":0,"projects":[]}"#.utf8).write(to: package.manifestURL)
        #expect(throws: LoadedProjectError.unsupportedFormatVersion(0)) { try LoadedProject.load(package.url) }
    }
}

@Test func loadedProjectRefusesPackageWithoutTakes() async throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        #expect(throws: LoadedProjectError.noTakes) { try LoadedProject.load(package.url) }
    }
}
