// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
@testable import ProjectFormat

// Phase 3 (base plan, Task B3; design §11): a package goes to version 5 only when it gets a second take; the tracks of
// one app each stay at the take's version, with two optional fields the reader of phase 2 ignores.

private let testApp = AppInfo(name: "Toma", version: "0.5.0")
private let testDate = Date(timeIntervalSince1970: 1_800_000_000)
private let start = HostTime(nanoseconds: 5_000_000_000_000)

private func take(_ id: String, status: TakeStatus = .complete) -> TakeRecord {
    TakeRecord(
        id: id, status: status, startedAt: testDate,
        tracks: [TrackRecord(id: "mic", kind: .microphone, source: TrackSource(name: "Microphone"), segments: [])])
}

/// A track of what one app plays: its sanitized id, the app in `TrackSource.name` and `includedBundleIDs` (what a reader
/// of phase 2 reads) and in the new fields.
private func appTrack(_ bundleID: String, _ name: String, taken: Set<String> = []) -> TrackRecord {
    TrackRecord(
        id: TrackRecord.systemAudioTrackID(bundleID: bundleID, taken: taken), kind: .systemAudio,
        source: TrackSource(name: name, includedBundleIDs: [bundleID]), segments: [], appBundleID: bundleID, appName: name)
}

// MARK: - The reader of phase 2

/// The fields of a track as `main` a78fbe1 (phase 2) decodes them: a copy, so this test says what that reader does with
/// a manifest of phase 3 whatever `TrackRecord` becomes.
private struct Phase2TrackRecord: Decodable {
    var id: String
    var kind: TrackKind
    var source: Phase2TrackSource
    var segments: [SegmentRecord]
}

private struct Phase2TrackSource: Decodable {
    var name: String
    var displayID: UInt32?
    var deviceUniqueID: String?
    var globalFrame: Rect?
    var pixelScale: Double?
    var windowID: UInt32?
    var bundleIdentifier: String?
    var captureArea: Rect?
    var includedBundleIDs: [String]?
    var excludedBundleIDs: [String]?
}

private struct Phase2Take: Decodable {
    var id: String
    var tracks: [Phase2TrackRecord]
}

private struct Phase2Manifest: Decodable {
    var formatVersion: Int
    var takes: [Phase2Take]
}

