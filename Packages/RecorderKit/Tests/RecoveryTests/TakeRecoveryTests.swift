// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

@testable import Recovery

/// A `recording` take whose microphone has one open segment from `base`, with `file` at its path.
private func openMicrophoneTake(in dir: URL, file: SegmentFileFixture) async throws -> ProjectPackage {
    let builder = try TakeBuilder(in: dir)
    try await builder.addAudioTrack(id: "mic", source: micSource, segments: [])
    try builder.addEmptySegment(track: "mic", index: 1, start: base, endReason: nil, file: file)
    return try builder.write(status: .recording).package
}

// MARK: - Scanner

@Test func scannerFindsOnlyUnheldRecordingTakes() async throws {
    try withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try addTake(makeTake("take-001", status: .complete, tracks: [micTrack([])]), to: package)
        try addTake(makeTake("take-002", tracks: [micTrack([])]), to: package)
        try addTake(makeTake("take-003", tracks: [micTrack([])]), to: package)
        let held = try RecordingLock.acquire(at: package.lockURL(take: "take-002"), info: .current(now: Date()))
        defer { held.release() }
        // take-003 keeps the lock file its crashed recorder left behind, which nobody holds.
        try Data("{}".utf8).write(to: package.lockURL(take: "take-003"))

        Swift.withExtendedLifetime(held) {
            #expect(RecoveryScanner.scan(directory: dir) == [.recoverable(package: package, takeID: "take-003")])
        }
    }
}

@Test func scanSkipsCorruptPackageAndFindsOthers() async throws {
    try withTemporaryDirectory { dir in
        let corrupt = try makePackage(in: dir, name: "a-corrupt")
        try Data().write(to: corrupt.manifestURL)
        let loose = dir.appendingPathComponent("b-loose.toma", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: false)
        let good = try makePackage(in: dir, name: "c-good")
        try addTake(makeTake(tracks: [micTrack([])]), to: good)
        // Not packages: ignored.
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("other"), withIntermediateDirectories: false)

        let results = RecoveryScanner.scan(directory: dir)

        try #require(results.count == 3)
        guard case let .needsRepair(first, firstReason) = results[0],
              case let .needsRepair(second, secondReason) = results[1]
        else {
            Issue.record("expected two packages that need repair first, got \(results)")
            return
        }
        #expect(first == corrupt && !firstReason.isEmpty)
        #expect(second == ProjectPackage(url: loose) && !secondReason.isEmpty)
        #expect(results[2] == .recoverable(package: good, takeID: "take-001"))
    }
}

/// A manifest of format version 2 that this version's `Manifest` cannot decode.
private let newerManifest = Data(#"{"formatVersion":2,"projects":[{"takes":[]}]}"#.utf8)

@Test func scanFlagsNewerFormatVersionWithoutRecoveringIt() async throws {
    try await withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try addTake(makeTake(tracks: [micTrack([])]), to: package)
        try newerManifest.write(to: package.manifestURL)

        let results = RecoveryScanner.scan(directory: dir)

        try #require(results.count == 1)
        guard case let .needsRepair(found, reason) = results[0] else {
            Issue.record("expected needsRepair, got \(results)")
            return
        }
        #expect(found == package)
        #expect(reason == "format version 2 is newer than 1")
        await #expect(throws: RecoveryError.unsupportedFormatVersion(2)) {
            try await TakeRecovery.recover(package: package, takeID: "take-001")
        }
        #expect(try Data(contentsOf: package.manifestURL) == newerManifest)
    }
}

// MARK: - Lock

@Test func recoverRefusesHeldLock() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await openMicrophoneTake(in: dir, file: .absent)
        let held = try RecordingLock.acquire(at: package.lockURL(take: "take-001"), info: .current(now: Date()))
        defer { held.release() }
        let before = try Data(contentsOf: package.manifestURL)

        await #expect(throws: RecoveryError.lockHeld) {
            try await TakeRecovery.recover(package: package, takeID: "take-001")
        }

        #expect(try Data(contentsOf: package.manifestURL) == before)
        Swift.withExtendedLifetime(held) {
            #expect(RecordingLock.isHeld(at: package.lockURL(take: "take-001")))
        }
    }
}

