// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ProjectFormat
import Synchronization

/// The outline of an audio track the timeline draws: the minimum (`x`) and maximum (`y`) of its samples, over every
/// channel and clipped to full scale (−1 … 1), every 10 ms.
///
/// Pair *k* covers the host times from the start of the track's first segment (its earliest `startHostTime`) plus
/// *k* × 10 ms, for 10 ms. Each segment's pairs start at the pair of its own `startHostTime` (rounded to the nearest
/// 10 ms) and follow its samples, 10 ms of them each at the file's sample rate; where segments overlap, their pairs are
/// merged. Between segments, where a segment cannot be read and after the last pair the track is silent: `(0, 0)`.
public struct Waveform: Equatable, Sendable {
    /// Pairs per second of the track.
    public static let pairsPerSecond = 100

    public var pairs: [SIMD2<Float>]

    public init(pairs: [SIMD2<Float>]) {
        self.pairs = pairs
    }
}

/// The waveforms of the audio tracks of a take, worked out once per segment and kept in `waveforms/` of the project's
/// cache folder (design §5.5), as `<take>-<track>-seg-NNNN.bin`: the cache folder is the project's, shared by its takes.
/// A file that is missing (macOS empties caches), damaged or made from a file of another size is worked out again.
///
/// Decoding a segment (`AVAssetReader.copyNextSampleBuffer`, which blocks until AVFoundation's reads finish, for a whole
/// track) and the files run on a dispatch queue of the cache's own, one segment at a time, and come back through a
/// continuation: never on a thread of Swift's cooperative pool, which callers blocked that way would leave without
/// threads for those reads (the warning of `TrackFrameReader`), and never on the main thread. A segment is decoded a
/// buffer at a time, holding only its pairs. Callers asking for the same track at once share one piece of work, which is
/// cancelled once all of them are; a cancelled caller gets an empty waveform, and nothing half done is written.
///
/// It reads the segments at `project.package.url`: give it the session's current `packageURL` (the package may have
/// been renamed). It writes nothing in the package.
public actor WaveformCache {
    /// The longest track worked out, 24 h: what a damaged manifest says lies beyond is left out.
    static let maxPairs = 24 * 3_600 * Waveform.pairsPerSecond

    private let project: LoadedProject
    private let caches: ProjectCaches
    /// Whether the take's ids and segment files are ones the manifest may have (`TakeRecord.validatePaths()`), so the
    /// names built from them stay inside the cache folder; without it, every waveform is empty.
    private let namesAreSafe: Bool
    /// Decodes, reads and writes the files, one at a time.
    private let queue = DispatchQueue(label: "dev.toma.Toma.WaveformCache", qos: .utility)
    private var work = SharedWork<Waveform>()
    /// How many segments were decoded rather than read from their file, for tests.
    private(set) var decodedSegments = 0

    public init(project: LoadedProject, caches: ProjectCaches) {
        self.project = project
        self.caches = caches
        namesAreSafe = (try? project.take.validatePaths()) != nil
    }

    /// The waveform of audio track `track` of the take; empty for a track that is not audio or is not in the take, and
    /// for a caller cancelled before it is done.
    public func waveform(track: String) async -> Waveform {
        guard namesAreSafe, let record = project.take.track(track), !record.kind.isVideo else { return Waveform(pairs: []) }
        let task = work.join(track) { Task { await self.assemble(record) } }
        let waveform = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(track, task) }
        }
        work.finish(track, task)
        return Task.isCancelled ? Waveform(pairs: []) : waveform
    }

    private func leave(_ track: String, _ task: Task<Waveform, Never>) {
        work.leave(track, task)
    }

    /// The segments of `track` placed by host time.
    private func assemble(_ track: TrackRecord) async -> Waveform {
        let segments = track.segments.sorted { $0.startHostTime < $1.startHostTime }
        guard let origin = segments.first?.startHostTime else { return Waveform(pairs: []) }
        // Pairs not filled yet are (+∞, −∞), which merge into anything and come out as silence.
        let unfilled = SIMD2<Float>(.infinity, -.infinity)
        var pairs: [SIMD2<Float>] = []
        for segment in segments {
            guard !Task.isCancelled else { return Waveform(pairs: []) }
            let offset = Int((Double(segment.startHostTime.nanoseconds - origin.nanoseconds) / 10_000_000).rounded())
            guard offset < Self.maxPairs, let own = await segmentPairs(of: segment, track: track.id) else { continue }
            let end = min(offset + own.count, Self.maxPairs)
            if pairs.count < end { pairs += repeatElement(unfilled, count: end - pairs.count) }
            for (k, pair) in own.prefix(end - offset).enumerated() {
                let merged = pairs[offset + k]
                pairs[offset + k] = SIMD2(min(merged.x, pair.x), max(merged.y, pair.y))
            }
        }
        return Waveform(pairs: pairs.map { $0 == unfilled ? .zero : $0 })
    }

    /// The pairs of `segment`, from its file in the cache or decoded (and then written there); `nil` if it cannot be
    /// read or the work was cancelled.
    private func segmentPairs(of segment: SegmentRecord, track: String) async -> [SIMD2<Float>]? {
        guard !Task.isCancelled, SegmentAvailability.classify(segment, in: project.package) == .present else { return nil }
        let source = project.package.fileURL(segment.file)
        let file = caches.waveforms.appending(
            path: "\(project.take.id)-\(track)-seg-\(String(format: "%04d", segment.index)).bin", directoryHint: .notDirectory)
        let (bytes, cached) = await onQueue { () -> (Int64?, [SIMD2<Float>]?) in
            var info = stat()
            guard lstat(source.path, &info) == 0 else { return (nil, nil) }
            let bytes = Int64(info.st_size)
            return (bytes, ProjectCaches.read(file).flatMap { WaveformFile.decode($0, sourceBytes: bytes) })
        }
        guard let bytes else { return nil }
        if let cached { return cached }

        let asset = AVURLAsset(url: source)
        guard let audio = try? await asset.loadTracks(withMediaType: .audio).first,
              let format = try? await audio.load(.formatDescriptions).first,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mSampleRate >= Double(Waveform.pairsPerSecond), description.mChannelsPerFrame > 0,
              !Task.isCancelled
        else { return nil }
        let input = DecoderInput(asset: asset, track: audio, sampleRate: description.mSampleRate)
        let cancelled = DecodingCancellation()
        let decoded = await withTaskCancellationHandler {
            await onQueue { SegmentEnvelope.decode(input, cancelled: cancelled) }
        } onCancel: {
            cancelled.cancel()
        }
        guard let decoded, !Task.isCancelled else { return nil }
        decodedSegments += 1
        // A file whose reading stopped partway is shown as far as it was read, and decoded again next time.
        if decoded.complete {
            let data = WaveformFile.encode(decoded.pairs, sourceBytes: bytes)
            _ = await onQueue { ProjectCaches.write(data, to: file) }
        }
        return decoded.pairs
    }

    /// Runs `body` on the cache's queue and waits for it without holding a thread.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// A segment's asset and its audio track, loaded, handed to the cache's queue to decode.
