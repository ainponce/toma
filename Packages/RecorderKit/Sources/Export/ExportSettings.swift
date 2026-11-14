// SPDX-License-Identifier: GPL-3.0-or-later
import Render

/// What an MP4 export produces: frame size and rate. The video bitrate follows from them.
public struct ExportSettings: Sendable, Equatable {
    /// H.264 bits per pixel per frame: `averageBitRate` = width × height × fps × `bitsPerPixel`.
    public static let bitsPerPixel = 0.08

    /// Width and height of the video, in pixels.
    public var outputSize: SIMD2<Int> = [1920, 1080]
    public var framesPerSecond: Int = 60
    /// For tests: the export fails, as if the writer had, once this many frames are encoded.
    internal var failAfterFrames: Int? = nil

    /// Average H.264 bitrate, in bits per second.
    public var averageBitRate: Int {
        Int((Double(outputSize.x) * Double(outputSize.y) * Double(framesPerSecond) * Self.bitsPerPixel).rounded())
    }

    public init(outputSize: SIMD2<Int> = [1920, 1080], framesPerSecond: Int = 60) {
        self.outputSize = outputSize
        self.framesPerSecond = framesPerSecond
    }
}

public enum ExportError: Error, Equatable {
    /// The task running the export was cancelled. Nothing was left behind.
    case cancelled
    /// Writing the MP4 failed (`AVAssetWriter`'s error, or the file system's when moving it into place).
    case writerFailed(String)
    /// The take has no display track with a segment: there is no screen to export.
    case noDisplayTrack
    /// The destination is a folder, or inside a project package (`*.toma`), which an export never writes into.
    case destinationNotAllowed
}

/// What a finished export left out, for the app to tell the user.
public struct ExportSummary: Sendable, Equatable {
    /// Spans of the video where recorded microphone audio could not be used, in time order: they are
    /// silent in the MP4.
    public var missingAudio: [MissingAudio]
    /// Spans of the video where the screen could not be decoded, in time order: they show the frame before
    /// them (`FrameRenderer.missingVideo`).
    public var missingVideo: [MissingVideo]

    public init(missingAudio: [MissingAudio] = [], missingVideo: [MissingVideo] = []) {
        self.missingAudio = missingAudio
        self.missingVideo = missingVideo
    }
}

/// A span of an export where a microphone segment's audio could not be used, so the MP4 is silent there.
public struct MissingAudio: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// Crash recovery found the segment's file without samples (`SegmentEndReason.empty`).
        case empty
        /// Crash recovery could not read the segment's file (`SegmentEndReason.unreadable`).
        case unreadable
        /// The segment's file is not in the package.
        case fileMissing
        /// The file has no audio track AVFoundation can open (the error, or what is missing).
        case cannotOpen(String)
        /// Reading the file stopped partway, with this error; the span starts where it stopped.
        case readFailed(String)
    }

    /// The segment's file, relative to the package root (`SegmentRecord.file`).
    public var file: String
    /// Output seconds where the silent span starts, within the export.
    public var start: Double
    /// Output seconds where it ends, within the export; `start` for a segment without a known length.
    public var end: Double
    public var reason: Reason

    public init(file: String, start: Double, end: Double, reason: Reason) {
        self.file = file
        self.start = start
        self.end = end
        self.reason = reason
    }
}
