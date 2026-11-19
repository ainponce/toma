// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import CryptoKit
import Foundation
import ProjectFormat
import Render
import Synchronization

/// Why `SensitiveScan.run` found nothing: what it read could not be trusted to be what the output shows.
public enum SensitiveScanError: Error, Equatable {
    /// The segment of this file (`SegmentRecord.file`) is in the package but could not be decoded where a sample needed
    /// it (a file AVFoundation cannot open, a decode that stopped partway, a track that did not load in time): the
    /// frame held over it is not what the output shows once it reads. A segment that holds nothing (empty, missing, or
    /// unreadable to crash recovery) is not this: the output shows the frame before it there too.
    case unreadable(file: String)
}

/// `sensitiveScan-1` on one take (design §7.2): the frames `ScanSampling` picks, decoded with `TrackFrameReader`,
/// recognized when their thumbnail is not that of the last one recognized, and followed into findings by
/// `FindingTracker`.
public enum SensitiveScan {
    /// `sensitiveScan-1`.
    public static let algorithm = SensitiveDetectors.id

    /// The findings of `project`'s take as `document` shows it.
    ///
    /// - One sample at a time, so what it holds is one frame per screen track and the last results: a take of any
    ///   length scans in bounded memory. All of it (the take's events, decoding and recognizing) runs on a queue of its
    ///   own, at utility priority, never on Swift's cooperative pool.
    /// - At each sample, the frame shown then and its thumbnail (`LumaThumbnail`, of the sample's crop): when it differs
    ///   less than `LumaThumbnail.reuseThreshold` from the thumbnail of the last frame recognized of the same track and
    ///   crop, it is not recognized again and what was found there holds. Either way it goes to the tracker, in order.
    /// - Cancelling stops it between two samples (`CancellationError`). `progress` is told after each sample, the
    ///   fraction of the samples done, up to 1; a take without samples tells 1 at once.
    /// - Throws `SensitiveScanError.unreadable(file:)` as soon as a segment that is there cannot be decoded, and what the
    ///   recognizer throws.
    ///
    /// `segments` (the identities of the take's screen segments as the caller read them before, which go in the result)
    /// say what the result was made from; it reads nothing of them.
    public static func run(
        project: LoadedProject, document: EditDocument, recognizer: any ScreenRecognizer, segments: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ScanResult {
        let cancelled = Flag()
        let queue = DispatchQueue(label: "dev.toma.Toma.SensitiveScan", qos: .utility)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try scan(
                            project: project, document: document, recognizer: recognizer, segments: segments,
                            isCancelled: { cancelled.isSet }, progress: progress)
                    })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// A digest of the samples `run` looks at (`ScanSampling.samples`: each one's instant, screen track and crop), in hex:
    /// two documents that show the same frames of the take have the same one. Reads the take's events: never on the main
    /// thread.
    public static func fingerprint(project: LoadedProject, document: EditDocument) -> String {
        fingerprint(of: ScanSampling.samples(take: project.take, events: project.events, document: document))
    }

    static func fingerprint(of samples: [ScanSample]) -> String {
        var hash = SHA256()
        for sample in samples {
            let crop = sample.crop
            hash.update(data: Data("\(sample.t.nanoseconds) \(sample.track) \(crop.x) \(crop.y) \(crop.width) \(crop.height)\n".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The scan

    /// Set once, read from the scan's queue.
    private final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    /// What was recognized last in a track's crop.
    private struct Recognized {
        var track: String
        var crop: Rect
        var thumbnail: LumaThumbnail
        var observations: [FrameObservation]
    }

    private static func scan(
        project: LoadedProject, document: EditDocument, recognizer: any ScreenRecognizer, segments: [String],
        isCancelled: () -> Bool, progress: (Double) -> Void
    ) throws -> ScanResult {
        if isCancelled() { throw CancellationError() }
        let take = project.take
        let events = project.events
        let samples = ScanSampling.samples(take: take, events: events, document: document)
        var tracker = FindingTracker(take: take.id)
        var readers: [String: (reader: TrackFrameReader, present: Set<String>)] = [:]
        var recognized: [Recognized] = []

        for (k, sample) in samples.enumerated() {
            if isCancelled() { throw CancellationError() }
            try autoreleasepool {
                guard let record = take.track(sample.track) else { return }
                let (reader, present) = readers[sample.track] ?? (
                    TrackFrameReader(package: project.package, track: record),
                    Set(record.segments.filter { SegmentAvailability.classify($0, in: project.package) == .present }.map(\.file)))
                readers[sample.track] = (reader, present)
                let frame = reader.pixelBuffer(at: sample.t)
                if let file = reader.filesWithGaps.first(where: present.contains) {
                    throw SensitiveScanError.unreadable(file: file)
                }
                var observations: [FrameObservation] = []
                if let frame {
                    let thumbnail = LumaThumbnail(pixelBuffer: frame, crop: sample.crop)
                    let last = recognized.firstIndex { $0.track == sample.track && $0.crop == sample.crop }
                    if let last, thumbnail.reusesResult(of: recognized[last].thumbnail) {
                        observations = recognized[last].observations
                    } else {
                        observations = try recognizer.observe(frame, crop: sample.crop)
                        let entry = Recognized(track: sample.track, crop: sample.crop, thumbnail: thumbnail, observations: observations)
                        if let last { recognized[last] = entry } else { recognized.append(entry) }
                    }
                }
                tracker.add(observations, at: sample.t)
            }
            progress(Double(k + 1) / Double(samples.count))
        }
        if samples.isEmpty { progress(1) }
        return ScanResult(
            algorithm: algorithm, findings: tracker.findings(within: ScanSampling.span(take: take, events: events)),
            samples: fingerprint(of: samples), segments: segments, take: take.id, version: ScanResult.currentVersion)
    }
}
