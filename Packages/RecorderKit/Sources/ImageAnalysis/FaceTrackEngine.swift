// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import Vision

/// What finds the faces in a frame of the camera: Vision's (`VisionFaceDetector`), or a test's.
public protocol FaceDetector: Sendable {
    /// The faces in `frame`, in Vision's normalized coordinates: fractions of the frame with the origin at its bottom
    /// left and y going up. Called on the engine's queue, never from two threads at once.
    func faces(in frame: CVPixelBuffer) throws -> [ProjectFormat.NormalizedRect]

    /// Whether it can work on this Mac: `true` unless it says otherwise. May take a moment the first time: ask off the
    /// main thread and off Swift's cooperative pool.
    var isAvailable: Bool { get }
}

extension FaceDetector {
    public var isAvailable: Bool { true }
}

/// Vision's face rectangles, as `faceTrack-1` freezes them (phase 2 design §6.2): `VNDetectFaceRectanglesRequest`
/// revision 3, on each frame alone.
public struct VisionFaceDetector: FaceDetector {
    public init() {}

    public var isAvailable: Bool { ImageAnalysisCondition.faceDetectionIsAvailable }

    public func faces(in frame: CVPixelBuffer) throws -> [ProjectFormat.NormalizedRect] {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        try VNImageRequestHandler(cvPixelBuffer: frame, options: [:]).perform([request])
        return (request.results ?? []).map { face in
            let box = face.boundingBox
            return ProjectFormat.NormalizedRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
        }
    }
}

/// `faceTrack-1` (phase 2 design §6.2): the biggest face of a camera segment every 100 ms of its source, which the analysis
/// caches keep as JSON (`CameraFaceTrack`) and `faceFraming-1` follows.
///
/// - **When.** The first frame presented at or after each 100 ms from the segment's start (its file's time 0): the
///   frame of time 0 (its first), then the first at or after 100 ms, and so on; where frames are further apart, one frame
///   is one sample, and the next is the first at or after the next 100 ms after it. Each sample's `t` is the segment's
///   start plus the frame's presentation time, as the render places the frame (`TrackFrameReader`).
/// - **Which face.** Of the faces the detector finds, each held to the frame, the one of the largest area, with its
///   origin moved to the top left (y going down, as `NormalizedRect`); none when the frame has no face.
/// - **Bounded.** Decoded one frame at a time on a queue of its own at utility QoS, as `PersonMaskEngine`; cancelling is
///   looked at before every frame.
public enum FaceTrackEngine {
    /// The algorithm of the face tracks, with its version (`CameraFaceTrack.id`).
    public static let algorithm = CameraFaceTrack.id
    /// How often a frame is looked at, in nanoseconds of the source.
    public static let interval: Int64 = 100_000_000

    /// The face track of the camera segment `segment`, which starts at `start`; `progress` gets the fraction done (0 to 1)
    /// from the engine's queue. Throws `ImageAnalysisError` (the segment cannot be read or holds no frame, or what the
    /// detector throws) or `CancellationError`.
    public static func track(
        segment: URL, start: HostTime, detector: any FaceDetector, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CameraFaceTrack {
        let frames = try await CameraSegmentFrames.open(segment)
        return try await onUtilityQueue(label: "dev.toma.Toma.FaceTrackEngine") { cancelled in
            var samples: [CameraFaceSample] = []
            var frameSize: [Int]?
            var next: Int64 = 0
            try frames.read(cancelled: cancelled) { frame, time in
                if frameSize == nil { frameSize = [CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame)] }
                let offset = Int64(HostTime(time).nanoseconds)
                guard offset >= next else { return }
                next = (offset / interval + 1) * interval
                let face = try detector.faces(in: frame).compactMap(topLeft).max { $0.width * $0.height < $1.width * $1.height }
                samples.append(CameraFaceSample(t: HostTime(nanoseconds: start.nanoseconds &+ UInt64(offset)), face: face))
                progress(frames.fraction(at: time))
            }
            guard let frameSize else { throw ImageAnalysisError.unreadable("the segment has no frame") }
            progress(1)
            return CameraFaceTrack(algorithm: algorithm, frameSize: frameSize, samples: samples)
        }
    }

    /// `rect`, in Vision's coordinates, held to the frame and with its origin at the top left; `nil` when nothing of it
    /// is in the frame or it is not a number.
    static func topLeft(_ rect: ProjectFormat.NormalizedRect) -> ProjectFormat.NormalizedRect? {
        let left = max(0, rect.x)
        let right = min(1, rect.x + rect.width)
        let top = max(0, 1 - (rect.y + rect.height))
        let bottom = min(1, 1 - rect.y)
        guard left.isFinite, right.isFinite, top.isFinite, bottom.isFinite, right > left, bottom > top else { return nil }
        return ProjectFormat.NormalizedRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
