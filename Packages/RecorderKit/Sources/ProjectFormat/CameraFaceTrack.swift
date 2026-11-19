// SPDX-License-Identifier: GPL-3.0-or-later

/// One segment of a camera track of a take: what the analysis caches keep a file of (phase 2 design §10, the person's
/// mask and the face), and the key they reach the render by (`AnalysisInputs.personMasks`, `.faceTracks`).
public struct CameraSegment: Hashable, Sendable {
    public var take: String
    /// The camera track's id.
    public var track: String
    /// The segment's `SegmentRecord.index`.
    public var segment: Int

    public init(take: String, track: String, segment: Int) {
        self.take = take
        self.track = track
        self.segment = segment
    }
}

extension CameraSegment {
    /// The algorithm of a segment's person's mask (phase 2 design §6.1), with its version: what `PersonMaskEngine`
    /// writes and its cache file is named after (`masks/<take>/<track>/<segment>-personMask-1.mov`). Another way of
    /// making it is another id, and another file.
    public static let personMaskID = "personMask-1"
}

/// The face of a camera's segment, `faceTrack-1` (phase 2 design §6.2): `VNDetectFaceRectanglesRequest` every 100 ms of
/// the camera's source, the biggest face of each frame. The analysis caches keep it as JSON, written whole by
/// `ProjectJSON.encoder()` (`faces/<take>/<track>/<segment>-faceTrack-1.json`), and the render reads it through
/// `AnalysisInputs.faceTracks` (`faceFraming-1`, Analysis' `FaceFramingPath`).
public struct CameraFaceTrack: Codable, Equatable, Sendable {
    /// The algorithm of these files, with its version: another way of finding the face is another id, and another file.
    public static let id = "faceTrack-1"

    /// `id` for the files of this version.
    public var algorithm: String
    /// The camera's frame the faces were found in, in pixels: its width and its height.
    public var frameSize: [Int]
    /// In order of `t`.
    public var samples: [CameraFaceSample]

    public init(algorithm: String, frameSize: [Int], samples: [CameraFaceSample]) {
        self.algorithm = algorithm
        self.frameSize = frameSize
        self.samples = samples
    }
}

/// The face of the camera's frame at source instant `t`: the biggest one, in fractions of the frame with its origin at the
/// top left (y going down, as `NormalizedRect`); `nil`, and left out of the JSON, when the frame has none.
public struct CameraFaceSample: Codable, Equatable, Sendable {
    public var t: HostTime
    public var face: NormalizedRect?

    public init(t: HostTime, face: NormalizedRect?) {
        self.t = t
        self.face = face
    }
}
