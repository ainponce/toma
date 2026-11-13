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
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var app: AppInfo
    public var createdAt: Date
    public var takes: [TakeRecord]

    public init(formatVersion: Int, app: AppInfo, createdAt: Date, takes: [TakeRecord]) {
        self.formatVersion = formatVersion
        self.app = app
        self.createdAt = createdAt
        self.takes = takes
    }
}

/// One recording session: every track recorded between Record and Stop.
public struct TakeRecord: Codable, Equatable, Sendable {
    public var id: String
    public var status: TakeStatus
    public var startedAt: Date
    public var tracks: [TrackRecord]

    public init(id: String, status: TakeStatus, startedAt: Date, tracks: [TrackRecord]) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.tracks = tracks
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

public enum TrackKind: String, Codable, Sendable {
    case display, microphone
}

/// What a track recorded. Only the fields that apply to its kind are set.
public struct TrackSource: Codable, Equatable, Sendable {
    public var name: String
    public var displayID: UInt32?
    public var deviceUniqueID: String?
    public var globalFrame: Rect?
    public var pixelScale: Double?

    public init(
        name: String,
        displayID: UInt32? = nil,
        deviceUniqueID: String? = nil,
        globalFrame: Rect? = nil,
        pixelScale: Double? = nil
    ) {
        self.name = name
        self.displayID = displayID
        self.deviceUniqueID = deviceUniqueID
        self.globalFrame = globalFrame
        self.pixelScale = pixelScale
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