@Test func recoverRefusesWhileAnotherTakeOfThePackageIsRecording() async throws {
    try await withTemporaryDirectory { dir in
        let package = try makePackage(in: dir)
        try addTake(makeTake("take-001", tracks: [micTrack([])]), to: package)
        try addTake(makeTake("take-002", tracks: [micTrack([])]), to: package)
        // Its recorder writes manifest.json, which has a single writer.
        let held = try RecordingLock.acquire(at: package.lockURL(take: "take-002"), info: .current(now: Date()))
        defer { held.release() }
        let before = try Data(contentsOf: package.manifestURL)

        await #expect(throws: RecoveryError.anotherTakeRecording) {
            try await TakeRecovery.recover(package: package, takeID: "take-001")
        }

        #expect(try Data(contentsOf: package.manifestURL) == before)
        #expect(!FileManager.default.fileExists(atPath: package.lockURL(take: "take-001").path))
        Swift.withExtendedLifetime(held) {}
    }
}

@Test func recoveryChecksAgainForAnotherRecorderBeforeWriting() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await openMicrophoneTake(in: dir, file: .absent)
        let before = try Data(contentsOf: package.manifestURL)

        // A recorder starts take-002 meanwhile: it holds its lock before the manifest lists the take.
        var newRecorder: HeldRecordingLock?
        await #expect(throws: RecoveryError.anotherTakeRecording) {
            try await TakeRecovery.recover(package: package, takeID: "take-001") {
                try FileManager.default.createDirectory(
                    at: package.takeDirectory("take-002"), withIntermediateDirectories: false)
                newRecorder = try RecordingLock.acquire(at: package.lockURL(take: "take-002"), info: .current(now: Date()))
            }
        }
        #expect(try Data(contentsOf: package.manifestURL) == before)
        newRecorder?.release()

        // A recorder wrote the manifest and is gone already.
        await #expect(throws: RecoveryError.anotherTakeRecording) {
            try await TakeRecovery.recover(package: package, takeID: "take-001") {
                try ManifestStore(package: package).update {
                    $0.takes.append(makeTake("take-002", status: .complete, tracks: []))
                }
            }
        }
        #expect(try takeOnDisk(package, "take-001").status == .recording)
        #expect(try takeOnDisk(package, "take-002").status == .complete)
        #expect(!FileManager.default.fileExists(atPath: package.lockURL(take: "take-001").path))

        // With nothing else going on, it goes through.
        #expect(try await TakeRecovery.recover(package: package, takeID: "take-001").status == .recovered)
    }
}

@Test(.enabled(if: getuid() != 0, "root can read any file"))
func segmentFileThatCannotBeOpenedLeavesTakeRecording() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await openMicrophoneTake(in: dir, file: .garbage(bytes: 4096))
        let micURL = package.segmentURL(take: "take-001", track: "mic", index: 1)
        try #require(chmod(micURL.path, 0o000) == 0)
        defer { chmod(micURL.path, 0o644) }
        let before = try Data(contentsOf: package.manifestURL)

        await #expect(throws: POSIXError(.EACCES)) {
            try await TakeRecovery.recover(package: package, takeID: "take-001")
        }

        // Nothing is recorded about the file: once it can be read, recovery runs again.
        #expect(try Data(contentsOf: package.manifestURL) == before)
        #expect(RecoveryScanner.scan(directory: dir) == [.recoverable(package: package, takeID: "take-001")])
        try #require(chmod(micURL.path, 0o644) == 0)
        let record = try await TakeRecovery.recover(package: package, takeID: "take-001")
        #expect(record.track("mic")?.segments.first?.endReason == .unreadable(bytes: 4096))
    }
}

// MARK: - Segments

