// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Vision
import VideoToolbox

/// Why an engine of the camera's analysis made nothing (`PersonMaskEngine`, `FaceTrackEngine`); `ProjectJobs` says it as
/// a `JobProblem`. A cancelled engine throws `CancellationError` instead.
public enum ImageAnalysisError: Error, Equatable {
    /// The camera's segment could not be opened or decoded, or holds no frame: why.
    case unreadable(String)
    /// Vision gave nothing for a frame, or not what it was asked for: why.
    case visionFailed(String)
    /// The drive is full.
    case diskFull
    /// The mask's movie could not be written: why.
    case writerFailed(String)
}

// MARK: - The segmenter

/// What finds the person in a frame of the camera: Vision's (`VisionPersonSegmenter`), or a test's.
public protocol PersonSegmenter: Sendable {
    /// The mask of the person in `frame`: `kCVPixelFormatType_OneComponent8`, 255 where the person is and 0 where the
    /// person is not, at the size the segmenter makes (`PersonMaskEngine` scales it to an even size). Called on the
    /// engine's queue, never from two threads at once.
    func mask(of frame: CVPixelBuffer) throws -> CVPixelBuffer

    /// Whether it can work on this Mac: `true` unless it says otherwise. May take a moment the first time: ask off the
    /// main thread and off Swift's cooperative pool.
    var isAvailable: Bool { get }

    /// The segmenter of the frames of one segment, handed them in presentation order from its first: Vision's keeps what
    /// it saw in the frames before (a stateful request), so the masks of a video do not flicker. By default, `self`.
    func sequence() -> any PersonSegmenter
}

extension PersonSegmenter {
    public var isAvailable: Bool { true }

    public func sequence() -> any PersonSegmenter { self }
}

/// Vision's person segmentation, as `personMask-1` freezes it (phase 2 design §6.1): `VNGeneratePersonSegmentationRequest`
/// revision 1 at `.balanced` quality, an 8-bit mask. `mask(of:)` looks at one frame alone; the engine uses `sequence()`,
/// one `VNSequenceRequestHandler` and one request for every frame of a segment, in order.
public struct VisionPersonSegmenter: PersonSegmenter {
    public init() {}

    public var isAvailable: Bool { ImageAnalysisCondition.personSegmentationIsAvailable }

    public func mask(of frame: CVPixelBuffer) throws -> CVPixelBuffer {
        let request = Self.makeRequest()
        try VNImageRequestHandler(cvPixelBuffer: frame, options: [:]).perform([request])
        return try Self.mask(of: request)
    }

    public func sequence() -> any PersonSegmenter { VisionPersonSequence() }

    static func makeRequest() -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        request.revision = VNGeneratePersonSegmentationRequestRevision1
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }

    static func mask(of request: VNGeneratePersonSegmentationRequest) throws -> CVPixelBuffer {
        guard let mask = request.results?.first?.pixelBuffer else {
            throw ImageAnalysisError.visionFailed("the person segmentation gave no mask")
        }
        return mask
    }
}

/// The frames of one segment through one stateful request. Used by the engine's queue alone, one frame at a time.
private final class VisionPersonSequence: PersonSegmenter, @unchecked Sendable {
    private let handler = VNSequenceRequestHandler()
    private let request = VisionPersonSegmenter.makeRequest()

    var isAvailable: Bool { ImageAnalysisCondition.personSegmentationIsAvailable }

    func mask(of frame: CVPixelBuffer) throws -> CVPixelBuffer {
        try handler.perform([request], on: frame)
        return try VisionPersonSegmenter.mask(of: request)
    }
}

// MARK: - The engine

/// `personMask-1` (phase 2 design §6.1, plan 2b decision 4): the person's mask of every frame of a camera segment, written
/// as a movie the render reads like the camera (`TrackFrameReader`), using its red channel.
///
/// - **The movie.** HEVC Main (8 bits) in a QuickTime movie, the mask's grey in BGRA (R = G = B) that the encoder takes
///   to 4:2:0, one key frame a second, at the size of the segmenter's first mask rounded to even numbers (each side
///   `round(n / 2) × 2`; a mask of another size is scaled bilinearly to it). Each mask frame has the presentation time of
///   its camera frame in the segment's file, the session starts at 0 as the camera's does, and it ends where the
///   camera's track ends: the mask of the camera's frame shown at a time is the mask's frame shown at that time.
/// - **Bounded.** The segment is decoded one frame at a time (`AVAssetReader`) on a queue of its own at utility QoS, and
///   each frame and its mask are let go before the next is read: never more than one in memory, whatever the length.
/// - **Cancelling** is looked at before every frame, so a cancelled task stops within one frame; whatever was written to
///   `to` is removed.
public enum PersonMaskEngine {
    /// The algorithm of the masks, with its version: another way of making them is another id, and another file.
    public static let algorithm = "personMask-1"
    /// The mask movie's average bit rate per pixel and frame.
    static let bitsPerPixel = 0.15