@Test func appTrackDecodesInThePhase2Reader() throws {
    let tracks = [
        TrackRecord(id: "mic", kind: .microphone, source: TrackSource(name: "Microphone"), segments: []),
        appTrack("com.apple.Safari", "Safari"),
        appTrack("com.spotify.client", "Spotify"),
    ]
    let manifest = Manifest(
        formatVersion: 3, app: testApp, createdAt: testDate,
        takes: [TakeRecord(id: "take-001", status: .complete, startedAt: testDate, tracks: tracks)], projectID: ProjectID.random())
    let data = try ProjectJSON.encoder().encode(manifest)
    #expect(try ProjectJSON.decoder().decode(Manifest.self, from: data) == manifest)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains(#""appBundleID" : "com.apple.Safari""#) && text.contains(#""appName" : "Spotify""#))

    // Phase 2 decodes it, the new fields left out, and every id is one it takes (`validatePaths`).
    let old = try ProjectJSON.decoder().decode(Phase2Manifest.self, from: data)
    #expect(old.formatVersion == 3)
    #expect(old.takes[0].tracks.map(\.id) == ["mic", "system-audio-com-apple-Safari", "system-audio-com-spotify-client"])
    #expect(old.takes[0].tracks.map(\.kind) == [.microphone, .systemAudio, .systemAudio])
    #expect(old.takes[0].tracks[1].source.name == "Safari")
    #expect(old.takes[0].tracks[2].source.includedBundleIDs == ["com.spotify.client"])
    #expect(old.takes[0].tracks.allSatisfy { ProjectPackage.isValidTrackID($0.id) })
    #expect(throws: Never.self) { try manifest.validatePaths() }

    // Without them, a track is encoded as it is today, byte for byte: neither key is written.
    let plain = TrackRecord(
        id: "system-audio", kind: .systemAudio, source: TrackSource(name: "System Audio", excludedBundleIDs: ["dev.toma.Toma"]),
        segments: [SegmentRecord(index: 1, file: "takes/take-001/system-audio/seg-0001.mov", startHostTime: start, droppedFrames: 0, heartbeatFrames: 0)])
    let encoded = String(decoding: try ProjectJSON.encoder().encode(plain), as: UTF8.self)
    #expect(encoded == """
        {
          "id" : "system-audio",
          "kind" : "systemAudio",
          "segments" : [
            {
              "droppedFrames" : 0,
              "file" : "takes/take-001/system-audio/seg-0001.mov",
              "heartbeatFrames" : 0,
              "index" : 1,
              "startHostTime" : 5000000000000
            }
          ],
          "source" : {
            "excludedBundleIDs" : [
              "dev.toma.Toma"
            ],
            "name" : "System Audio"
          }
        }
        """)
    #expect(try ProjectJSON.decoder().decode(TrackRecord.self, from: Data(encoded.utf8)) == plain)
}

@Test func systemAudioTrackIDIsAValidTrackID() {
    #expect(TrackRecord.systemAudioTrackID(bundleID: "com.apple.Safari", taken: []) == "system-audio-com-apple-Safari")
    #expect(TrackRecord.systemAudioTrackID(bundleID: "com.spotify.client", taken: ["mic"]) == "system-audio-com-spotify-client")
    // Taken: the next free number.
    #expect(TrackRecord.systemAudioTrackID(bundleID: "com.apple.Safari", taken: ["system-audio-com-apple-Safari"])
        == "system-audio-com-apple-Safari-2")
    #expect(TrackRecord.systemAudioTrackID(
        bundleID: "com.apple.Safari", taken: ["system-audio-com-apple-Safari", "system-audio-com-apple-Safari-2"])
        == "system-audio-com-apple-Safari-3")
    // Two bundles that sanitize alike get two ids.
    let first = TrackRecord.systemAudioTrackID(bundleID: "com.example.app", taken: [])
    let second = TrackRecord.systemAudioTrackID(bundleID: "com-example-app", taken: [first])
    #expect(first == "system-audio-com-example-app" && second == "system-audio-com-example-app-2")
    // Anything that is not an ASCII letter or digit is a `-`: a `ñ`, a `_`, a space, a `/`, a `.`.
    #expect(TrackRecord.systemAudioTrackID(bundleID: "ñ", taken: []) == "system-audio--")
    #expect(TrackRecord.systemAudioTrackID(bundleID: "dev.toma_Año 2/x", taken: []) == "system-audio-dev-toma-A-o-2-x")
    #expect(TrackRecord.systemAudioTrackID(bundleID: "", taken: []) == "system-audio-")
    // Without case: the id names a folder, and APFS ignores case by default.
    #expect(TrackRecord.systemAudioTrackID(bundleID: "com.foo.app", taken: ["system-audio-com-Foo-app"]) == "system-audio-com-foo-app-2")
    #expect(TrackRecord.systemAudioTrackID(bundleID: "com.Foo.app", taken: ["SYSTEM-AUDIO-COM-FOO-APP", "system-audio-com-foo-APP-2"])
        == "system-audio-com-Foo-app-3")
    var folders: Set<String> = []
    for bundle in ["com.foo.app", "com.Foo.app", "COM.FOO.APP", "com.foo.App"] {
        let id = TrackRecord.systemAudioTrackID(bundleID: bundle, taken: folders)
        #expect(!folders.contains { $0.lowercased() == id.lowercased() }, "\(bundle) → \(id)")
        folders.insert(id)
    }
    #expect(Set(folders.map { $0.lowercased() }).count == 4)
    for bundle in ["com.apple.Safari", "ñ", "../../escape", "a b\tc", "😀.app", "", "UPPER.lower.123"] {
        let id = TrackRecord.systemAudioTrackID(bundleID: bundle, taken: ["system-audio-x"])
        #expect(ProjectPackage.isValidTrackID(id), "\(bundle) → \(id)")
        #expect(id.hasPrefix("system-audio-"))
    }
}

@Test func manifestOfTwoTakesNeedsVersion5() {
    var manifest = Manifest(formatVersion: 3, app: testApp, createdAt: testDate, takes: [], projectID: ProjectID.random())
    #expect(!manifest.needsFormatVersion5)
    manifest.takes = [take("take-001")]
    #expect(!manifest.needsFormatVersion5)
    // Tracks of one app each change nothing.
    manifest.takes[0].tracks += [appTrack("com.apple.Safari", "Safari"), appTrack("com.spotify.client", "Spotify")]
    #expect(!manifest.needsFormatVersion5 && !manifest.needsFormatVersion4)
    manifest.takes.append(take("take-002"))
    #expect(manifest.needsFormatVersion5)
    #expect(!manifest.needsFormatVersion4)
}

@Test func updateRefusesASecondTakeBelow5() throws {
    for version in [3, 4] {
        try withTemporaryDirectory { dir in
            let package = try ProjectPackage.create(in: dir, name: "One take", app: testApp, now: testDate)
            if version == 4 { try ManifestStore(package: package).raiseFormatVersion(to: 4) }
            let store = try ManifestStore(package: package)
            try store.update { $0.takes.append(take("take-001", status: .recording)) }
            let before = try Data(contentsOf: package.manifestURL)
            let memory = store.manifest

            #expect(throws: ManifestStoreError.needsFormatVersion(5), "\(version)") {
                try store.update { $0.takes.append(take("take-002", status: .recording)) }
            }
            // A body that sets the version itself does not get past it either.
            #expect(throws: ManifestStoreError.needsFormatVersion(5)) {
                try store.update { manifest in
                    manifest.formatVersion = 5
                    manifest.takes.append(take("take-002", status: .recording))
                }
            }
            #expect(try Data(contentsOf: package.manifestURL) == before)
            #expect(store.manifest == memory)
            // The take there changes as before.
            try store.update { $0.takes[0].status = .complete }
            #expect(try ManifestStore(package: package).manifest.formatVersion == version)

            let closed = store.manifest
            try store.raiseFormatVersion(to: 5)
            #expect(store.manifest.formatVersion == 5)
            // Only the version changes: the id and the take stay.
            #expect(try ManifestStore(package: package).manifest == closed.with(formatVersion: 5))
            try store.update { $0.takes.append(take("take-002", status: .recording)) }
            let reread = try ManifestStore(package: package).manifest
            #expect(reread.formatVersion == 5)
            #expect(reread.projectID == memory.projectID)
            #expect(reread.takes.map(\.id) == ["take-001", "take-002"])
            #expect(reread.takes[0] == store.manifest.takes[0])
        }
    }
}

/// Raising the version and adding the take that needs it are one write: the disk has both or neither, so a cut between
/// them never leaves a package of one take at 5, which the app of phase 2 would refuse.
@Test func raisingAndAddingATakeIsOneWrite() throws {
    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "One write", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        try store.update { $0.takes.append(take("take-001")) }
        let before = try Data(contentsOf: package.manifestURL)

        // A write that fails: the disk keeps the manifest of before, of 3 with one take, whole.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.url.path)
        do {
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.url.path) }
            #expect(throws: (any Error).self) {
                try store.update(raisingTo: 5) { $0.takes.append(take("take-002", status: .recording)) }
            }
            #expect(try Data(contentsOf: package.manifestURL) == before)
            // In memory, the take and its version together, written together next.
            #expect(store.manifest.formatVersion == 5 && store.manifest.takes.map(\.id) == ["take-001", "take-002"])
        }
        try store.flushPending()
        let written = try ManifestStore(package: package).manifest
        #expect(written.formatVersion == 5)
        #expect(written.takes.map(\.id) == ["take-001", "take-002"])

        // At the version or past it, it stays: nothing goes down.
        try store.update(raisingTo: 4) { $0.takes[1].status = .complete }
        #expect(try ManifestStore(package: package).manifest.formatVersion == 5)
        let five = try Data(contentsOf: package.manifestURL)
        // Past the newest, or a body that throws: nothing changes.
        #expect(throws: ManifestStoreError.unsupportedVersion(6)) {
            try store.update(raisingTo: 6) { $0.takes.append(take("take-003")) }
        }
        struct Abort: Error {}
        #expect(throws: Abort.self) {
            try store.update(raisingTo: 5) { manifest in
                manifest.takes.append(take("take-003"))
                throw Abort()
            }
        }
        #expect(try Data(contentsOf: package.manifestURL) == five)
        #expect(store.manifest.takes.count == 2)
    }
    // A package of 1 or 2 is not moved by a take: only its first edit moves it, to 3.
    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Old", app: testApp, now: testDate)
        var old = try ManifestStore(package: package).manifest
        old.formatVersion = 2
        old.projectID = nil
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(old), to: package.manifestURL)
        let before = try Data(contentsOf: package.manifestURL)
        let store = try ManifestStore(package: package)
        #expect(throws: ManifestStoreError.notRecordable(2)) {
            try store.update(raisingTo: 5) { $0.takes.append(take("take-001")) }
        }
        #expect(try Data(contentsOf: package.manifestURL) == before)
        #expect(store.manifest == old)
    }
}

/// A package with two takes below version 5 (no app writes one: phase 1 and 2 record one take per package; a test or a
/// hand may) still gets its takes closed: what is refused is a take added, never a change to the ones there.
@Test func aPackageWithTwoTakesBelow5StillChanges() throws {
    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Two at 3", app: testApp, now: testDate)
        var manifest = try ManifestStore(package: package).manifest
        manifest.takes = [take("take-001", status: .recording), take("take-002", status: .recording)]
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(manifest), to: package.manifestURL)

        let store = try ManifestStore(package: package)
        try store.update { $0.takes[0].status = .recovered }
        try store.update { $0.takes[1].status = .recovered }
        let reread = try ManifestStore(package: package).manifest
        #expect(reread.formatVersion == 3)
        #expect(reread.takes.map(\.status) == [.recovered, .recovered])
        #expect(throws: ManifestStoreError.needsFormatVersion(5)) { try store.update { $0.takes.append(take("take-003")) } }
    }
}

@Test func raiseGoesUpToFive() throws {
    #expect(Manifest.newestFormatVersion == 5)
    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Raise", app: testApp, now: testDate)
        let store = try ManifestStore(package: package)
        try store.raiseFormatVersion(to: 5)
        #expect(try Manifest.formatVersion(of: Data(contentsOf: package.manifestURL)) == 5)
        // Nothing goes down, and 4 is below it.
        try store.raiseFormatVersion(to: 4)
        #expect(store.manifest.formatVersion == 5)
        #expect(throws: ManifestStoreError.unsupportedVersion(6)) { try store.raiseFormatVersion(to: 6) }
        #expect(try ManifestStore(package: package).manifest.formatVersion == 5)
    }
}

@Test func readersAcceptFiveAndCallSixNewer() async throws {
    #expect(Manifest.currentFormatVersion == 3)
    #expect(Manifest.newestFormatVersion == 5)
    #expect(Manifest.supportedFormatVersions == 1...5)
    #expect(Manifest.recordableFormatVersions == 3...5)
    try await withTemporaryDirectory { dir in
        let builder = try TakeBuilder(in: dir, name: "Five", formatVersion: 5)
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Microphone", deviceUniqueID: "mic"),
            segments: [AudioSegmentSpec(start: start, seconds: 0.5)])
        let written = try builder.write()
        #expect(written.manifest.formatVersion == 5)
        let loaded = try LoadedProject.load(builder.package.url)
        #expect(loaded.manifest.formatVersion == 5)
        #expect(loaded.take.id == "take-001")

        // A manifest of version 6, which this version's `Manifest` may not decode: refused before decoding it.
        try Data(#"{"formatVersion":6,"somethingNew":true}"#.utf8).write(to: builder.package.manifestURL)
        #expect(throws: LoadedProjectError.unsupportedFormatVersion(6)) { try LoadedProject.load(builder.package.url) }
    }
}

private extension Manifest {
    func with(formatVersion: Int) -> Manifest {
        var copy = self
        copy.formatVersion = formatVersion
        return copy
    }
}