@Test func recoversOpenSegmentsFromFragments() async throws {
    try await withTemporaryDirectory { dir in
        let micStart = base.adding(seconds: 0.01)
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: "display-1", source: displaySource, segments: [
            VideoSegmentSpec(start: base, seconds: 3, endReason: nil, leaveOpen: true),
        ])
        // Written as fast as it can (not in real time), an ALAC movie gets its header only after about
        // 3 s of audio, so 3 s would leave nothing readable; in real time the first fragment comes at 1 s.
        try await builder.addAudioTrack(id: "mic", source: micSource, segments: [
            AudioSegmentSpec(start: micStart, seconds: 6, endReason: nil, leaveOpen: true),
        ])
        let package = try builder.write(status: .recording).package
        let lock = package.lockURL(take: "take-001")
        let reserve = package.reserveURL(take: "take-001")
        try Data("{}".utf8).write(to: lock)  // left behind by the crashed recorder
        try Data(count: 1 << 20).write(to: reserve)
        let displayURL = package.segmentURL(take: "take-001", track: "display-1", index: 1)
        let micURL = package.segmentURL(take: "take-001", track: "mic", index: 1)

        try await withExtendedLifetime(builder) {
            let readableBefore = [
                "display-1": await readableDuration(of: displayURL, reaching: 1.9),
                "mic": await readableDuration(of: micURL, reaching: 1.9),
            ]
            let record = try await TakeRecovery.recover(package: package, takeID: "take-001")
            let readableAfter = ["display-1": await readableDuration(of: displayURL), "mic": await readableDuration(of: micURL)]

            #expect(record.status == .recovered)
            #expect(try takeOnDisk(package, "take-001") == record)
            for (trackID, start) in [("display-1", base), ("mic", micStart)] {
                let track = try #require(record.track(trackID))
                try #require(track.segments.count == 1)
                let segment = track.segments[0]
                #expect(segment.startHostTime == start)
                #expect(segment.endReason == .recoveredAfterCrash)
                #expect(segment.droppedFrames == 0 && segment.heartbeatFrames == 0)
                let seconds = try #require(segment.endHostTime).seconds(since: start)
                #expect(seconds >= 1.9)
                let before = try #require(readableBefore[trackID]), after = try #require(readableAfter[trackID])
                #expect(seconds >= before - 0.001 && seconds <= after + 0.001, "\(trackID): \(seconds) s vs \(before)…\(after) s")
            }
            #expect(FileManager.default.fileExists(atPath: displayURL.path))
            #expect(FileManager.default.fileExists(atPath: micURL.path))
            // The reserve is scratch and goes; the lock is released and its file removed.
            #expect(!FileManager.default.fileExists(atPath: reserve.path))
            #expect(!RecordingLock.isHeld(at: lock))
            #expect(!FileManager.default.fileExists(atPath: lock.path))
        }
    }
}

@Test func recoversTakeWhoseSegmentHasNoFragments() async throws {
    try await withTemporaryDirectory { dir in
        let micStart = base.adding(seconds: 0.02)
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: "display-1", source: displaySource, segments: [
            VideoSegmentSpec(start: base, seconds: 3, endReason: nil, leaveOpen: true),
        ])
        try await builder.addAudioTrack(id: "mic", source: micSource, segments: [])
        try builder.addEmptySegment(track: "mic", index: 1, start: micStart, endReason: nil, file: .zeroBytes)
        let package = try builder.write(status: .recording).package
        let displayURL = package.segmentURL(take: "take-001", track: "display-1", index: 1)
        let micURL = package.segmentURL(take: "take-001", track: "mic", index: 1)

        try await withExtendedLifetime(builder) {
            #expect(await readableDuration(of: displayURL, reaching: 1.9) >= 1.9)
            let record = try await TakeRecovery.recover(package: package, takeID: "take-001")

            #expect(record.status == .recovered)
            let mic = try #require(record.track("mic")?.segments.first)
            #expect(mic.endReason == .empty)
            #expect(mic.endHostTime == micStart)
            #expect(mic.droppedFrames == 0 && mic.heartbeatFrames == 0)
            #expect(try fileSize(micURL) == 0)
            let display = try #require(record.track("display-1")?.segments.first)
            #expect(display.endReason == .recoveredAfterCrash)
            #expect(try #require(display.endHostTime).seconds(since: base) >= 1.9)
            #expect(try takeOnDisk(package, "take-001") == record)
        }
    }
}