    /// Writes the masks of the camera segment `segment` to the new movie `to` (a temporary of the caches: nothing may be
    /// there yet), calling `progress` with the fraction of the segment done (0 to 1, never going down) from the engine's
    /// queue. Throws `ImageAnalysisError` (the segment cannot be read or holds no frame, Vision failed, the movie cannot
    /// be written, the drive is full) or `CancellationError`, and then leaves nothing at `to`.
    public static func write(
        segment: URL, to url: URL, segmenter: any PersonSegmenter, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var info = stat()
        guard lstat(url.path, &info) != 0 else {
            throw ImageAnalysisError.writerFailed("something is already at \(url.lastPathComponent)")
        }
        do {
            let frames = try await CameraSegmentFrames.open(segment)
            try await onUtilityQueue(label: "dev.toma.Toma.PersonMaskEngine") { cancelled in
                try writeMasks(of: frames, to: url, segmenter: segmenter.sequence(), cancelled: cancelled, progress: progress)
            }
        } catch {
            unlink(url.path)
            throw error
        }
    }

    /// The loop, on the engine's queue.
    private static func writeMasks(
        of frames: CameraSegmentFrames, to url: URL, segmenter: any PersonSegmenter, cancelled: () -> Bool,
        progress: (Double) -> Void
    ) throws {
        var writer: MaskMovieWriter?
        do {
            var last = CMTime.zero
            try frames.read(cancelled: cancelled) { frame, time in
                let mask = try segmenter.mask(of: frame)
                if writer == nil {
                    let (width, height) = MaskMovieWriter.evenSize(of: mask)
                    writer = try MaskMovieWriter(
                        url: url, width: width, height: height, framesPerSecond: frames.framesPerSecond)
                }
                try writer?.append(mask, at: time, cancelled: cancelled)
                last = time
                progress(frames.fraction(at: time))
            }
            guard let writer else { throw ImageAnalysisError.unreadable("the segment has no frame") }
            try writer.finish(at: frames.end(after: last))
            progress(1)
        } catch {
            writer?.cancel()
            throw error
        }
    }
}

// MARK: - Reading a segment

/// The video of one camera segment, opened, and read frame after frame (`read`). Shared by the camera's engines.
struct CameraSegmentFrames: @unchecked Sendable {
    // `@unchecked`: the asset and its track are only read, once opened.
    let asset: AVURLAsset
    let track: AVAssetTrack
    /// Where the track's media ends in its file; invalid when the file does not say.
    let trackEnd: CMTime
    /// The track's frame rate as the file says it; 30 when it says none.
    let framesPerSecond: Double

    /// Decoded biplanar 4:2:0 in IOSurfaces, the camera's own format, which Vision reads as it is.
    private static let outputSettings: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    /// Opens the segment file at `url` and its first video track; `ImageAnalysisError.unreadable` if it cannot.
    static func open(_ url: URL) async throws -> CameraSegmentFrames {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ImageAnalysisError.unreadable("the file has no video track")
            }
            let (range, rate) = try await track.load(.timeRange, .nominalFrameRate)
            let end = range.end
            return CameraSegmentFrames(
                asset: asset, track: track, trackEnd: end.isNumeric ? end : .invalid,
                framesPerSecond: rate.isFinite && rate > 0 ? Double(rate) : 30)
        } catch let error as ImageAnalysisError {
            throw error
        } catch {
            // AVFoundation's own error for a load its task cancelled is not a reason the segment cannot be read.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ImageAnalysisError.unreadable(describe(error))
        }
    }

    /// Decodes the frames in presentation order, one at a time, handing each to `body` with its presentation time in the
    /// file, each later than the one before (a frame that is not is skipped). Throws `CancellationError` once `cancelled()`
    /// says so, looked at before each frame, and `ImageAnalysisError.unreadable` when decoding fails. Blocks: on a queue
    /// of its own, never on Swift's cooperative pool.
    func read(cancelled: () -> Bool, _ body: (CVPixelBuffer, CMTime) throws -> Void) throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ImageAnalysisError.unreadable(Self.describe(error))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ImageAnalysisError.unreadable("the reader takes no output for the video") }
        reader.add(output)
        guard reader.startReading() else { throw ImageAnalysisError.unreadable(Self.describe(reader.error)) }
        defer { reader.cancelReading() }
        var last: CMTime?
        while true {
            if cancelled() { throw CancellationError() }
            // Each frame's objects go with it, not at the end of the segment.
            let more = try autoreleasepool { () throws -> Bool in
                guard let sample = output.copyNextSampleBuffer() else {
                    if reader.status == .failed { throw ImageAnalysisError.unreadable(Self.describe(reader.error)) }
                    return false
                }
                let time = sample.presentationTimeStamp
                guard time.isNumeric, let frame = CMSampleBufferGetImageBuffer(sample) else { return true }
                if let last, time <= last { return true }
                last = time
                try body(frame, time)
                return true
            }
            if !more { return }
        }
    }

    /// How far into the segment `time` is, 0 to 1.
    func fraction(at time: CMTime) -> Double {
        guard trackEnd.isNumeric, trackEnd.seconds > 0 else { return 0 }
        return min(max(time.seconds / trackEnd.seconds, 0), 1)
    }

    /// Where a movie of the segment's frames, the last at `last`, ends: where the track ends, or one frame after `last`
    /// when the file says nothing later.
    func end(after last: CMTime) -> CMTime {
        if trackEnd.isNumeric, trackEnd > last { return trackEnd }
        return CMTimeAdd(last, CMTime(seconds: 1 / framesPerSecond, preferredTimescale: 1_000_000_000))
    }

    /// `domain code: description` of an error and of the one under it.
    static func describe(_ error: (any Error)?) -> String {
        guard let error = error.map({ $0 as NSError }) else { return "no error given" }
        var text = "\(error.domain) \(error.code): \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        }
        return text
    }
}

