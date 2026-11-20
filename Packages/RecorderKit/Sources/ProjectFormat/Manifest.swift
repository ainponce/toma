// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The app that created a project.
public struct AppInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// A rectangle in global points, origin at the top left of the main display.
public struct Rect: Codable, Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The contents of `manifest.json`: what was recorded and where it lives in the package.
public struct Manifest: Codable, Equatable, Sendable {
    /// The version new packages are created with. A package keeps the version it was created with until the user
    /// edits it or records what an older app cannot read: recovery never rewrites it (a version 1 package it touches
    /// stays at version 1), the first edit of a version 1 or 2 package upgrades it to version 3, with `upgradedFrom`, a
    /// version 3 package goes to version 4 only when a take records a track of a device or a key press, and a package
    /// goes to version 5 only when it gets a second take (`ManifestStore.raiseFormatVersion(to:)`). A package without
    /// them stays at 3, which the app of phase 1 opens.
    public static let currentFormatVersion = 3
    /// The newest version this version writes and reads: 5, a package with two takes or more (`needsFormatVersion5`);
    /// 4 has the tracks of an iPhone or iPad (`TrackKind.device`, `.deviceAudio`) and `keyPress` events. A manifest of
    /// a later version was written by a newer Toma.
    public static let newestFormatVersion = 5
    /// The versions this version reads. A manifest of any other version is refused before it is decoded.
    public static let supportedFormatVersions = 1...5
    /// The versions a take is recorded into: an older package gets what its version does not define only through its
    /// first edit, which upgrades it to 3.
    public static let recordableFormatVersions = 3...5

    public var formatVersion: Int
    public var app: AppInfo
    public var createdAt: Date
    public var takes: [TakeRecord]
    /// The version (1 or 2) a version 3 package was created at, before its first edit upgraded it. `nil` in a package
    /// created at version 3, and always in version 1 and 2 packages.
    public var upgradedFrom: Int?
    /// The project's stable id (`ProjectID`): random in a package created at version 3, the derived one in an upgraded
    /// package. `nil` in version 1 and 2 packages, whose id is the derived one (`resolvedProjectID`).
    public var projectID: String?

    public init(
        formatVersion: Int, app: AppInfo, createdAt: Date, takes: [TakeRecord], upgradedFrom: Int? = nil,
        projectID: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.app = app
        self.createdAt = createdAt
        self.takes = takes
        self.upgradedFrom = upgradedFrom
        self.projectID = projectID
    }

    /// The project's id: `projectID`, or the one derived from the manifest when it has none (version 1 and 2).
    public var resolvedProjectID: String { projectID ?? ProjectID.derived(from: self) }

    /// Whether a track of any take is of a kind only version 4 defines (`TrackKind.requiresFormatVersion4`).
    /// `keyPress` events also need it, but they are in `events.jsonl`: whoever writes the first one raises the version.
    public var needsFormatVersion4: Bool {
        takes.contains { take in take.tracks.contains { $0.kind.requiresFormatVersion4 } }
    }

    /// Whether the package has two takes or more, which only version 5 allows (design §11): the app of phase 2 would open
    /// the last one with the document of the first. Tracks of one app each (`TrackRecord.appBundleID`) do not need it:
    /// the reader of phase 2 mixes them as they are.
    public var needsFormatVersion5: Bool { takes.count > 1 }
}

/// One recording session: every track recorded between Record and Stop.
public struct TakeRecord: Codable, Equatable, Sendable {
    public var id: String
    public var status: TakeStatus
    public var startedAt: Date
    public var tracks: [TrackRecord]
    /// How the camera looks from the start of the take (notch design §6); the `cameraStyle` events of
    /// `events.jsonl` change it while recording. Only in takes with a camera, and never in a version 1
    /// package: without it, the camera is `CameraStyle.default`.
    public var cameraStyle: CameraStyle?

    public init(id: String, status: TakeStatus, startedAt: Date, tracks: [TrackRecord], cameraStyle: CameraStyle? = nil) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.tracks = tracks
        self.cameraStyle = cameraStyle
    }

    public func track(_ id: String) -> TrackRecord? {
        tracks.first { $0.id == id }
    }
}

public enum TakeStatus: String, Codable, Sendable {
    /// Still being written, or the recorder died before closing it.
    case recording
    /// Closed by the recorder.
    case complete
    /// Closed by crash recovery.
    case recovered
}

