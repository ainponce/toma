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

    /// The GIF's size: the bytes a second of `sampleRanges` encoded for real, times the range's length, at two digits. A
    /// `preview` already made (by `preview(...)`) counts as one of the stretches, in place of the first (the estimate does not
    /// know where the playhead was; the preview is 3 s of real content either way).
    public static func estimate(
        project: LoadedProject, document: EditDocument, settings: GIFSettings, preview: Data?
    ) async throws -> GIFEstimateResult {
        let exporter = GIFExporter(project: project, document: document, settings: settings)
        return try await estimate(settings: settings, preview: preview) { try await exporter.encodeInMemory(range: $0) }
    }

    /// `estimate(project:…)` with the encoding of a stretch given (the tests count its calls).
    static func estimate(
        settings: GIFSettings, preview: Data?, encode: (ExportRange) async throws -> Data
    ) async throws -> GIFEstimateResult {
        let range = settings.range
        let samples = sampleRanges(range)
        var bytes: Int64 = 0
        var seconds = 0.0
        var skipped: Int?
        if samples.count > 1, let preview, let length = duration(of: preview) {
            skipped = 0
            bytes += Int64(preview.count)
            seconds += length
        }
        for (i, sample) in samples.enumerated() where i != skipped {
            try Task.checkCancellation()
            bytes += Int64(try await encode(sample).count)
            seconds += Double(sample.end - sample.start) / 1e9
        }
        guard seconds > 0 else { throw GIFExportError.rangeShorterThanAFrame }
        let length = Double(range.end - range.start) / 1e9
        let estimated = roundedToTwoDigits(Int64((Double(bytes) / seconds * length).rounded()))
        return GIFEstimateResult(
            bytes: estimated, seconds: length, frames: range.frameCount(fps: settings.fps),
            warnings: warnings(bytes: estimated, seconds: length))
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
