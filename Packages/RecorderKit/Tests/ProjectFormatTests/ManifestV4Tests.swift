// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
import ProjectFormat

private let testApp = AppInfo(name: "Toma", version: "0.4.0")
private let testDate = Date(timeIntervalSince1970: 1_800_000_000)
private let start = HostTime(nanoseconds: 5_000_000_000_000)

private let phoneSource = TrackSource(name: "iPhone", deviceUniqueID: "00008110-000A1234")

/// A track of `kind` without segments.
private func track(_ kind: TrackKind) -> TrackRecord {
    switch kind {
    case .device: TrackRecord(id: "device", kind: kind, source: phoneSource, segments: [])
    case .deviceAudio: TrackRecord(id: "device-audio", kind: kind, source: phoneSource, segments: [])
    default: TrackRecord(id: "\(kind.rawValue)-1", kind: kind, source: TrackSource(name: "\(kind)"), segments: [])
    }
}

private func recordingTake(_ tracks: [TrackRecord]) -> TakeRecord {
    TakeRecord(id: "take-001", status: .recording, startedAt: testDate, tracks: tracks)
}

@Test func deviceKindsRoundTripAndClassify() throws {
    #expect(TrackKind.device.rawValue == "device" && TrackKind.deviceAudio.rawValue == "deviceAudio")
    // At the end: nothing the app of phase 1 knows moves.
    #expect(TrackKind.allCases == [.display, .window, .camera, .microphone, .systemAudio, .device, .deviceAudio])
    for kind in [TrackKind.device, .deviceAudio] {
        let data = try JSONEncoder().encode(kind)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(kind.rawValue)\"")
        #expect(try JSONDecoder().decode(TrackKind.self, from: data) == kind)
    }
    // The iPhone's screen is the take's screen, its audio an audio track.
    #expect(TrackKind.device.isVideo && TrackKind.device.isScreen)
    #expect(!TrackKind.deviceAudio.isVideo && !TrackKind.deviceAudio.isScreen)
    #expect(TrackKind.allCases.filter(\.isVideo) == [.display, .window, .camera, .device])
    #expect(TrackKind.allCases.filter(\.isScreen) == [.display, .window, .device])
    #expect(TrackKind.allCases.filter(\.requiresFormatVersion4) == [.device, .deviceAudio])

    let manifest = Manifest(
        formatVersion: 4, app: testApp, createdAt: testDate,
        takes: [recordingTake([track(.device), track(.deviceAudio), track(.microphone)])], projectID: ProjectID.random())
    let data = try ProjectJSON.encoder().encode(manifest)
    #expect(try ProjectJSON.decoder().decode(Manifest.self, from: data) == manifest)
    #expect(String(decoding: data, as: UTF8.self).contains(#""kind" : "deviceAudio""#))
    #expect(manifest.needsFormatVersion4)
    for kind in [TrackKind.device, .deviceAudio] {
        var one = manifest
        one.takes[0].tracks = [track(.microphone), track(kind)]
        #expect(one.needsFormatVersion4, "\(kind)")
    }
    var none = manifest
    none.takes[0].tracks = [TrackKind.display, .window, .camera, .microphone, .systemAudio].map(track)
    #expect(!none.needsFormatVersion4)
    // Any take counts, not only the last.
    none.takes.insert(TakeRecord(id: "take-000", status: .complete, startedAt: testDate, tracks: [track(.device)]), at: 0)
    #expect(none.needsFormatVersion4)
}

@Test func aTakeWithoutDevicesOrKeysStaysAt3() async throws {
    try await withTemporaryDirectory { dir in
        // A take of phase 2 with what phase 1 also records: screen, microphone, camera and key activity.
        let builder = try TakeBuilder(in: dir, name: "Phase 1 kinds")
        try await builder.addVideoTrack(
            id: "display-1",
            source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 640, height: 360), pixelScale: 1),
            segments: [VideoSegmentSpec(start: start, seconds: 0.5, framesPerSecond: 10)])
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: TrackSource(name: "Camera", deviceUniqueID: "camera"),
            segments: [VideoSegmentSpec(start: start, seconds: 0.5, framesPerSecond: 10, width: 320, height: 180)])
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Microphone", deviceUniqueID: "mic"),
            segments: [AudioSegmentSpec(start: start, seconds: 0.5)])
        try builder.addEvents([
            InputEvent(t: start, kind: .keyActivity), InputEvent(t: start.adding(seconds: 0.25), kind: .keyActivity),
        ])
        let project = try builder.write()

        #expect(project.manifest.formatVersion == 3)
        #expect(!project.manifest.needsFormatVersion4)
        #expect(project.events.contains { $0.kind == .keyActivity })
        #expect(!project.events.contains { $0.kind.requiresFormatVersion4 })
        // What the app of phase 1 reads: a manifest of version 3 (its readers take 1...3) with only kinds it knows.
        let data = try Data(contentsOf: builder.package.manifestURL)
        #expect(try Manifest.formatVersion(of: data) == 3)
        let kinds = try ProjectJSON.decoder().decode(Manifest.self, from: data).takes.flatMap(\.tracks).map(\.kind)
        #expect(kinds.sorted { $0.rawValue < $1.rawValue } == [.camera, .display, .microphone])
    }
}