/// One source recorded into its own files, split into segments at every interruption.
public struct TrackRecord: Codable, Equatable, Sendable {
    public var id: String
    public var kind: TrackKind
    public var source: TrackSource
    public var segments: [SegmentRecord]
    /// The bundle identifier of the one app a track of system audio records, in a take that records each app in a
    /// track of its own (design §7.1); the app is also in `source.name` and `source.includedBundleIDs`, which a reader
    /// of phase 2 reads. `nil` (left out) in any other track, and in every track before phase 3.
    public var appBundleID: String?
    /// The name of that app, as the take saw it. `nil` (left out) where `appBundleID` is.
    public var appName: String?

    public init(
        id: String, kind: TrackKind, source: TrackSource, segments: [SegmentRecord], appBundleID: String? = nil,
        appName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.segments = segments
        self.appBundleID = appBundleID
        self.appName = appName
    }

    /// The id of the track of system audio of the app `bundleID`: `system-audio-` and the bundle identifier with every
    /// character (Unicode scalar) that is not an ASCII letter or digit as a `-`, so it is a track id a reader of phase 2
    /// takes (`ProjectPackage.isValidTrackID`): `com.apple.Safari` is `system-audio-com-apple-Safari`. If that is in
    /// `taken`, the first of `-2`, `-3`… after it that is not. `taken` is compared without case: the id names the
    /// track's folder, and on a volume that ignores case (APFS by default) `com.Foo.app` and `com.foo.app` would share
    /// one.
    public static func systemAudioTrackID(bundleID: String, taken: Set<String>) -> String {
        let sanitized = String(String.UnicodeScalarView(bundleID.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: scalar
            default: "-"
            }
        }))
        let id = "system-audio-" + sanitized
        let taken = Set(taken.map { $0.lowercased() })
        guard taken.contains(id.lowercased()) else { return id }
        var number = 2
        while taken.contains("\(id)-\(number)".lowercased()) { number += 1 }
        return "\(id)-\(number)"
    }
}

/// What a track records. `window`, `camera` and `systemAudio` are new in format version 2, `device` and `deviceAudio`
/// in version 4.
public enum TrackKind: String, Codable, Sendable, CaseIterable {
    /// A whole display, or an area of it (`TrackSource.captureArea`).
    case display
    /// One window.
    case window
    /// A camera.
    case camera
    case microphone
    /// The sound the Mac plays: every app but the excluded ones, or only the chosen ones.
    case systemAudio
    /// The screen of an iPhone or iPad connected by cable (version 4): the take's screen.
    case device
    /// The sound of an iPhone or iPad connected by cable (version 4), in a track of its own.
    case deviceAudio

    /// Whether a track of this kind is only in a package of version 4 or later: the app of phase 1 cannot read it.
    public var requiresFormatVersion4: Bool {
        switch self {
        case .device, .deviceAudio: true
        case .display, .window, .camera, .microphone, .systemAudio: false
        }
    }
}

/// What a track recorded. Only the fields that apply to its kind are set.
public struct TrackSource: Codable, Equatable, Sendable {
    /// The display's, window's (its app and title) or device's visible name.
    public var name: String
    /// The `CGDirectDisplayID` of a display.
    public var displayID: UInt32?
    /// The `uniqueID` of a microphone, a camera or an iPhone or iPad (`device`, `deviceAudio`).
    public var deviceUniqueID: String?
    /// Where a display or a window is, in global points.
    public var globalFrame: Rect?
    /// Pixels per point of what a display or a window recorded.
    public var pixelScale: Double?
    /// The `CGWindowID` of a window.
    public var windowID: UInt32?
    /// The bundle identifier of a window's app.
    public var bundleIdentifier: String?
    /// The area of a display recorded in Area mode, in global points. The track records the whole display.
    public var captureArea: Rect?
    /// System audio of only these apps; `nil`, every app but `excludedBundleIDs`.
    public var includedBundleIDs: [String]?
    /// Apps whose sound system audio leaves out when it records every app.
    public var excludedBundleIDs: [String]?

