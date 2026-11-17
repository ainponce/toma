// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO
import ProjectFormat

/// What the export sheet warns about (1c design §7.3).
public enum GIFWarning: Equatable, Sendable {
    /// The GIF lasts more than a minute.
    case longerThanAMinute
    /// The GIF is estimated to weigh more than 10 MB.
    case over10MB
    /// The GIF is estimated to weigh more than 50 MB.
    case over50MB
}

public struct GIFEstimateResult: Equatable, Sendable {
    /// The estimated size of the GIF, to two significant digits.
    public var bytes: Int64
    /// The GIF's length.
    public var seconds: Double
    /// The frames the export will draw.
    public var frames: Int
    public var warnings: [GIFWarning]

    public init(bytes: Int64, seconds: Double, frames: Int, warnings: [GIFWarning]) {
        self.bytes = bytes
        self.seconds = seconds
        self.frames = frames
        self.warnings = warnings
    }
}

/// The export sheet's size estimate and short preview (1c design §7.3): short stretches of the range really encoded with
/// the settings, never a formula. Cancel the task running either to stop.
///
/// A stretch is a GIF of its own, so its first image is a whole frame, with nothing transparent, and the export of the range
/// pays one of those only once: the estimate is one first image (the mean of the stretches') and the bytes the
/// stretches spend after theirs, per frame, times the range's frames but the first (design §7.3 as amended by the
/// controller's ruling of Task 25). Per second of every stretch, as §7.3 had it, the still takes of the GIF corpus came out
/// up to twice their size (`GIFCorpusTests`).
public enum GIFEstimate {
    /// Stretches encoded for the estimate.
    public static let sampleCount = 8
    /// Seconds of each stretch.
    public static let sampleSeconds = 1.0
    /// Seconds of the preview.
    public static let previewSeconds = 3.0

    private static let second: Int64 = 1_000_000_000
    private static let megabyte: Int64 = 1_000_000

    /// The stretches the estimate encodes: the whole range if it lasts `sampleCount` seconds or less, else `sampleCount`
    /// of `sampleSeconds`, spread evenly, the first at the range's start and the last ending at its end.
    public static func sampleRanges(_ range: ExportRange) -> [ExportRange] {
        let length = range.end - range.start
        let sample = Int64(sampleSeconds * 1e9)
        guard length > Int64(sampleCount) * sample else { return [range] }
        let slack = length - sample
        return (0..<sampleCount).map { i in
            let start = range.start + slack * Int64(i) / Int64(sampleCount - 1)
            return ExportRange(start: start, end: start + sample)
        }
    }

    /// The preview's stretch: `previewSeconds` from `playhead` if it is inside `range`, else from the range's start,
    /// cut at the range's end.
    public static func previewRange(_ range: ExportRange, playhead: Int64) -> ExportRange {
        let start = (range.start..<range.end).contains(playhead) ? playhead : range.start
        return ExportRange(start: start, end: min(range.end, start + Int64(previewSeconds * 1e9)))
    }

    /// `bytes` to its two most significant digits.
    public static func roundedToTwoDigits(_ bytes: Int64) -> Int64 {
        guard bytes >= 100 else { return max(0, bytes) }
        var scale: Int64 = 10
        while bytes / scale >= 100 { scale *= 10 }
        return (bytes + scale / 2) / scale * scale
    }

    static func warnings(bytes: Int64, seconds: Double) -> [GIFWarning] {
        var warnings: [GIFWarning] = []
        if seconds > 60 { warnings.append(.longerThanAMinute) }
        if bytes > 10 * megabyte { warnings.append(.over10MB) }
        if bytes > 50 * megabyte { warnings.append(.over50MB) }
        return warnings
    }

    /// The preview: the GIF of `previewRange(settings.range, playhead:)` (from the range's start if what is left of it
    /// is shorter than a frame).
    public static func preview(
        project: LoadedProject, document: EditDocument, settings: GIFSettings, playhead: Int64
    ) async throws -> Data {
        var range = previewRange(settings.range, playhead: playhead)
        if !range.lastsAFrame(fps: settings.fps) { range = previewRange(settings.range, playhead: settings.range.start) }
        let exporter = GIFExporter(project: project, document: document, settings: settings)
        return try await exporter.encodeInMemory(range: range)
    }

    /// The GIF's size, at two digits, from `sampleRanges` encoded for real: one first image and the bytes per frame after
    /// it (see `GIFEstimate`). A `preview` already made (by `preview(...)`) counts as one of the stretches, in place of the
    /// first (the estimate does not know where the playhead was; the preview is 3 s of real content either way). All the
    /// stretches are drawn by one renderer.
    public static func estimate(
        project: LoadedProject, document: EditDocument, settings: GIFSettings, preview: Data?
    ) async throws -> GIFEstimateResult {
        let exporter = GIFExporter(project: project, document: document, settings: settings)
        let renderer = try exporter.makeRenderer()
        return try await estimate(settings: settings, preview: preview, first: nil) {
            try await exporter.encodeInMemory(range: $0, renderer: renderer)
        }
    }

