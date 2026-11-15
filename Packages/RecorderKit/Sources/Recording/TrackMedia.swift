// SPDX-License-Identifier: GPL-3.0-or-later

/// What a track carries, which decides how its segments are encoded.
public enum TrackMedia: Sendable, Equatable {
    /// Screen or camera video, encoded HEVC at `framesPerSecond` (the capture rate).
    case video(framesPerSecond: Int)
    /// Microphone audio, encoded lossless.
    case audio
}

/// Recording bitrate for HEVC screen video: width × height × fps × `bitsPerPixel`.
public enum VideoBitrate {
    public static let bitsPerPixel = 0.05

    /// Average bitrate in bits per second.
    public static func averageBitRate(width: Int, height: Int, framesPerSecond: Int) -> Int {
        Int((Double(width) * Double(height) * Double(framesPerSecond) * bitsPerPixel).rounded())
    }
}
