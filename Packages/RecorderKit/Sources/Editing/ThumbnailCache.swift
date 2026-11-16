// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import ProjectFormat

/// The timeline's thumbnails of the raw screen recording, without style or zoom (design §5.5): made with
/// `AVAssetImageGenerator` and kept in `thumbnails/` of the project's cache folder as
/// `<take>-<track>-seg-NNNN-<ms>-<height>.png` (the cache folder is the project's, shared by its takes), from which they
/// are read afterwards. A file that is missing (macOS empties caches) or damaged is made again.
///
/// A thumbnail is of the millisecond of its segment's file at or before the time asked for, and may show a frame up to
/// half the interval between keyframes (0.5 s) earlier, never a later one: an exact one would decode from a keyframe each
/// time. The timeline asks only for times its clips keep.
///
/// The generator decodes on AVFoundation's own threads and answers through a callback, so nothing blocks the main
/// thread or a thread of Swift's cooperative pool; the files are read and written on a dispatch queue of the cache's own.
/// One thumbnail is made at a time, with one generator alive (its segment's, reused while the requests stay in it), so
/// the memory held does not grow with the requests. Callers asking for the same thumbnail at once share one piece of
/// work, which is cancelled, the generator's request with it, once all of them are; a cancelled caller gets `nil`.
///
/// It reads the segments at `project.package.url`: give it the session's current `packageURL` (the package may have
/// been renamed). It writes nothing in the package.
public actor ThumbnailCache {
    /// The tallest thumbnail made, in pixels: the timeline's video track is 56 pt.
    static let maxHeight = 512
    /// The widest a thumbnail is, as a multiple of its height: a recording wider than that is fitted by its width.
    static let maxAspect = 8
    /// How much earlier than the time asked for the frame may be: half the interval between keyframes (1 s).
    static let toleranceBefore = CMTime(value: 1, timescale: 2)

    private let project: LoadedProject
    private let caches: ProjectCaches
    /// Whether the take's ids and segment files are ones the manifest may have (`TakeRecord.validatePaths()`), so the
    /// names built from them stay inside the cache folder; without it, there are no thumbnails.
    private let namesAreSafe: Bool
    /// Encodes, reads and writes the files.
    private let files = DispatchQueue(label: "dev.toma.Toma.ThumbnailCache", qos: .utility)
    private var work = SharedWork<CGImage?>()
    /// Whether a thumbnail is being made, and the work waiting for its turn, in order.
    private var making = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// The generator of the segment file thumbnails were made from last.
    private var generator: (file: URL, generator: AVAssetImageGenerator)?
    /// Numbers each request to the generator, so a cancellation reaches only its own.
    private var request = 0
    /// How many thumbnails were asked of the generator rather than read from their file, for tests.
    private(set) var generations = 0

    public init(project: LoadedProject, caches: ProjectCaches) {
        self.project = project
        self.caches = caches
        namesAreSafe = (try? project.take.validatePaths()) != nil
    }

    /// The thumbnail `height` pixels high (1 … 512; as high as the recording at most, never enlarged) of video track
    /// `track` of the take at source time `source`, or `nil` if `source` is in no segment of the track that can be read,
    /// if the track is not video or not in the take, if the generator fails, or for a caller cancelled before it is done.
    public func thumbnail(track: String, source: HostTime, height: Int) async -> CGImage? {
        guard namesAreSafe, let thumbnail = Thumbnail(project: project, track: track, source: source, height: height)
        else { return nil }
        let task = work.join(thumbnail.name) { Task { await self.make(thumbnail) } }
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(thumbnail.name, task) }
        }
        work.finish(thumbnail.name, task)
        return Task.isCancelled ? nil : image
    }

    private func leave(_ name: String, _ task: Task<CGImage?, Never>) {
        work.leave(name, task)
    }

    /// The thumbnail from its file, or made and written there.
    private func make(_ thumbnail: Thumbnail) async -> CGImage? {
        let file = caches.thumbnails.appending(path: thumbnail.name, directoryHint: .notDirectory)
        let cached = await onFiles {
            ProjectCaches.read(file).flatMap {
                BoundedImage.decode($0, maxPixelSide: Self.maxHeight * Self.maxAspect, allowedTypes: ["public.png"])
            }
        }
        if let cached { return cached }

        await takeTurn()
        defer { endTurn() }
        guard !Task.isCancelled, let image = await generate(thumbnail), !Task.isCancelled else { return nil }
        _ = await onFiles { Self.png(image).map { ProjectCaches.write($0, to: file) } }
        return image
    }

    /// The frame of `thumbnail` from the generator of its segment file.
    private func generate(_ thumbnail: Thumbnail) async -> CGImage? {
        let current: AVAssetImageGenerator
        if let generator, generator.file == thumbnail.file {
            current = generator.generator
        } else {
            current = AVAssetImageGenerator(asset: AVURLAsset(url: thumbnail.file))
            current.appliesPreferredTrackTransform = true
            current.requestedTimeToleranceBefore = Self.toleranceBefore
            current.requestedTimeToleranceAfter = .zero
            generator = (thumbnail.file, current)
        }
        current.maximumSize = CGSize(width: thumbnail.height * Self.maxAspect, height: thumbnail.height)
        generations += 1
        request += 1
        let number = request
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                current.generateCGImageAsynchronously(for: thumbnail.time) { image, _, _ in
                    continuation.resume(returning: image)
                }
            }
        } onCancel: {
            Task { await self.cancel(request: number) }
        }
    }

    /// Cancels request `number` to the generator, if it is the one it is working on.
    private func cancel(request number: Int) {
        guard number == request else { return }
        generator?.generator.cancelAllCGImageGeneration()
    }

    /// Waits until no other thumbnail is being made.
    private func takeTurn() async {
        guard making else {
            making = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func endTurn() {
        if waiting.isEmpty {
            making = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// Runs `body` on the cache's queue and waits for it without holding a thread.
    private func onFiles<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            files.async { continuation.resume(returning: body()) }
        }
    }

    /// `image` as a PNG, or `nil` if ImageIO cannot write it.
    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// One thumbnail asked for: where it is in which segment file, and the name of its file in the cache.
private struct Thumbnail: Sendable {
    var name: String
    /// The segment's file.
    var file: URL
    /// The time in the file: whole milliseconds from its start.
    var time: CMTime
    var height: Int

    /// `nil` unless `track` is a video track of the take and `source` is in one of its segments that can be read
    /// (`SegmentAvailability.present`): from its start up to its end, or on from its start while it is open.
    init?(project: LoadedProject, track id: String, source: HostTime, height: Int) {
        guard (1...ThumbnailCache.maxHeight).contains(height), let track = project.take.track(id), track.kind.isVideo,
              let segment = track.segments.filter({ $0.startHostTime <= source }).max(by: { $0.startHostTime < $1.startHostTime }),
              segment.endHostTime.map({ source < $0 }) ?? true,
              SegmentAvailability.classify(segment, in: project.package) == .present
        else { return nil }
        let milliseconds = (source.nanoseconds - segment.startHostTime.nanoseconds) / 1_000_000
        name = "\(project.take.id)-\(id)-seg-\(String(format: "%04d", segment.index))-\(milliseconds)-\(height).png"
        file = project.package.fileURL(segment.file)
        time = CMTime(value: CMTimeValue(milliseconds), timescale: 1_000)
        self.height = height
    }
}