///
/// Unchecked because `AVAssetTrack` is not marked `Sendable`: the track is only handed to the one
/// `AVAssetReaderTrackOutput` that decodes it, on the queue, and not used anywhere else meanwhile.
private struct DecoderInput: @unchecked Sendable {
    var asset: AVURLAsset
    var track: AVAssetTrack
    /// The track's sample rate, which decoding keeps.
    var sampleRate: Double
}

/// Set once the work that decodes is cancelled, read by the decoding on the queue between buffers.
private final class DecodingCancellation: Sendable {
    private let flag = Atomic(false)
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func cancel() { flag.store(true, ordering: .relaxed) }
}

/// The minimum and maximum of every 10 ms of a segment's samples, as they are decoded.
private struct SegmentEnvelope {
    let sampleRate: Double
    private(set) var pairs: [SIMD2<Float>] = []
    /// Frames added so far.
    private var frames: Int64 = 0
    /// The frame where the pair being worked out ends.
    private var boundary: Int64
    private var low = Float.infinity
    private var high = -Float.infinity

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        boundary = Self.start(ofPair: 1, sampleRate: sampleRate)
    }

    /// The first frame of pair `k`: frames `start(k) ..< start(k + 1)` are its 10 ms.
    static func start(ofPair k: Int, sampleRate: Double) -> Int64 {
        Int64((Double(k) * sampleRate / Double(Waveform.pairsPerSecond)).rounded(.down))
    }

    /// Adds interleaved frames of `channels` channels. A sample that is not a number counts for nothing.
    mutating func add(_ samples: UnsafeBufferPointer<Float>, channels: Int) {
        var i = 0
        while i + channels <= samples.count {
            if frames == boundary { closePair() }
            for c in 0..<channels {
                let sample = samples[i + c]
                if sample < low { low = sample }
                if sample > high { high = sample }
            }
            frames += 1
            i += channels
        }
    }

    /// The pairs, the last one closed if any frame went into it.
    mutating func finish() -> [SIMD2<Float>] {
        if frames > Self.start(ofPair: pairs.count, sampleRate: sampleRate) { closePair() }
        return pairs
    }

    private mutating func closePair() {
        pairs.append(low <= high ? SIMD2(min(max(low, -1), 1), min(max(high, -1), 1)) : .zero)
        low = .infinity
        high = -.infinity
        boundary = Self.start(ofPair: pairs.count + 1, sampleRate: sampleRate)
    }

    /// The pairs of the segment `input` holds, and whether its file was read to the end; `nil` if it cannot be read at
    /// all or once `cancelled`. Blocks while it decodes: only on the cache's queue.
    static func decode(_ input: DecoderInput, cancelled: DecodingCancellation) -> (pairs: [SIMD2<Float>], complete: Bool)? {
        guard let reader = try? AVAssetReader(asset: input.asset) else { return nil }
        // At the file's own sample rate and channels.
        let output = AVAssetReaderTrackOutput(track: input.track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var envelope = SegmentEnvelope(sampleRate: input.sampleRate)
        var buffer: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let block = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let channels = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame, channels > 0
            else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            if buffer.count < count { buffer = [Float](repeating: 0, count: count) }
            let status = buffer.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: bytes.baseAddress!)
            }
            guard status == noErr else { return (envelope.finish(), false) }
            buffer.withUnsafeBufferPointer { envelope.add(UnsafeBufferPointer(rebasing: $0[..<count]), channels: Int(channels)) }
        }
        return (envelope.finish(), reader.status == .completed)
    }
}

