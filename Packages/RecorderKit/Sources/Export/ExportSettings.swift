// SPDX-License-Identifier: GPL-3.0-or-later

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