    public init(
        name: String,
        displayID: UInt32? = nil,
        deviceUniqueID: String? = nil,
        globalFrame: Rect? = nil,
        pixelScale: Double? = nil,
        windowID: UInt32? = nil,
        bundleIdentifier: String? = nil,
        captureArea: Rect? = nil,
        includedBundleIDs: [String]? = nil,
        excludedBundleIDs: [String]? = nil
    ) {
        self.name = name
        self.displayID = displayID
        self.deviceUniqueID = deviceUniqueID
        self.globalFrame = globalFrame
        self.pixelScale = pixelScale
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.captureArea = captureArea
        self.includedBundleIDs = includedBundleIDs
        self.excludedBundleIDs = excludedBundleIDs
    }
}

/// One media file of a track. Time 0 of the file is `startHostTime`.
public struct SegmentRecord: Codable, Equatable, Sendable {
    public var index: Int
    /// Path relative to the package root, for example `takes/take-001/display-1/seg-0001.mov`.
    public var file: String
    public var startHostTime: HostTime
    /// `nil` while the segment is open.
    public var endHostTime: HostTime?
    /// `nil` while the segment is open.
    public var endReason: SegmentEndReason?
    public var droppedFrames: Int
    /// Frames repeated to keep time moving while the screen did not change.
    public var heartbeatFrames: Int

    public init(
        index: Int,
        file: String,
        startHostTime: HostTime,
        endHostTime: HostTime? = nil,
        endReason: SegmentEndReason? = nil,
        droppedFrames: Int,
        heartbeatFrames: Int
    ) {
        self.index = index
        self.file = file
        self.startHostTime = startHostTime
        self.endHostTime = endHostTime
        self.endReason = endReason
        self.droppedFrames = droppedFrames
        self.heartbeatFrames = heartbeatFrames
    }
}

/// Why a segment was closed. Encoded flat: `{"type":"streamError","domain":"…","code":-3821}`.
public enum SegmentEndReason: Codable, Equatable, Sendable {
    case stopped
    case paused
    case streamError(domain: String, code: Int)
    case writerError(domain: String, code: Int)
    case formatChanged
    case diskFull
    case recoveredAfterCrash
    /// Recovery found no sample in the file, for example a file of 0 bytes.
    case empty
    /// Recovery could not read a non-empty file; it stays on disk untouched.
    case unreadable(bytes: Int64)
    /// The track went on in a new segment after a fixed time (fases 4 y 5 design §10.2): only in the working package of
    /// the Replay, never in a take of the library, whose manifest an older reader must still decode.
    case rotated

    private enum CodingKeys: String, CodingKey {
        case type, domain, code, bytes
    }

    private enum Kind: String, Codable {
        case stopped, paused, streamError, writerError, formatChanged, diskFull, recoveredAfterCrash, empty, unreadable
        case rotated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .stopped: self = .stopped
        case .paused: self = .paused
        case .streamError:
            self = .streamError(
                domain: try container.decode(String.self, forKey: .domain),
                code: try container.decode(Int.self, forKey: .code)
            )
        case .writerError:
            self = .writerError(
                domain: try container.decode(String.self, forKey: .domain),
                code: try container.decode(Int.self, forKey: .code)
            )
        case .formatChanged: self = .formatChanged
        case .diskFull: self = .diskFull
        case .recoveredAfterCrash: self = .recoveredAfterCrash
        case .empty: self = .empty
        case .unreadable: self = .unreadable(bytes: try container.decode(Int64.self, forKey: .bytes))
        case .rotated: self = .rotated
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stopped:
            try container.encode(Kind.stopped, forKey: .type)
        case .paused:
            try container.encode(Kind.paused, forKey: .type)
        case let .streamError(domain, code):
            try container.encode(Kind.streamError, forKey: .type)
            try container.encode(domain, forKey: .domain)
            try container.encode(code, forKey: .code)
        case let .writerError(domain, code):
            try container.encode(Kind.writerError, forKey: .type)
            try container.encode(domain, forKey: .domain)
            try container.encode(code, forKey: .code)
        case .formatChanged:
            try container.encode(Kind.formatChanged, forKey: .type)
        case .diskFull:
            try container.encode(Kind.diskFull, forKey: .type)
        case .recoveredAfterCrash:
            try container.encode(Kind.recoveredAfterCrash, forKey: .type)
        case .empty:
            try container.encode(Kind.empty, forKey: .type)
        case let .unreadable(bytes):
            try container.encode(Kind.unreadable, forKey: .type)
            try container.encode(bytes, forKey: .bytes)
        case .rotated:
            try container.encode(Kind.rotated, forKey: .type)
        }
    }
}
