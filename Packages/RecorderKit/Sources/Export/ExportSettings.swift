// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Render

/// The resolutions of the export sheet (design §5.6), by the output's shorter side: 4K is 3840 × 2160 in 16:9.
public enum ExportResolution: Int, CaseIterable, Sendable {
    case p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160
}

/// How many bits the H.264 encoder may spend on a pixel of a frame (design §5.6).
public enum ExportQuality: CaseIterable, Sendable {
    /// 0.08 bits per pixel and frame, the bitrate of phase 0 and 1a.
    case standard
    /// 0.14.
    case high

    public var bitsPerPixel: Double {
        switch self {
        case .standard: 0.08
        case .high: 0.14
        }
    }
}

/// What an MP4 export produces: frame size and rate, and the quality its video bitrate follows from.
///
/// The export sheet's options are parameters of an export, never edits (design §5.6): they are not in the document.
public struct ExportSettings: Sendable, Equatable {
    /// H.264 bits per pixel per frame at `.standard` quality: `averageBitRate` = width × height × fps × the quality's
    /// `bitsPerPixel`.
    public static let bitsPerPixel = ExportQuality.standard.bitsPerPixel

    /// Width and height of the video, in pixels.
    public var outputSize: SIMD2<Int> = [1920, 1080]
    public var framesPerSecond: Int = 60
    public var quality: ExportQuality = .standard
    /// For tests: the export fails, as if the writer had, once this many frames are encoded.
    internal var failAfterFrames: Int? = nil
    /// How many frames are drawn at once, on the GPU or waiting for their decoded frames, while the writer takes the
    /// ones before them. 1 draws each frame and waits for it before the next (`FrameRenderer.render(at:into:)`), as
    /// before milestone 1b: for tests, which compare the two.
    internal var framesInFlight = 3

    /// Average H.264 bitrate, in bits per second.
    public var averageBitRate: Int {
        Int((Double(outputSize.x) * Double(outputSize.y) * Double(framesPerSecond) * quality.bitsPerPixel).rounded())
    }

    public init(outputSize: SIMD2<Int> = [1920, 1080], framesPerSecond: Int = 60, quality: ExportQuality = .standard) {
        self.outputSize = outputSize
        self.framesPerSecond = framesPerSecond
        self.quality = quality
    }

    /// The video of the export sheet: `aspect` at `resolution` (`StageLayout.outputSize`: both sides even); `auto` from
    /// `contentRatio`, the ratio of the recording's screen (16:9 without it).
    public init(
        aspect: Aspect, resolution: ExportResolution, framesPerSecond: Int, quality: ExportQuality,
        contentRatio: Double? = nil
    ) {
        self.init(
            outputSize: StageLayout.outputSize(aspect: aspect, shortSide: resolution.rawValue, contentRatio: contentRatio),
            framesPerSecond: framesPerSecond, quality: quality)
    }

    /// About how many bytes an export of `durationSeconds` takes: the video's and the audio's bitrates over that time
    /// (the export sheet's estimate, design §5.6).
    public func estimatedBytes(durationSeconds: Double) -> Int64 {
        Int64((Double(averageBitRate + MP4Exporter.audioBitRate) * durationSeconds / 8).rounded())
    }

    /// Whether `resolution` is more than what was recorded: its shorter side longer than the recorded screen's
    /// (`recordedShortSide`, in pixels). The sheet says "More than the recording" beside it.
    public static func exceedsRecording(_ resolution: ExportResolution, recordedShortSide: Int) -> Bool {
        resolution.rawValue > recordedShortSide
    }
}

public enum ExportError: Error, Equatable {
    /// The task running the export was cancelled. Nothing was left behind.
    case cancelled
    /// Writing the MP4 failed (`AVAssetWriter`'s error, or the file system's when moving it into place).
    case writerFailed(String)
    /// The destination's disk is full (`AVError.diskFull`, `ENOSPC` or `EDQUOT`, while writing, syncing or moving the
    /// MP4 into place): its partial file was removed, so the room it took is back (final review C-M3).
    case diskFull
    /// The legacy document (`EditDocument.legacy(for:)`) of a take whose screen (`ScreenChoice`: a display or a window)
    /// recorded no segment, or that has none: as in phase 0 and 1a, there is no screen to export. An edited document of
    /// such a take exports its background, its camera and its audio.
    case noDisplayTrack
    /// The destination is a folder, or inside a project package (`*.toma`), which an export never writes into.
    case destinationNotAllowed
    /// The document's clips last no time, as those of a take that recorded nothing (no segment of a screen, an audio
    /// track or the camera) do, or the range asked for (`MP4Exporter.range`) lasts less than a frame of the video:
    /// there is nothing to export, and nothing is written.
    case nothingToExport
}

/// What a finished export left out, for the app to tell the user.
public struct ExportSummary: Sendable, Equatable {
    /// Spans of the video where recorded audio, of the microphone or of system audio, could not be used, in time
    /// order, each with its track: that track is silent there in the MP4.
    public var missingAudio: [MissingAudio]
    /// Spans of the video where the screen or the camera could not be decoded, in time order, each with its track:
    /// they show the frame before them (`FrameRenderer.missingVideo`).
    public var missingVideo: [MissingVideo]

    public init(missingAudio: [MissingAudio] = [], missingVideo: [MissingVideo] = []) {
        self.missingAudio = missingAudio
        self.missingVideo = missingVideo
    }
}

/// A span of an export where the audio of a segment of a microphone or system audio track could not be used, so that
/// track is silent there in the MP4.
public struct MissingAudio: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The segment holds no samples: crash recovery marked it `SegmentEndReason.empty`, or its file has 0
        /// bytes.
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

    /// The track the segment belongs to (`TrackRecord.id`): a microphone or system audio.
    public var track: String
    /// The segment's file, relative to the package root (`SegmentRecord.file`).
    public var file: String
    /// Output seconds where the silent span starts, within the export.
    public var start: Double
    /// Output seconds where it ends, within the export: up to the segment's end, else the next segment's
    /// start, else the export's end.
    public var end: Double
    public var reason: Reason

    public init(track: String, file: String, start: Double, end: Double, reason: Reason) {
        self.track = track
        self.file = file
        self.start = start
        self.end = end
        self.reason = reason
    }
}
