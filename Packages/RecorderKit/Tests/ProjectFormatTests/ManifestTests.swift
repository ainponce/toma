// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import RecorderKitTestSupport
import Testing
@testable import ProjectFormat

extension Manifest {
    /// One take with a display track (a closed segment and an open one) and a microphone track.
    static let fixture = Manifest(
        formatVersion: Manifest.currentFormatVersion,
        app: AppInfo(name: "Toma", version: "0.1.0"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        takes: [
            TakeRecord(
                id: "take-001",
                status: .recording,
                startedAt: Date(timeIntervalSince1970: 1_700_000_005),
                tracks: [
                    TrackRecord(
                        id: "display-1",
                        kind: .display,
                        source: TrackSource(
                            name: "Built-in Retina Display",
                            displayID: 1,
                            globalFrame: Rect(x: 0, y: 0, width: 1512, height: 982),
                            pixelScale: 2
                        ),
                        segments: [
                            SegmentRecord(
                                index: 1,
                                file: "takes/take-001/display-1/seg-0001.mov",
                                startHostTime: HostTime(nanoseconds: 5_000_000_000),
                                endHostTime: HostTime(nanoseconds: 9_500_000_000),
                                endReason: .streamError(domain: "SCStreamErrorDomain", code: -3821),
                                droppedFrames: 2,
                                heartbeatFrames: 7
                            ),
                            SegmentRecord(
                                index: 2,
                                file: "takes/take-001/display-1/seg-0002.mov",
                                startHostTime: HostTime(nanoseconds: 9_700_000_000),
                                droppedFrames: 0,
                                heartbeatFrames: 0
                            ),
                        ]
                    ),
                    TrackRecord(
                        id: "mic",
                        kind: .microphone,
                        source: TrackSource(name: "MacBook Pro Microphone", deviceUniqueID: "BuiltInMicrophoneDevice"),
                        segments: [
                            SegmentRecord(
                                index: 1,
                                file: "takes/take-001/mic/seg-0001.mov",
                                startHostTime: HostTime(nanoseconds: 5_000_000_000),
                                droppedFrames: 0,
                                heartbeatFrames: 0
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}

@Test func manifestRoundTrips() throws {
    let manifest = Manifest.fixture
    let data = try ProjectJSON.encoder().encode(manifest)
    let decoded = try ProjectJSON.decoder().decode(Manifest.self, from: data)
    #expect(decoded == manifest)
    #expect(decoded.takes[0].tracks[0].segments[1].endHostTime == nil)
    #expect(decoded.takes[0].tracks[0].segments[0].endReason == .streamError(domain: "SCStreamErrorDomain", code: -3821))
}

@Test func endReasonUsesFlatTypeField() throws {
    let json = String(decoding: try ProjectJSON.encoder().encode(SegmentEndReason.unreadable(bytes: 10)), as: UTF8.self)
    #expect(json.contains("\"type\" : \"unreadable\"") && json.contains("\"bytes\" : 10"))
}

@Test func streamErrorEncodesDomainAndCodeNextToType() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(SegmentEndReason.streamError(domain: "SCStreamErrorDomain", code: -3821)), as: UTF8.self)
    #expect(json == #"{"code":-3821,"domain":"SCStreamErrorDomain","type":"streamError"}"#)
}

@Test(arguments: [
    SegmentEndReason.stopped, .paused, .streamError(domain: "SCStreamErrorDomain", code: -3821),
    .writerError(domain: "AVFoundationErrorDomain", code: -11800), .formatChanged, .diskFull,
    .recoveredAfterCrash, .empty, .unreadable(bytes: 2_097_152),
])
func everyEndReasonRoundTrips(reason: SegmentEndReason) throws {
    let data = try ProjectJSON.encoder().encode(reason)
    #expect(try ProjectJSON.decoder().decode(SegmentEndReason.self, from: data) == reason)
}

@Test func unknownEndReasonTypeFailsToDecode() {
    #expect(throws: DecodingError.self) {
        try ProjectJSON.decoder().decode(SegmentEndReason.self, from: Data(#"{"type":"exploded"}"#.utf8))
    }
}

@Test func datesAreISO8601AndPathsKeepTheirSlashes() throws {
    let json = String(decoding: try ProjectJSON.encoder().encode(Manifest.fixture), as: UTF8.self)
    #expect(json.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""))
    #expect(json.contains("\"file\" : \"takes/take-001/display-1/seg-0001.mov\""))
}

@Test func takeFindsTrackByID() {
    let take = Manifest.fixture.takes[0]
    #expect(take.track("mic")?.kind == .microphone)
    #expect(take.track("camera") == nil)
}

// MARK: - Version 2

/// The example `manifest.json` of `docs/format/README.md` while the format was at version 1, as it was.
private let version1Example = #"""
{
  "app" : {
    "name" : "Toma",
    "version" : "0.1.0"
  },
  "createdAt" : "2026-11-13T16:00:00Z",
  "formatVersion" : 1,
  "takes" : [
    {
      "id" : "take-001",
      "startedAt" : "2026-11-13T16:00:12Z",
      "status" : "complete",
      "tracks" : [
        {
          "id" : "display-1",
          "kind" : "display",
          "segments" : [
            {
              "droppedFrames" : 0,
              "endHostTime" : 81276901234567,
              "endReason" : {
                "code" : -3821,
                "domain" : "SCStreamErrorDomain",
                "type" : "streamError"
              },
              "file" : "takes/take-001/display-1/seg-0001.mov",
              "heartbeatFrames" : 312,
              "index" : 1,
              "startHostTime" : 81234567890123
            },
            {
              "droppedFrames" : 3,
              "endHostTime" : 81334000000000,
              "endReason" : {
                "type" : "stopped"
              },
              "file" : "takes/take-001/display-1/seg-0002.mov",
              "heartbeatFrames" : 0,
              "index" : 2,
              "startHostTime" : 81277458000000
            }
          ],
          "source" : {
            "displayID" : 1,
            "globalFrame" : {
              "height" : 982,
              "width" : 1512,
              "x" : 0,
              "y" : 0
            },
            "name" : "Built-in Retina Display",
            "pixelScale" : 2
          }
        },
        {
          "id" : "mic",
          "kind" : "microphone",
          "segments" : [
            {
              "droppedFrames" : 0,
              "endHostTime" : 81334000000000,
              "endReason" : {
                "type" : "stopped"
              },
              "file" : "takes/take-001/mic/seg-0001.mov",
              "heartbeatFrames" : 0,
              "index" : 1,
              "startHostTime" : 81234570000000
            }
          ],
          "source" : {
            "deviceUniqueID" : "BuiltInMicrophoneDevice",
            "name" : "MacBook Pro Microphone"
          }
        }
      ]
    }
  ]
}
"""#

@Test func version1ManifestStillLoads() throws {
    #expect(Manifest.supportedFormatVersions.contains(1))
    let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(version1Example.utf8))
    #expect(manifest.formatVersion == 1)
    #expect(manifest.takes.map(\.id) == ["take-001"])
    #expect(manifest.takes[0].tracks.map(\.kind) == [.display, .microphone])
    #expect(manifest.takes[0].tracks[0].source.pixelScale == 2)
    #expect(manifest.takes[0].tracks[0].source.captureArea == nil)

    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Old", app: AppInfo(name: "Toma", version: "0.1.0"), now: Date())
        try Data(version1Example.utf8).write(to: package.manifestURL)
        let project = try LoadedProject.load(package.url)
        #expect(project.manifest == manifest)
        #expect(project.manifest.formatVersion == 1)
        #expect(project.take.id == "take-001")
    }
}

/// What a version 1 package is rewritten with (recovery closing its take, say) has no key a later version added.
@Test func version1ManifestReencodesByteForByte() throws {
    let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(version1Example.utf8))
    let reencoded = try ProjectJSON.encoder().encode(manifest)
    #expect(String(decoding: reencoded, as: UTF8.self) == version1Example)
}

@Test func takeWithoutCameraStyleDecodesAsNil() throws {
    let version1 = try ProjectJSON.decoder().decode(Manifest.self, from: Data(version1Example.utf8))
    #expect(version1.takes[0].cameraStyle == nil)

    let take = #"{"id":"take-001","startedAt":"2026-11-13T16:00:12Z","status":"complete","tracks":[]}"#
    let version2 = #"{"app":{"name":"Toma","version":"0.2.0"},"createdAt":"2026-11-13T16:00:00Z","formatVersion":2,"takes":[\#(take)]}"#
    let decoded = try ProjectJSON.decoder().decode(Manifest.self, from: Data(version2.utf8))
    #expect(decoded.formatVersion == 2)
    #expect(decoded.takes[0].cameraStyle == nil)
    // Nothing is written for a take without one: a field without a value is left out.
    #expect(!String(decoding: try ProjectJSON.encoder().encode(decoded), as: UTF8.self).contains("cameraStyle"))
}

@Test func newTrackKindsRoundTrip() throws {
    let window = TrackRecord(
        id: "window-4242", kind: .window,
        source: TrackSource(
            name: "Safari — Toma", globalFrame: Rect(x: 100, y: 80, width: 800, height: 600), pixelScale: 2,
            windowID: 4242, bundleIdentifier: "com.apple.Safari"),
        segments: [])
    let camera = TrackRecord(
        id: "camera", kind: .camera, source: TrackSource(name: "FaceTime HD Camera", deviceUniqueID: "FaceTimeHD"), segments: [])
    let systemAudio = TrackRecord(
        id: "system-audio", kind: .systemAudio,
        source: TrackSource(name: "System Audio", excludedBundleIDs: ["dev.toma.Toma"]), segments: [])
    let area = TrackRecord(
        id: "display-1", kind: .display,
        source: TrackSource(
            name: "Built-in Retina Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1512, height: 982),
            pixelScale: 2, captureArea: Rect(x: 200, y: 150.5, width: 1280, height: 720)),
        segments: [])
    let chosenApps = TrackRecord(
        id: "system-audio-2", kind: .systemAudio,
        source: TrackSource(name: "System Audio", includedBundleIDs: ["com.apple.Music", "com.spotify.client"]), segments: [])
    let style = CameraStyle(shape: .portrait, size: CameraStyle.large, anchor: .top)
    let manifest = Manifest(
        formatVersion: Manifest.currentFormatVersion, app: AppInfo(name: "Toma", version: "0.2.0"),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        takes: [TakeRecord(
            id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_005),
            tracks: [area, window, camera, systemAudio, chosenApps], cameraStyle: style)])

    let data = try ProjectJSON.encoder().encode(manifest)
    #expect(try ProjectJSON.decoder().decode(Manifest.self, from: data) == manifest)
    let json = String(decoding: data, as: UTF8.self)
    for kind in ["window", "camera", "systemAudio"] {
        #expect(json.contains("\"kind\" : \"\(kind)\""), "\(kind)")
    }
    #expect(json.contains("\"windowID\" : 4242") && json.contains("\"bundleIdentifier\" : \"com.apple.Safari\""))
    #expect(json.contains("\"captureArea\" : {"))
    #expect(json.contains("\"excludedBundleIDs\" : [") && json.contains("\"includedBundleIDs\" : ["))

    // The take's style, inside the take, as the format documents it.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let take = String(decoding: try encoder.encode(TakeRecord(
        id: "take-001", status: .recording, startedAt: Date(timeIntervalSince1970: 0), tracks: [], cameraStyle: .default)),
        as: UTF8.self)
    #expect(take.contains(#""cameraStyle":{"anchor":"bottomTrailing","shape":"circle","size":0.24}"#), "\(take)")
}

@Test func trackKindsSayWhatTheyHold() {
    #expect(TrackKind.allCases == [.display, .window, .camera, .microphone, .systemAudio, .device, .deviceAudio])
    #expect(TrackKind.allCases.filter(\.isVideo) == [.display, .window, .camera, .device])
    #expect(TrackKind.allCases.filter(\.isScreen) == [.display, .window, .device])
}

// MARK: - Version 3

/// The example `manifest.json` of `docs/format/README.md` while the format was at version 2, as it was.
private let version2Example = #"""
{
  "app" : {
    "name" : "Toma",
    "version" : "0.1.0"
  },
  "createdAt" : "2026-11-13T16:00:00Z",
  "formatVersion" : 2,
  "takes" : [
    {
      "cameraStyle" : {
        "anchor" : "bottomTrailing",
        "shape" : "circle",
        "size" : 0.24
      },
      "id" : "take-001",
      "startedAt" : "2026-11-13T16:00:12Z",
      "status" : "complete",
      "tracks" : [
        {
          "id" : "display-1",
          "kind" : "display",
          "segments" : [
            {
              "droppedFrames" : 0,
              "endHostTime" : 81276901234567,
              "endReason" : {
                "code" : -3821,
                "domain" : "SCStreamErrorDomain",
                "type" : "streamError"
              },
              "file" : "takes/take-001/display-1/seg-0001.mov",
              "heartbeatFrames" : 312,
              "index" : 1,
              "startHostTime" : 81234567890123
            },
            {
              "droppedFrames" : 3,
              "endHostTime" : 81334000000000,
              "endReason" : {
                "type" : "stopped"
              },
              "file" : "takes/take-001/display-1/seg-0002.mov",
              "heartbeatFrames" : 0,
              "index" : 2,
              "startHostTime" : 81277458000000
            }
          ],
          "source" : {
            "displayID" : 1,
            "globalFrame" : {
              "height" : 982,
              "width" : 1512,
              "x" : 0,
              "y" : 0
            },
            "name" : "Built-in Retina Display",
            "pixelScale" : 2
          }
        },
        {
          "id" : "camera",
          "kind" : "camera",
          "segments" : [
            {
              "droppedFrames" : 0,
              "endHostTime" : 81334000000000,
              "endReason" : {
                "type" : "stopped"
              },
              "file" : "takes/take-001/camera/seg-0001.mov",
              "heartbeatFrames" : 0,
              "index" : 1,
              "startHostTime" : 81234590000000
            }
          ],
          "source" : {
            "deviceUniqueID" : "0x1420000005ac8600",
            "name" : "FaceTime HD Camera"
          }
        },
        {
          "id" : "mic",
          "kind" : "microphone",
          "segments" : [
            {
              "droppedFrames" : 0,
              "endHostTime" : 81334000000000,
              "endReason" : {
                "type" : "stopped"
              },
              "file" : "takes/take-001/mic/seg-0001.mov",
              "heartbeatFrames" : 0,
              "index" : 1,
              "startHostTime" : 81234570000000
            }
          ],
          "source" : {
            "deviceUniqueID" : "BuiltInMicrophoneDevice",
            "name" : "MacBook Pro Microphone"
          }
        },
        {
          "id" : "system-audio",
          "kind" : "systemAudio",
          "segments" : [
            {
              "droppedFrames" : 0,
              "endHostTime" : 81334000000000,
              "endReason" : {
                "type" : "stopped"
              },
              "file" : "takes/take-001/system-audio/seg-0001.mov",
              "heartbeatFrames" : 0,
              "index" : 1,
              "startHostTime" : 81234575000000
            }
          ],
          "source" : {
            "excludedBundleIDs" : [
              "dev.toma.Toma",
              "com.apple.notificationcenterui",
              "com.apple.UserNotificationCenter",
              "systemsoundserverd",
              "com.apple.systemsoundserverd"
            ],
            "name" : "System Audio"
          }
        }
      ]
    }
  ]
}
"""#

@Test func newPackagesAreVersion3WithARandomProjectID() throws {
    #expect(Manifest.currentFormatVersion == 3)
    #expect(Manifest.supportedFormatVersions == 1...5)
    try withTemporaryDirectory { dir in
        let app = AppInfo(name: "Toma", version: "0.1.0")
        let first = try ProjectPackage.create(in: dir, name: "New", app: app, now: Date())
        let second = try ProjectPackage.create(in: dir, name: "Other", app: app, now: Date())
        let data = try Data(contentsOf: first.manifestURL)
        #expect(try Manifest.formatVersion(of: data) == 3)
        #expect(String(decoding: data, as: UTF8.self).contains("\"formatVersion\" : 3"))

        let ids = try [first, second].map { package in
            let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
            #expect(manifest.upgradedFrom == nil)
            let id = try #require(manifest.projectID)
            #expect(ProjectID.isValid(id), "\(id)")
            #expect(manifest.resolvedProjectID == id)
            return id
        }
        #expect(ids[0] != ids[1])
    }
}

@Test func projectIDIsThirtyTwoLowercaseHexDigits() {
    #expect(ProjectID.isValid("0123456789abcdef0123456789abcdef"))
    #expect(!ProjectID.isValid("0123456789ABCDEF0123456789ABCDEF"))
    #expect(!ProjectID.isValid("0123456789abcdef0123456789abcde"))
    #expect(!ProjectID.isValid("0123456789abcdef0123456789abcdef0"))
    #expect(!ProjectID.isValid("0123456789abcdef0123456789abcdeg"))
    #expect(!ProjectID.isValid("../../../../../../../../../../.."))
    #expect(!ProjectID.isValid(""))
    #expect(ProjectID.isValid(ProjectID.random()))
    #expect(ProjectID.random() != ProjectID.random())
}

@Test func version2ManifestStillLoads() throws {
    #expect(Manifest.supportedFormatVersions.contains(2))
    let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(version2Example.utf8))
    #expect(manifest.formatVersion == 2)
    #expect(manifest.projectID == nil)
    #expect(manifest.upgradedFrom == nil)
    #expect(manifest.takes[0].tracks.map(\.kind) == [.display, .camera, .microphone, .systemAudio])
    // Rewritten (recovery closing its take, say) with no key version 3 added.
    #expect(String(decoding: try ProjectJSON.encoder().encode(manifest), as: UTF8.self) == version2Example)

    try withTemporaryDirectory { dir in
        let package = try ProjectPackage.create(in: dir, name: "Old", app: AppInfo(name: "Toma", version: "0.1.0"), now: Date())
        try Data(version2Example.utf8).write(to: package.manifestURL)
        let project = try LoadedProject.load(package.url)
        #expect(project.manifest == manifest)
        #expect(project.manifest.formatVersion == 2)
        #expect(project.manifest.projectID == nil)
        #expect(project.take.id == "take-001")
    }
}

@Test func derivedProjectIDIsStable() throws {
    let take = #"{"id":"take-001","startedAt":"2026-11-15T20:00:01Z","status":"complete","tracks":[]}"#
    let json = #"{"app":{"name":"Toma","version":"0.2.0"},"createdAt":"2026-11-15T20:00:00Z","formatVersion":2,"takes":[\#(take)]}"#
    try withTemporaryDirectory { dir in
        let app = AppInfo(name: "Toma", version: "0.2.0")
        // The same manifest in two packages of different names (a package renamed or copied in Finder).
        let ids = try ["First", "Renamed"].map { name in
            let package = try ProjectPackage.create(in: dir, name: name, app: app, now: Date())
            try Data(json.utf8).write(to: package.manifestURL)
            return ProjectID.derived(from: try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL)))
        }
        #expect(ids[0] == ids[1])
        #expect(ProjectID.isValid(ids[0]))

        let expected = SHA256.hash(data: Data("2026-11-15T20:00:00Z\ntake-001\n2026-11-15T20:00:01Z\n".utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        #expect(ids[0] == expected)

        var manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(json.utf8))
        #expect(manifest.resolvedProjectID == expected)
        manifest.takes[0].id = "take-002"
        #expect(ProjectID.derived(from: manifest) != expected)
        // Only the creation date and the takes count: not the app, the version or what a take holds.
        manifest.takes[0].id = "take-001"
        manifest.app = AppInfo(name: "Other", version: "9")
        manifest.formatVersion = 1
        manifest.takes[0].status = .recording
        #expect(ProjectID.derived(from: manifest) == expected)
    }
}

@Test func upgradedManifestRoundTrips() throws {
    var manifest = Manifest.fixture
    manifest.formatVersion = 3
    manifest.upgradedFrom = 2
    manifest.projectID = "3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e"
    let data = try ProjectJSON.encoder().encode(manifest)
    #expect(try ProjectJSON.decoder().decode(Manifest.self, from: data) == manifest)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"upgradedFrom\" : 2"))
    #expect(json.contains("\"projectID\" : \"3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e\""))
    #expect(!json.contains("null"))
    #expect(manifest.resolvedProjectID == "3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e")

    // A package created at version 3 has no `upgradedFrom`, and nothing is written for it.
    manifest.upgradedFrom = nil
    let created = String(decoding: try ProjectJSON.encoder().encode(manifest), as: UTF8.self)
    #expect(!created.contains("upgradedFrom") && !created.contains("null"))
    #expect(Manifest(formatVersion: 3, app: manifest.app, createdAt: manifest.createdAt, takes: []).upgradedFrom == nil)
}

@Test func legacyFixturesHaveNoProjectID() throws {
    try withTemporaryDirectory { dir in
        for version in [1, 2] {
            let builder = try TakeBuilder(in: dir, name: "v\(version)", formatVersion: version)
            let data = try Data(contentsOf: builder.package.manifestURL)
            let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: data)
            #expect(manifest.formatVersion == version)
            #expect(manifest.projectID == nil)
            #expect(manifest.upgradedFrom == nil)
            #expect(manifest.resolvedProjectID == ProjectID.derived(from: manifest))
            #expect(!String(decoding: data, as: UTF8.self).contains("projectID"))
        }
        let current = try TakeBuilder(in: dir, name: "v3")
        let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: current.package.manifestURL))
        #expect(manifest.formatVersion == 3)
        #expect(manifest.upgradedFrom == nil)
        #expect(manifest.projectID.map(ProjectID.isValid) == true)

        let upgraded = try TakeBuilder(in: dir, name: "upgraded", formatVersion: 3, upgradedFrom: 2)
        let reread = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: upgraded.package.manifestURL))
        #expect(reread.upgradedFrom == 2)
        #expect(reread.projectID.map(ProjectID.isValid) == true)

        // A version 1 or 2 package never has `upgradedFrom`: a fixture that asks for one is refused.
        #expect(throws: TestSupportError.self) { try TakeBuilder(in: dir, name: "contradictory", formatVersion: 2, upgradedFrom: 1) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("contradictory.toma").path))
    }
}
