// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia

/// The camera quality chosen: the size the camera records at, when one of its formats has it at the rate chosen.
public enum CameraPreset: String, Codable, Sendable, CaseIterable {
    case p720
    case p1080
    case p2160

    public var width: Int {
        switch self {
        case .p720: 1280
        case .p1080: 1920
        case .p2160: 3840
        }
    }

    public var height: Int {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p2160: 2160
        }
    }
}

/// One of a camera's formats, as `CameraFormatChoice` compares them.
public struct CameraFormatInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// The highest rate of its frame rate ranges.
    public var maxFramesPerSecond: Double
    /// Its pixels are `420v` (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`), what the camera track
    /// records, so the frames need no conversion.
    public var isVideoRange420: Bool

    public init(width: Int, height: Int, maxFramesPerSecond: Double, isVideoRange420: Bool) {
        self.width = width
        self.height = height
        self.maxFramesPerSecond = maxFramesPerSecond
        self.isVideoRange420 = isVideoRange420
    }
}

/// Which of a camera's formats records a preset at a frame rate.
public enum CameraFormatChoice {
    /// How far below the rate asked for a format may top out and still give it: cameras say 29.97 for 30.
    static let rateTolerance = 0.1

    /// The index in `formats` of the smallest format that covers `preset` (as wide and as tall) at
    /// `framesPerSecond`, a `420v` one before another of the same size; if none covers it, the largest that
    /// gives the rate; `nil` if none gives the rate. Among equals, the first.
    public static func best(among formats: [CameraFormatInfo], preset: CameraPreset, framesPerSecond: Int) -> Int? {
        let fastEnough = formats.indices.filter { formats[$0].maxFramesPerSecond + rateTolerance >= Double(framesPerSecond) }
        let covering = fastEnough.filter { formats[$0].width >= preset.width && formats[$0].height >= preset.height }
        func key(_ index: Int, largestFirst: Bool) -> (Int, Int, Int) {
            let format = formats[index]
            let pixels = format.width * format.height
            return (largestFirst ? -pixels : pixels, format.isVideoRange420 ? 0 : 1, index)
        }
        if !covering.isEmpty {
            return covering.min { key($0, largestFirst: false) < key($1, largestFirst: false) }
        }
        return fastEnough.min { key($0, largestFirst: true) < key($1, largestFirst: true) }
    }

    /// A frame rate range of a format (`AVFrameRateRange`), with the durations AVFoundation gives for its ends.
    struct RateRange {
        var minRate: Double
        var maxRate: Double
        /// The frame duration at `maxRate`.
        var minDuration: CMTime
        /// The frame duration at `minRate`.
        var maxDuration: CMTime
    }

    /// The frame duration that makes a format with `ranges` capture at `framesPerSecond`: 1/`framesPerSecond`
    /// when a range holds that rate; otherwise the end of a range nearest to it, as the range gives it (a
    /// duration outside every range raises an Objective-C exception, which Swift cannot catch). `nil` without
    /// ranges.
    static func frameDuration(framesPerSecond: Int, ranges: [RateRange]) -> CMTime? {
        let rate = Double(framesPerSecond)
        if ranges.contains(where: { $0.minRate <= rate && rate <= $0.maxRate }) {
            return CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        }
        let ends = ranges.flatMap { [(rate: $0.maxRate, duration: $0.minDuration), (rate: $0.minRate, duration: $0.maxDuration)] }
        return ends.min { abs($0.rate - rate) < abs($1.rate - rate) }?.duration
    }
}