// MARK: - Writing the masks

/// The mask movie being written; touched by the engine's queue alone.
private final class MaskMovieWriter {
    /// How long the encoder may take no frame before the writing gives up.
    static let stallTimeout = 60.0

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    /// A mask of another size, scaled to the movie's.
    private var scaled: [UInt8] = []

    /// Each side of `mask` rounded to an even number: `round(n / 2) × 2`, at least 2.
    static func evenSize(of mask: CVPixelBuffer) -> (Int, Int) {
        (even(CVPixelBufferGetWidth(mask)), even(CVPixelBufferGetHeight(mask)))
    }

    static func even(_ n: Int) -> Int {
        max(2, Int((Double(n) / 2).rounded()) * 2)
    }

    init(url: URL, width: Int, height: Int, framesPerSecond: Double) throws {
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw ImageAnalysisError.writerFailed(CameraSegmentFrames.describe(error))
        }
        let settings = Self.videoSettings(width: width, height: height, framesPerSecond: framesPerSecond)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw ImageAnalysisError.writerFailed("HEVC cannot encode \(width) × \(height)")
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ImageAnalysisError.writerFailed("the writer takes no video input") }
        writer.add(input)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        self.width = width
        self.height = height
        guard writer.startWriting() else { throw failure() }
        // At 0, as the camera's writer starts its own: each frame keeps its time.
        writer.startSession(atSourceTime: .zero)
    }

    static func videoSettings(width: Int, height: Int, framesPerSecond: Double) -> [String: Any] {
        let bitRate = Double(width) * Double(height) * framesPerSecond * PersonMaskEngine.bitsPerPixel
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                AVVideoAverageBitRateKey: max(200_000, Int(bitRate.rounded())),
                AVVideoExpectedSourceFrameRateKey: max(1, Int(framesPerSecond.rounded())),
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
    }

    /// Appends `mask` (8-bit grey) as the frame presented at `time`, its grey in B, G and R.
    func append(_ mask: CVPixelBuffer, at time: CMTime, cancelled: () -> Bool) throws {
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else {
            throw ImageAnalysisError.visionFailed("the mask is not one 8-bit component")
        }
        guard let pool = adaptor.pixelBufferPool else { throw failure() }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made) == kCVReturnSuccess, let frame = made else {
            throw ImageAnalysisError.writerFailed("the writer's pool gave no frame")
        }
        try draw(mask, into: frame)
        try waitUntilReady(cancelled: cancelled)
        guard adaptor.append(frame, withPresentationTime: time) else { throw failure() }
    }

    /// Ends the movie at `end` and waits until it is written.
    func finish(at end: CMTime) throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw failure() }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }

    /// `mask`'s grey into the BGRA `frame`, scaled bilinearly to it when their sizes differ.
    private func draw(_ mask: CVPixelBuffer, into frame: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        guard let source = CVPixelBufferGetBaseAddress(mask), let target = CVPixelBufferGetBaseAddress(frame) else {
            throw ImageAnalysisError.writerFailed("a frame has no memory")
        }
        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let maskRow = CVPixelBufferGetBytesPerRow(mask)
        var dest = vImage_Buffer(
            data: target, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(frame))
        let status: vImage_Error
        if maskWidth == width, maskHeight == height {
            var grey = vImage_Buffer(
                data: source, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: maskRow)
            status = vImageConvert_Planar8ToBGRX8888(&grey, &grey, &grey, 255, &dest, vImage_Flags(kvImageNoFlags))
        } else {
            if scaled.count != width * height { scaled = [UInt8](repeating: 0, count: width * height) }
            status = scaled.withUnsafeMutableBufferPointer { buffer -> vImage_Error in
                guard let scaledBase = buffer.baseAddress else { return vImage_Error(kvImageNullPointerArgument) }
                Self.scaleBilinear(
                    source.assumingMemoryBound(to: UInt8.self), width: maskWidth, height: maskHeight, rowBytes: maskRow,
                    into: scaledBase, width: width, height: height)
                var grey = vImage_Buffer(
                    data: scaledBase, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                return vImageConvert_Planar8ToBGRX8888(&grey, &grey, &grey, 255, &dest, vImage_Flags(kvImageNoFlags))
            }
        }
        guard status == kvImageNoError else { throw ImageAnalysisError.writerFailed("vImage failed (\(status))") }
    }

    /// Bilinear between the pixels' centres, held at the edges.
    static func scaleBilinear(
        _ source: UnsafePointer<UInt8>, width sourceWidth: Int, height sourceHeight: Int, rowBytes: Int,
        into target: UnsafeMutablePointer<UInt8>, width: Int, height: Int
    ) {
        guard sourceWidth > 0, sourceHeight > 0 else { return }
        let scaleX = Double(sourceWidth) / Double(width)
        let scaleY = Double(sourceHeight) / Double(height)
        for y in 0..<height {
            let fy = min(max((Double(y) + 0.5) * scaleY - 0.5, 0), Double(sourceHeight - 1))
            let y0 = Int(fy)
            let y1 = min(y0 + 1, sourceHeight - 1)
            let wy = fy - Double(y0)
            let row0 = source + y0 * rowBytes
            let row1 = source + y1 * rowBytes
            for x in 0..<width {
                let fx = min(max((Double(x) + 0.5) * scaleX - 0.5, 0), Double(sourceWidth - 1))
                let x0 = Int(fx)
                let x1 = min(x0 + 1, sourceWidth - 1)
                let wx = fx - Double(x0)
                let top = Double(row0[x0]) + (Double(row0[x1]) - Double(row0[x0])) * wx
                let bottom = Double(row1[x0]) + (Double(row1[x1]) - Double(row1[x0])) * wx
                target[y * width + x] = UInt8(min(max((top + (bottom - top) * wy).rounded(), 0), 255))
            }
        }
    }

    /// Returns once the input takes a frame; throws the writer's failure, `CancellationError`, or after `stallTimeout`.
    private func waitUntilReady(cancelled: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(Self.stallTimeout)
        while true {
            guard writer.status == .writing else { throw failure() }
            if input.isReadyForMoreMediaData { return }
            if cancelled() { throw CancellationError() }
            guard Date() < deadline else {
                throw ImageAnalysisError.writerFailed("the writer took no frame for \(Int(Self.stallTimeout)) s")
            }
            usleep(1_000)
        }
    }

    private func failure() -> ImageAnalysisError {
        if let error = writer.error, Self.isDiskFull(error) { return .diskFull }
        return .writerFailed(writer.error.map { CameraSegmentFrames.describe($0) } ?? "the writer stopped (status \(writer.status.rawValue))")
    }

    private static func isDiskFull(_ error: any Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case AVFoundationErrorDomain where error.code == AVError.Code.diskFull.rawValue: return true
        case NSPOSIXErrorDomain where error.code == Int(ENOSPC) || error.code == Int(EDQUOT): return true
        case NSCocoaErrorDomain where error.code == NSFileWriteOutOfSpaceError: return true
        default: break
        }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isDiskFull) ?? false
    }
}

// MARK: - The engines' queue

/// Whether the task of an engine was cancelled, for its queue to look at.
private final class CancelFlag: Sendable {
    private let value = Atomic(false)

    func set() { value.store(true, ordering: .relaxed) }
    var isSet: Bool { value.load(ordering: .relaxed) }
}

/// `body`'s value, made on a new serial queue of utility QoS, off Swift's cooperative pool; `body` is handed what says
/// whether the calling task was cancelled meanwhile.
func onUtilityQueue<T: Sendable>(
    label: String, _ body: @escaping @Sendable (_ cancelled: () -> Bool) throws -> T
) async throws -> T {
    let flag = CancelFlag()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: label, qos: .utility).async {
                continuation.resume(with: Result { try body { flag.isSet } })
            }
        }
    } onCancel: {
        flag.set()
    }
}