@Test func nonEmptyUnreadableSegmentIsNotMarkedEmpty() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await openMicrophoneTake(in: dir, file: .garbage(bytes: 2_097_152))
        let micURL = package.segmentURL(take: "take-001", track: "mic", index: 1)
        let garbage = try Data(contentsOf: micURL)

        let record = try await TakeRecovery.recover(package: package, takeID: "take-001")

        let mic = try #require(record.track("mic")?.segments.first)
        #expect(mic.endReason == .unreadable(bytes: 2_097_152))
        #expect(mic.endHostTime == base)
        #expect(record.status == .recovered)
        #expect(try Data(contentsOf: micURL) == garbage)
    }
}

@Test func segmentWhoseFileIsGoneIsMarkedEmpty() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await openMicrophoneTake(in: dir, file: .absent)
        // Not even the track folder is left.
        try FileManager.default.removeItem(at: package.trackDirectory(take: "take-001", track: "mic"))

        let record = try await TakeRecovery.recover(package: package, takeID: "take-001")

        let mic = try #require(record.track("mic")?.segments.first)
        #expect(mic.endReason == .empty)
        #expect(mic.endHostTime == base)
        #expect(record.status == .recovered)
    }
}

@Test func recoveryAdoptsSegmentMissingFromManifest() async throws {
    try await withTemporaryDirectory { dir in
        let secondStart = base.adding(seconds: 1.5)
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: "display-1", source: displaySource, segments: [
            VideoSegmentSpec(start: base, seconds: 1, endReason: .streamError(domain: "SCStreamErrorDomain", code: -3821)),
            VideoSegmentSpec(start: secondStart, seconds: 3, endReason: nil, leaveOpen: true),
        ])
        let package = try builder.write(status: .recording).package
        // seg-0002 has its segmentStarted event, but the recorder died before the manifest listed it.
        try ManifestStore(package: package).update { $0.takes[0].tracks[0].segments.removeLast() }
        let first = try #require(try takeOnDisk(package, "take-001").track("display-1")?.segments.first)
        let secondURL = package.segmentURL(take: "take-001", track: "display-1", index: 2)
        // seg-0003 has no segmentStarted event, so nothing says when it starts: it is left alone.
        let strayURL = package.segmentURL(take: "take-001", track: "display-1", index: 3)
        let stray = Data(repeating: 0xAB, count: 4096)
        try stray.write(to: strayURL)

        try await withExtendedLifetime(builder) {
            #expect(await readableDuration(of: secondURL, reaching: 1.9) >= 1.9)
            let record = try await TakeRecovery.recover(package: package, takeID: "take-001")

            let segments = try #require(record.track("display-1")?.segments)
            try #require(segments.map(\.index) == [1, 2])
            #expect(segments[0] == first)
            let adopted = segments[1]
            #expect(adopted.startHostTime == secondStart)
            #expect(adopted.file == "takes/take-001/display-1/seg-0002.mov")
            #expect(adopted.endReason == .recoveredAfterCrash)
            #expect(adopted.droppedFrames == 0 && adopted.heartbeatFrames == 0)
            #expect(try #require(adopted.endHostTime).seconds(since: secondStart) >= 1.9)
            #expect(try Data(contentsOf: strayURL) == stray)
            #expect(try takeOnDisk(package, "take-001") == record)
        }
    }
}

// MARK: - Events and idempotence