/// A segment's pairs on disk: `TWAV`, the version (1, `UInt32`), the size in bytes of the segment file they were made
/// from (`UInt64`), the number of pairs (`UInt64`) and each pair's minimum and maximum (`Float32`), all little-endian.
private enum WaveformFile {
    static let magic = Array("TWAV".utf8)
    static let version: UInt32 = 1
    static let headerSize = 24

    static func encode(_ pairs: [SIMD2<Float>], sourceBytes: Int64) -> Data {
        var data = Data(capacity: headerSize + pairs.count * 8)
        data.append(contentsOf: magic)
        append(version, to: &data)
        append(UInt64(sourceBytes), to: &data)
        append(UInt64(pairs.count), to: &data)
        for pair in pairs {
            append(pair.x.bitPattern, to: &data)
            append(pair.y.bitPattern, to: &data)
        }
        return data
    }

    /// The pairs of `data`, or `nil` unless it is a whole file of this version made from a segment file of
    /// `sourceBytes` bytes, whose every pair is a minimum and a maximum within full scale.
    static func decode(_ data: Data, sourceBytes: Int64) -> [SIMD2<Float>]? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize, Array(bytes[0..<4]) == magic,
              UInt32(littleEndianBytes: bytes[4..<8]) == version,
              UInt64(littleEndianBytes: bytes[8..<16]) == UInt64(sourceBytes)
        else { return nil }
        let count = UInt64(littleEndianBytes: bytes[16..<24])
        guard count <= UInt64(WaveformCache.maxPairs), bytes.count == headerSize + Int(count) * 8 else { return nil }
        var pairs: [SIMD2<Float>] = []
        pairs.reserveCapacity(Int(count))
        for k in 0..<Int(count) {
            let at = headerSize + k * 8
            let low = Float(bitPattern: UInt32(littleEndianBytes: bytes[at..<(at + 4)]))
            let high = Float(bitPattern: UInt32(littleEndianBytes: bytes[(at + 4)..<(at + 8)]))
            guard low >= -1, high <= 1, low <= high else { return nil }
            pairs.append(SIMD2(low, high))
        }
        return pairs
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

private extension FixedWidthInteger {
    /// The integer whose little-endian bytes are `bytes`, exactly `MemoryLayout<Self>.size` of them.
    init(littleEndianBytes bytes: ArraySlice<UInt8>) {
        self = bytes.reversed().reduce(0) { $0 << 8 | Self($1) }
    }
}