@Test func deviceTrackNeedsVersion4() throws {
    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "iPhone", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        try store.update { $0.takes.append(recordingTake([track(.microphone)])) }
        let before = try Data(contentsOf: package.manifestURL)
        let memory = store.manifest
        #expect(memory.formatVersion == 3)

        for kind in [TrackKind.device, .deviceAudio] {
            #expect(throws: ManifestStoreError.needsFormatVersion(4), "\(kind)") {
                try store.update { $0.takes[0].tracks.append(track(kind)) }
            }
            #expect(try Data(contentsOf: package.manifestURL) == before)
            #expect(store.manifest == memory)
        }
        // A body that sets the version itself does not get past it: `update` keeps the version.
        #expect(throws: ManifestStoreError.needsFormatVersion(4)) {
            try store.update { manifest in
                manifest.formatVersion = 4
                manifest.takes[0].tracks.append(track(.device))
            }
        }
        #expect(try Data(contentsOf: package.manifestURL) == before)
        // Nor a new take.
        #expect(throws: ManifestStoreError.needsFormatVersion(4)) {
            try store.update { $0.takes.append(TakeRecord(id: "take-002", status: .recording, startedAt: testDate, tracks: [track(.device)])) }
        }
        #expect(store.manifest == memory)

        try store.raiseFormatVersion(to: 4)
        #expect(store.manifest.formatVersion == 4)
        var raised = memory
        raised.formatVersion = 4
        // Only the version changes: the id and the takes stay.
        #expect(try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL)) == raised)

        try store.update { $0.takes[0].tracks.append(track(.device)) }
        let reread = try ManifestStore(package: package).manifest
        #expect(reread.formatVersion == 4)
        #expect(reread.projectID == memory.projectID)
        #expect(reread.takes[0].tracks.map(\.kind) == [.microphone, .device])
        #expect(reread.needsFormatVersion4)
    }
}

@Test func raiseOnlyGoesUpToFour() throws {
    #expect(Manifest.newestFormatVersion == 4)
    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Raise", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        try store.raiseFormatVersion(to: 4)
        let raised = try Data(contentsOf: package.manifestURL)
        #expect(try Manifest.formatVersion(of: raised) == 4)

        // With nothing to raise nothing is written: the file stays the one put there.
        let marked = raised + Data("\n".utf8)
        try marked.write(to: package.manifestURL)
        try store.raiseFormatVersion(to: 4)
        try store.raiseFormatVersion(to: 3)
        #expect(store.manifest.formatVersion == 4)
        #expect(try Data(contentsOf: package.manifestURL) == marked)

        #expect(throws: ManifestStoreError.unsupportedVersion(5)) { try store.raiseFormatVersion(to: 5) }
        #expect(store.manifest.formatVersion == 4)
        #expect(try Data(contentsOf: package.manifestURL) == marked)
        #expect(try ManifestStore(package: package).manifest.formatVersion == 4)
    }
}

@Test func raiseNeverSkipsTheFirstEditsUpgrade() throws {
    // A version 1 or 2 package goes to 3 only with its first edit, which writes its document: never raised past it.
    for version in [1, 2] {
        try withTemporaryDirectory { dir in
            let package = try ProjectPackage.create(in: dir, name: "Old", app: testApp, now: testDate)
            var old = try ManifestStore(package: package).manifest
            old.formatVersion = version
            old.projectID = nil
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(old), to: package.manifestURL)
            let before = try Data(contentsOf: package.manifestURL)

            let store = try ManifestStore(package: package)
            for target in [3, 4] {
                #expect(throws: ManifestStoreError.notRecordable(version), "\(version) to \(target)") {
                    try store.raiseFormatVersion(to: target)
                }
            }
            #expect(throws: ManifestStoreError.unsupportedVersion(5)) { try store.raiseFormatVersion(to: 5) }
            try store.raiseFormatVersion(to: version)
            #expect(store.manifest.formatVersion == version)
            #expect(try Data(contentsOf: package.manifestURL) == before)
        }
    }
}