@Test func recoveryTakesDroppedFramesFromTheLog() async throws {
    try await withTemporaryDirectory { dir in
        // display-1 died while finishing segment 1, with segment 2 already open; mic in segment 1.
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: "display-1", source: displaySource, segments: [])
        try builder.addEmptySegment(track: "display-1", index: 1, start: base, endReason: nil, file: .zeroBytes)
        try builder.addEmptySegment(track: "display-1", index: 2, start: base.adding(seconds: 2), endReason: nil, file: .zeroBytes)
        try await builder.addAudioTrack(id: "mic", source: micSource, segments: [])
        try builder.addEmptySegment(track: "mic", index: 1, start: base, endReason: nil, file: .zeroBytes)
        let package = try builder.write(status: .recording).package
        // The log as the recorder left it, in file order.
        let events = [
            InputEvent(t: base, kind: .segmentStarted(track: "display-1", index: 1)),
            InputEvent(t: base, kind: .segmentStarted(track: "mic", index: 1)),
            InputEvent(t: base.adding(seconds: 1), kind: .droppedSamples(track: "display-1", count: 3)),
            InputEvent(t: base.adding(seconds: 1), kind: .droppedSamples(track: "mic", count: 5)),
            InputEvent(t: base.adding(seconds: 1.9), kind: .droppedSamples(track: "display-1", count: 7)),
            InputEvent(t: base.adding(seconds: 2), kind: .segmentStarted(track: "display-1", index: 2)),
            InputEvent(t: base.adding(seconds: 3), kind: .droppedSamples(track: "display-1", count: 4)),
        ]
        try Data(try events.map { try $0.jsonLine() + "\n" }.joined().utf8).write(to: package.eventsURL(take: "take-001"))

        let record = try await TakeRecovery.recover(package: package, takeID: "take-001")

        #expect(record.track("display-1")?.segments.map(\.droppedFrames) == [7, 4])
        #expect(record.track("mic")?.segments.map(\.droppedFrames) == [5])
        #expect(record.tracks.flatMap(\.segments).allSatisfy { $0.heartbeatFrames == 0 })
    }
}

@Test func recoveryTruncatesBrokenEventTail() async throws {
    try await withTemporaryDirectory { dir in
        let package = try await openMicrophoneTake(in: dir, file: .zeroBytes)
        let whole = try [
            InputEvent(t: base, kind: .segmentStarted(track: "mic", index: 1)),
            InputEvent(t: base.adding(seconds: 0.5), kind: .cursor(x: 10.5, y: 20)),
        ].map { try $0.jsonLine() + "\n" }.joined()
        let eventsURL = package.eventsURL(take: "take-001")
        try Data((whole + #"{"t":5000600000000,"type":"cur"#).utf8).write(to: eventsURL)

        let record = try await TakeRecovery.recover(package: package, takeID: "take-001")

        #expect(record.status == .recovered)
        let contents = try String(contentsOf: eventsURL, encoding: .utf8)
        #expect(contents == whole)
        #expect(contents.hasSuffix("}\n"))
    }
}

@Test func recoveryIsIdempotent() async throws {
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir)
        try await builder.addVideoTrack(id: "display-1", source: displaySource, segments: [
            VideoSegmentSpec(start: base, seconds: 3, endReason: nil, leaveOpen: true),
        ])
        try await builder.addAudioTrack(id: "mic", source: micSource, segments: [])
        try builder.addEmptySegment(track: "mic", index: 1, start: base, endReason: nil, file: .zeroBytes)
        let package = try builder.write(status: .recording).package
        let displayURL = package.segmentURL(take: "take-001", track: "display-1", index: 1)

        try await withExtendedLifetime(builder) {
            #expect(await readableDuration(of: displayURL, reaching: 1.9) >= 1.9)
            let first = try await TakeRecovery.recover(package: package, takeID: "take-001")
            let manifest = try Data(contentsOf: package.manifestURL)
            let second = try await TakeRecovery.recover(package: package, takeID: "take-001")

            #expect(second == first)
            #expect(first.status == .recovered)
            #expect(try Data(contentsOf: package.manifestURL) == manifest)
            #expect(RecoveryScanner.scan(directory: dir).isEmpty)
        }
    }
}
