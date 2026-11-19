// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import Foundation
import ProjectFormat
import VideoToolbox
import Vision

/// What reads a frame of the screen for `sensitiveScan-1`: the sensitive things in its content, each where it is.
/// `VisionRecognizer` in the app; a test hands in one that does not look.
public protocol ScreenRecognizer: Sendable {
    /// What is sensitive in `crop` of `frame` (in fractions of the frame, 0, 0 its top-left corner: the screen's content),
    /// with rects in fractions of `crop`, from its top left. Blocks: never on Swift's cooperative pool.
    func observe(_ frame: CVPixelBuffer, crop: Rect) throws -> [FrameObservation]

    /// Whether it can look on this Mac; a scan does not start without it.
    var isAvailable: Bool { get }
}

extension ScreenRecognizer {
    public var isAvailable: Bool { true }
}

/// Why `VisionRecognizer` could not look at a frame.
public enum VisionRecognizerError: Error, Equatable {
    /// The frame could not be made into an image (its format, or a crop outside it).
    case unreadableFrame
}

/// `sensitiveScan-1`'s recognizer (design §7.2, plan decision 10): Vision's text, precise, without language correction,
/// in Spanish and English, one line per observation with its first candidate, and every match of `SensitiveDetectors`
/// on it where `boundingBox(for:)` puts its characters (the whole line when Vision does not say); and the faces. On the
/// image of the content alone (the crop), so Vision's places are fractions of it; its origin, at the bottom left, is
/// turned to the top left.
///
/// Vision's precise text now and then reads nothing at all in an image full of text: 4 of the bench's 60 dense 4K pages
/// (and at 1080p too), always all of it or none, and an image a few pixels off reads every line. A still screen that
/// fell on one would go unread for as long as it stays still, so an image where it reads no line is read again from
/// the crop `retryInset` pixels in at the top, and then at the left (`retries`): a screen with no text costs two more
/// readings, of an image Vision reads quickly.
public struct VisionRecognizer: ScreenRecognizer {
    public static let languages = ["es-ES", "en-US"]
    /// Pixels the crop is moved in by when Vision read no line in it.
    static let retryInset = 4
    /// How many times an image where Vision read no line is read again.
    static let retries = 2

    public init() {}

    /// Whether this Mac recognizes text precisely in both languages.
    public static var isAvailable: Bool { availability }

    public var isAvailable: Bool { Self.isAvailable }

    private static let availability: Bool = {
        let request = textRequest()
        guard let supported = try? request.supportedRecognitionLanguages() else { return false }
        return languages.allSatisfy(supported.contains)
    }()

    private static func textRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        return request
    }

    public func observe(_ frame: CVPixelBuffer, crop: Rect) throws -> [FrameObservation] {
        let (width, height) = (CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame))
        guard let pixels = Self.pixels(of: crop, width: width, height: height) else { return [] }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &image) == noErr, let image else {
            throw VisionRecognizerError.unreadableFrame
        }

        // A place Vision gives in fractions of the image of `region` (from the bottom left), in fractions of `crop`
        // (from the top left): `region` is `crop` out to whole pixels, or a few pixels in from that.
        let (frameWidth, frameHeight) = (Double(width), Double(height))
        func place(_ box: CGRect, in region: CGRect) -> ProjectFormat.NormalizedRect {
            let (left, top) = (Double(region.minX), Double(region.minY))
            let (columns, rows) = (Double(region.width), Double(region.height))
            let x: Double = (left + box.minX * columns) / frameWidth
            let y: Double = (top + (1 - box.maxY) * rows) / frameHeight
            let boxWidth: Double = box.width * columns / frameWidth
            let boxHeight: Double = box.height * rows / frameHeight
            return ProjectFormat.NormalizedRect(
                x: (x - crop.x) / crop.width, y: (y - crop.y) / crop.height,
                width: boxWidth / crop.width, height: boxHeight / crop.height)
        }

        let inset = CGFloat(Self.retryInset)
        let regions = [
            pixels,
            CGRect(x: pixels.minX, y: pixels.minY + inset, width: pixels.width, height: pixels.height - inset),
            CGRect(x: pixels.minX + inset, y: pixels.minY, width: pixels.width - inset, height: pixels.height),
        ].prefix(1 + Self.retries)
        var observations: [FrameObservation] = []
        var faceObservations: [FrameObservation] = []
        for (attempt, region) in regions.enumerated() {
            // Vision takes no image of 2 pixels or less on a side, which holds nothing readable anyway.
            guard region.width > 2, region.height > 2, let content = image.cropping(to: region) else { break }
            let text = Self.textRequest()
            let faces = VNDetectFaceRectanglesRequest()
            // The faces once, with the first reading.
            try VNImageRequestHandler(cgImage: content, options: [:]).perform(attempt == 0 ? [text, faces] : [text])
            for face in faces.results ?? [] {
                faceObservations.append(FrameObservation(kind: .face, text: nil, rect: place(face.boundingBox, in: region)))
            }
            let lines = text.results ?? []
            for line in lines {
                guard let candidate = line.topCandidates(1).first else { continue }
                let string = candidate.string
                for match in SensitiveDetectors.matches(in: string) {
                    let box = (try? candidate.boundingBox(for: match.range))?.boundingBox ?? line.boundingBox
                    observations.append(
                        FrameObservation(kind: match.kind, text: String(string[match.range]), rect: place(box, in: region)))
                }
            }
            if !lines.isEmpty { break }
        }
        return observations + faceObservations
    }

    /// The whole pixels of a `width` × `height` frame that `crop` (fractions) covers, within it; `nil` when none or
    /// when `crop` is not finite.
    static func pixels(of crop: Rect, width: Int, height: Int) -> CGRect? {
        guard [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite), crop.width > 0, crop.height > 0 else {
            return nil
        }
        func span(_ origin: Double, _ size: Double, _ count: Int) -> Range<Int> {
            let lower = Int((max(origin, 0) * Double(count)).rounded(.down))
            let upper = Int((min(origin + size, 1) * Double(count)).rounded(.up))
            return min(lower, count)..<min(max(upper, lower), count)
        }
        let (columns, rows) = (span(crop.x, crop.width, width), span(crop.y, crop.height, height))
        guard !columns.isEmpty, !rows.isEmpty else { return nil }
        return CGRect(x: columns.lowerBound, y: rows.lowerBound, width: columns.count, height: rows.count)
    }
}