@Test func aFailedRaiseKeepsVersion3() throws {
    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Read-only", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        try store.update { $0.takes.append(recordingTake([track(.microphone)])) }
        let before = try Data(contentsOf: package.manifestURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.url.path)
        do {
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.url.path) }
            #expect(throws: (any Error).self) { try store.raiseFormatVersion(to: 4) }
            // Not raised, in memory either: what needs 4 is still refused, so nothing of it waits to be written at 3.
            #expect(store.manifest.formatVersion == 3)
            #expect(throws: ManifestStoreError.needsFormatVersion(4)) {
                try store.update { $0.takes[0].tracks.append(track(.device)) }
            }
            #expect(try Data(contentsOf: package.manifestURL) == before)
        }

        try store.flushPending()
        #expect(try Data(contentsOf: package.manifestURL) == before)
        try store.raiseFormatVersion(to: 4)
        #expect(try ManifestStore(package: package).manifest.formatVersion == 4)
    }
}

@Test func aRaiseThatFailsAfterTheRenameIsRewrittenFromMemory() throws {
    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Late", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        try store.update { $0.takes.append(recordingTake([track(.microphone)])) }

        // Without read permission the folder cannot be opened to sync it, after the rename has already worked.
        try FileManager.default.setAttributes([.posixPermissions: 0o311], ofItemAtPath: package.url.path)
        do {
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.url.path) }
            #expect(throws: (any Error).self) { try store.raiseFormatVersion(to: 4) }
            #expect(store.manifest.formatVersion == 3)
        }
        #expect(try ManifestStore(package: package).manifest.formatVersion == 4, "the rename went through")

        try store.flushPending()
        #expect(try ManifestStore(package: package).manifest.formatVersion == 3, "the disk follows the memory again")
    }
}

@Test func readersAcceptFourAndCallFiveNewer() async throws {
    #expect(Manifest.currentFormatVersion == 3)
    #expect(Manifest.newestFormatVersion == 4)
    #expect(Manifest.supportedFormatVersions == 1...4)
    #expect(Manifest.recordableFormatVersions == 3...4)
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir, name: "iPhone", formatVersion: 4)
        try await builder.addVideoTrack(
            id: "device", kind: .device, source: phoneSource,
            segments: [VideoSegmentSpec(start: start, seconds: 0.5, framesPerSecond: 10, width: 360, height: 640)])
        try await builder.addAudioTrack(
            id: "device-audio", kind: .deviceAudio, source: phoneSource, segments: [AudioSegmentSpec(start: start, seconds: 0.5)])
        let key = InputEvent(t: start.adding(seconds: 0.1), kind: .keyPress(code: 0, chars: "a", mods: 0, isRepeat: false))
        try builder.addEvents([key])
        let written = try builder.write()
        #expect(written.manifest.formatVersion == 4)
        #expect(written.manifest.projectID.map(ProjectID.isValid) == true)

        let loaded = try LoadedProject.load(builder.package.url)
        #expect(loaded.manifest.formatVersion == 4)
        #expect(loaded.take.tracks.map(\.kind) == [.device, .deviceAudio])
        #expect(loaded.events.contains(key))

        // A manifest of version 5, which this version's `Manifest` may not decode: refused before decoding it.
        try Data(#"{"formatVersion":5,"somethingNew":true}"#.utf8).write(to: builder.package.manifestURL)
        #expect(throws: LoadedProjectError.unsupportedFormatVersion(5)) { try LoadedProject.load(builder.package.url) }
    }
}

@Test func theBuilderRefusesWhatVersion3Cannot() async throws {
    try await withTemporaryDirectory { dir in
        // A device track in a package of version 3: the manifest refuses it.
        let device = try TakeBuilder(in: dir, name: "Device at 3")
        try await device.addVideoTrack(
            id: "device", kind: .device, source: phoneSource,
            segments: [VideoSegmentSpec(start: start, seconds: 0.2, framesPerSecond: 10, width: 360, height: 640)])
        #expect(throws: ManifestStoreError.needsFormatVersion(4)) { try device.write() }

        // A key press in a package of version 3: refused before anything is written.
        let keys = try TakeBuilder(in: dir, name: "Keys at 3")
        try keys.addEvents([InputEvent(t: start, kind: .keyPress(code: 0, chars: "a", mods: 0, isRepeat: false))])
        #expect(throws: TestSupportError.self) { try keys.write() }
        #expect(try ManifestStore(package: keys.package).manifest.takes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: keys.package.eventsURL(take: "take-001").path))
    }
}