    /// The estimate in two steps, for the export sheet: with a `preview` (and a range long enough to be sampled), first
    /// the estimate of the preview alone, as soon as it is called, and then the refined one, once the other stretches are
    /// encoded; the stream then ends. Without one, only the refined estimate. Cancel the task iterating it, or stop
    /// iterating, to stop the encoding.
    public static func estimates(
        project: LoadedProject, document: EditDocument, settings: GIFSettings, preview: Data?
    ) -> AsyncThrowingStream<GIFEstimateResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let exporter = GIFExporter(project: project, document: document, settings: settings)
                    let renderer = try exporter.makeRenderer()
                    let final = try await estimate(settings: settings, preview: preview, first: { continuation.yield($0) }) {
                        try await exporter.encodeInMemory(range: $0, renderer: renderer)
                    }
                    continuation.yield(final)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `estimate(project:…)` with the encoding of a stretch given (the tests count its calls). `first` is told the
    /// estimate of `preview` alone before any stretch is encoded, when it takes part (a range of up to `sampleCount`
    /// seconds is encoded whole and `preview` is ignored).
    static func estimate(
        settings: GIFSettings, preview: Data?, first: ((GIFEstimateResult) -> Void)?,
        encode: (ExportRange) async throws -> Data
    ) async throws -> GIFEstimateResult {
        let range = settings.range
        let samples = sampleRanges(range)
        let length = Double(range.end - range.start) / 1e9
        let frames = range.frameCount(fps: settings.fps)
        func result(_ stretches: [Stretch]) -> GIFEstimateResult {
            let estimated = estimatedBytes(stretches, frames: frames)
            return GIFEstimateResult(
                bytes: estimated, seconds: length, frames: frames, warnings: warnings(bytes: estimated, seconds: length))
        }
        var stretches: [Stretch] = []
        var skipped: Int?
        if samples.count > 1, let preview, let previewLength = duration(of: preview), previewLength > 0 {
            skipped = 0
            stretches.append(Stretch(preview, frames: Int((previewLength * Double(settings.fps)).rounded())))
            first?(result(stretches))
        }
        for (i, sample) in samples.enumerated() where i != skipped {
            try Task.checkCancellation()
            stretches.append(Stretch(try await encode(sample), frames: sample.frameCount(fps: settings.fps)))
        }
        guard stretches.contains(where: { $0.frames > 0 }) else { throw GIFExportError.rangeShorterThanAFrame }
        return result(stretches)
    }

    /// A stretch encoded for the estimate: its bytes, those up to the end of its first image (the header and the loop
    /// extension with it; `nil` if it does not read as one of our GIFs) and its frames.
    struct Stretch: Equatable {
        var bytes: Int
        var firstImage: Int?
        var frames: Int

        init(bytes: Int, firstImage: Int?, frames: Int) {
            self.bytes = bytes
            self.firstImage = firstImage
            self.frames = frames
        }

        init(_ gif: Data, frames: Int) {
            self.init(bytes: gif.count, firstImage: GIFEstimate.firstImageEnd(of: gif), frames: frames)
        }
    }

    /// `estimatedSize(_:frames:)` at two digits.
    static func estimatedBytes(_ stretches: [Stretch], frames: Int) -> Int64 {
        roundedToTwoDigits(Int64(estimatedSize(stretches, frames: frames).rounded()))
    }

    /// The bytes of a GIF of `frames` frames from `stretches`: the mean of the first images that were read, and the bytes
    /// after them over the frames after them, of the stretches that have some, times `frames − 1`. When no stretch read
    /// has frames after its first (a range of one frame) or none was read, each stretch's total bytes per frame, times
    /// `frames`: never 0 when something was encoded, and a stretch not read never counts as a first image of 0 bytes.
    static func estimatedSize(_ stretches: [Stretch], frames: Int) -> Double {
        let read = stretches.compactMap { stretch in stretch.firstImage.map { (stretch, $0) } }
        let split = read.filter { $0.0.frames > 1 }
        guard !split.isEmpty else {
            let bytes = stretches.reduce(0) { $0 + $1.bytes }
            let stretchFrames = stretches.reduce(0) { $0 + max(1, $1.frames) }
            return stretchFrames > 0 ? Double(bytes) * Double(max(1, frames)) / Double(stretchFrames) : 0
        }
        let firstImage = Double(read.reduce(0) { $0 + $1.1 }) / Double(read.count)
        let rest = split.reduce(0) { $0 + $1.0.bytes - $1.1 }
        let restFrames = split.reduce(0) { $0 + $1.0.frames - 1 }
        return firstImage + Double(rest) * Double(max(0, frames - 1)) / Double(restFrames)
    }

    /// Where the first image of a GIF ends: past the header, the logical screen and its colour table, the extensions
    /// before the image (the loop, its graphic control), its descriptor, its colour table and its data's sub-blocks. `nil`
    /// if `gif` ends before or has another block there.
    static func firstImageEnd(of gif: Data) -> Int? {
        gif.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
            guard bytes.count >= 13, bytes.prefix(3).elementsEqual("GIF".utf8) else { return nil }
            var position = 13
            if bytes[10] & 0x80 != 0 { position += 3 << (Int(bytes[10] & 7) + 1) }
            // Past the sub-blocks at `position`; false if the data ends first.
            func skipSubBlocks() -> Bool {
                while position < bytes.count {
                    let size = Int(bytes[position])
                    position += 1 + size
                    if size == 0 { return true }
                }
                return false
            }
            while position < bytes.count {
                switch bytes[position] {
                case 0x21:
                    position += 2
                    guard skipSubBlocks() else { return nil }
                case 0x2C:
                    guard position + 10 <= bytes.count else { return nil }
                    let packed = bytes[position + 9]
                    position += 10
                    if packed & 0x80 != 0 { position += 3 << (Int(packed & 7) + 1) }
                    position += 1  // the minimum code size
                    guard skipSubBlocks(), position <= bytes.count else { return nil }
                    return position
                default:
                    return nil
                }
            }
            return nil
        }
    }

    /// The seconds a GIF plays once (the sum of its images' delays), or `nil` if it is not one.
    static func duration(of gif: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(gif as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        var total = 0.0
        for i in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
                let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                let delay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            else { return nil }
            total += delay
        }
        return total
    }
}
