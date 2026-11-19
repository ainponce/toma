// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Vision

/// Whether this Mac's Vision does what the camera's analysis asks of it (phase 2 design §6.1, §6.2): the person's mask
/// (`personMask-1`) and the faces (`faceTrack-1`), with the request revisions their ids are frozen at. Found out once per
/// process, the first time it is asked, by running both requests on a small grey frame (a fraction of a second): never
/// ask on the main thread or on Swift's cooperative pool for the first time.
///
/// The jobs say `JobProblem.notOnThisMac` when it is `false`, and the tests that use Vision itself run only when it is
/// `true` (`.enabled(if: ImageAnalysisCondition.visionIsAvailable)`).
public enum ImageAnalysisCondition {
    /// Both: the masks and the faces.
    public static var visionIsAvailable: Bool { personSegmentationIsAvailable && faceDetectionIsAvailable }

    /// `VNGeneratePersonSegmentationRequest` (revision 1, `.balanced`, 8 bits) gives a mask here.
    public static var personSegmentationIsAvailable: Bool { personSegmentation }

    /// `VNDetectFaceRectanglesRequest` (revision 3) runs here.
    public static var faceDetectionIsAvailable: Bool { faceDetection }

    private static let personSegmentation: Bool = {
        guard let frame = greyFrame() else { return false }
        return (try? VisionPersonSegmenter().mask(of: frame)) != nil
    }()

    private static let faceDetection: Bool = {
        guard let frame = greyFrame() else { return false }
        return (try? VisionFaceDetector().faces(in: frame)) != nil
    }()

    /// 64 × 64 mid grey, BGRA.
    private static func greyFrame() -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, attributes, &made) == kCVReturnSuccess,
              let frame = made
        else { return nil }
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { return nil }
        memset(base, 0x80, CVPixelBufferGetBytesPerRow(frame) * 64)
        return frame
    }
}
