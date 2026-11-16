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
    /// edits it: recording and recovery never rewrite it (a version 1 package they touch stays at version 1), and the
    /// first edit of a version 1 or 2 package upgrades it to version 3, with `upgradedFrom`.
    public static let currentFormatVersion = 3
    /// The versions this version reads. A manifest of any other version is refused before it is decoded.
    public static let supportedFormatVersions = 1...3

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

    public init(id: String, kind: TrackKind, source: TrackSource, segments: [SegmentRecord]) {
        self.id = id
        self.kind = kind
        self.source = source
        self.segments = segments
    }
}

/// What a track records. `window`, `camera` and `systemAudio` are new in format version 2.
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
}

/// What a track recorded. Only the fields that apply to its kind are set.
public struct TrackSource: Codable, Equatable, Sendable {
    /// The display's, window's (its app and title) or device's visible name.
    public var name: String
    /// The `CGDirectDisplayID` of a display.
    public var displayID: UInt32?
    /// The `uniqueID` of a microphone or a camera.
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

    private enum CodingKeys: String, CodingKey {
        case type, domain, code, bytes
    }

    private enum Kind: String, Codable {
        case stopped, paused, streamError, writerError, formatChanged, diskFull, recoveredAfterCrash, empty, unreadable
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
        }
    }
}
