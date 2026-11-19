// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat

/// What the camera's analysis left in a project's caches (phase 2 design §6.1, §6.2 and §10), read and never written:
/// the person's mask (`personMask-1`) and the face (`faceTrack-1`) of each segment of the camera the document draws, as
/// the render reads them (`AnalysisInputs.personMasks`, `.faceTracks`). Shared by the camera's jobs (ProjectJobs'
/// `CameraAnalysis`, which makes them) and the library's thumbnails (which never make any).
///
/// - **Which segments.** Those of the camera track `CameraBubble` draws (the take's first camera track with a segment,
///   none while the document hides the camera), each `SegmentAvailability.present` and with a `SegmentIdentity` (not a
///   link), which names its cache: `masks/<take>/<track>/<segment>-personMask-1.mov` and
///   `faces/<take>/<track>/<segment>-faceTrack-1.json` (`ProjectCaches.analysisFile`).
public enum CameraAnalysisCaches {
    /// `inputs` with its masks and faces replaced by what the caches hold whole for what `document` asks of `take`: the
    /// committed mask movie of each segment (a regular file of some bytes at its name) while the background is not
    /// `original`, and the face track that decodes as `faceTrack-1` while the framing follows the face; nothing else.
    /// A temporary not committed is never at the name, and a JSON that does not decode is not there. Reads the disk:
    /// never on the main thread.
    public static func fill(
        _ inputs: inout AnalysisInputs, document: EditDocument, take: TakeRecord, package: ProjectPackage, caches: ProjectCaches
    ) {
        var masks: [CameraSegment: URL] = [:]
        var faces: [CameraSegment: CameraFaceTrack] = [:]
        if let track = cameraTrack(document: document, take: take) {
            for segment in analysable(track, in: package) {
                guard let identity = SegmentIdentity.of(segment, in: package) else { continue }
                let key = CameraSegment(take: take.id, track: track.id, segment: segment.index)
                if document.camera.background != .original,
                   let url = maskFile(take: take.id, track: track.id, identity: identity, caches: caches), isWholeFile(url) {
                    masks[key] = url
                }
                if document.camera.framing.mode == .face,
                   let url = faceFile(take: take.id, track: track.id, identity: identity, caches: caches),
                   let face = readFaceTrack(url) {
                    faces[key] = face
                }
            }
        }
        inputs.personMasks = masks
        inputs.faceTracks = faces
    }

    /// The camera track `CameraBubble` draws: the take's first camera track with a segment, unless the document hides
    /// the camera.
    public static func cameraTrack(document: EditDocument, take: TakeRecord) -> TrackRecord? {
        guard document.camera.show else { return nil }
        return take.tracks.first { $0.kind == .camera && !$0.segments.isEmpty }
    }

    /// The segments of `track` that can be analysed, in the order of their index: present, and not a link.
    public static func analysable(_ track: TrackRecord, in package: ProjectPackage) -> [SegmentRecord] {
        track.segments.sorted { $0.index < $1.index }.filter { segment in
            SegmentAvailability.classify(segment, in: package) == .present && SegmentIdentity.of(segment, in: package) != nil
        }
    }

    /// The mask's cache file of the segment of `identity` of camera track `track` of take `take`; `nil` if the names
    /// cannot name one (`ProjectCaches.analysisFile`).
    public static func maskFile(take: String, track: String, identity: SegmentIdentity, caches: ProjectCaches) -> URL? {
        caches.analysisFile(
            .masks, take: take, track: track, segment: identity, algorithm: CameraSegment.personMaskID, extension: "mov")
    }

    /// The face's cache file of the segment of `identity` of camera track `track` of take `take`; `nil` if the names
    /// cannot name one.
    public static func faceFile(take: String, track: String, identity: SegmentIdentity, caches: ProjectCaches) -> URL? {
        caches.analysisFile(.faces, take: take, track: track, segment: identity, algorithm: CameraFaceTrack.id, extension: "json")
    }

    /// Whether a regular file of some bytes is at `url`, by `lstat` (a link is not followed).
    public static func isWholeFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size > 0
    }

    /// The face track at `url`, if it is there and decodes as `faceTrack-1`.
    public static func readFaceTrack(_ url: URL) -> CameraFaceTrack? {
        guard let data = ProjectCaches.readAnalysis(url),
              let face = try? ProjectJSON.decoder().decode(CameraFaceTrack.self, from: data),
              face.algorithm == CameraFaceTrack.id
        else { return nil }
        return face
    }
}
