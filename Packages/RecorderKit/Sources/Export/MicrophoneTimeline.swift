// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import os

/// A take's microphone as one continuous stream of 48 kHz Float32 PCM on the export's timeline, read in
/// order in blocks ready for the AAC encoder.
///
/// The track is the take's first microphone track. Each segment is placed by host time: its frames go to
/// output time `host − timelineStart`, where a frame's host time comes from its segment's clock map
/// (`ClockMap`). Segments marked `.empty` or `.unreadable`, missing files and files that cannot be read
/// are silence, listed in `missingAudio`; so is every gap between segments longer than `maxClosedGap`
/// (a gap is not missing audio: nothing was recorded there). A shorter gap (or overlap) after audio is
/// closed: the next segment follows on where the audio before it ended, which shifts that segment, and
/// only it, by up to `maxClosedGap` (20 ms) from its host time. Output before the first segment, after the
/// last and past `totalFrames` is silence too.
///
/// The stream is mono if every segment is, stereo otherwise: a mono segment goes to both channels, and a
/// segment of more than two channels is mixed down with every channel at unity gain into both, clipped to
/// full scale. That keeps the level of the one or two live inputs a multichannel interface usually has;
/// AVFoundation's own downmix gives silence for a discrete layout (`kAudioChannelLayoutTag_DiscreteInOrder`).
///
/// Not thread-safe: one owner reads it, from one thread at a time.
final class MicrophoneTimeline {
    static let sampleRate = 48_000.0
    /// The longest gap between two segments that is closed instead of filled with silence.
    static let maxClosedGap = 0.020
    /// Frames per block handed to the encoder.
    static let blockFrames = 4096
    /// The largest difference between the rate two consecutive clock anchors imply and the file's sample
    /// rate for the later one to be used: 5000 ppm, well beyond any real device clock.
    static let maxClockDeviation = 0.005

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    /// 1 for a mono microphone, 2 otherwise.
    let channels: Int
    /// Length of the stream, in frames.
    let totalFrames: Int64
    /// Format of the blocks: interleaved Float32 at `sampleRate` with `channels` channels.
    let formatDescription: CMAudioFormatDescription
    /// Output frame of the next block.
    private(set) var position: Int64 = 0
    /// Spans that are silent because a segment's audio could not be used, as they were found: the
    /// segments that could not be opened when loading, then the ones that failed while reading.
    private(set) var missingAudio: [MissingAudio]

    private let segments: [Segment]
    private var nextSegment = 0
    private var active: SegmentReader?
    /// Where the audio placed last ended, in output frames.
    private var lastAudioEnd: Int64?

    /// A segment that can be read, and where its frames go.
    struct Segment {
        var index: Int
        /// `SegmentRecord.file`.
        var file: String
        var asset: AVURLAsset
        var track: AVAssetTrack
        var map: ClockMap
        /// Channels of the file.
        var channels: Int
        /// Frames of the file at `sampleRate`, when its track says.
        var frames: Double?
        /// Output seconds of the segment's recorded span, for `missingAudio`.
        var span: (start: Double, end: Double)
    }

    /// The microphone of `project` on a timeline whose frame 0 is host time `timelineStart`, `totalFrames`
    /// long; `nil` if the take has no microphone track. Loads every segment's track, so the stream can then
    /// be read without waiting.
    /// - Throws: `ExportError.writerFailed` if the block format cannot be made.
    static func load(_ project: LoadedProject, timelineStart: HostTime, totalFrames: Int64) async throws -> MicrophoneTimeline? {
        guard let track = project.take.tracks.first(where: { $0.kind == .microphone }) else { return nil }
        let records = track.segments.sorted { $0.startHostTime < $1.startHostTime }
        let duration = Double(max(0, totalFrames)) / sampleRate
        var segments: [Segment] = []
        var missing: [MissingAudio] = []
        var rejectedAnchors = 0
        var maxChannels = 1
        for (k, record) in records.enumerated() {
            let next = k + 1 < records.count ? records[k + 1].startHostTime : nil
            // Where the segment's audio would go, for the summary: up to its end, the next segment or the export's end.
            let start = record.startHostTime.seconds(since: timelineStart)
            let end = (record.endHostTime ?? next).map { $0.seconds(since: timelineStart) } ?? duration
            func leaveOut(_ reason: MissingAudio.Reason) {
                if let entry = missingEntry(file: record.file, start: start, end: end, duration: duration, reason: reason) {
                    missing.append(entry)
                }
            }
            switch record.endReason {
            case .empty?:
                leaveOut(.empty)
                continue
            case .unreadable?:
                leaveOut(.unreadable)
                continue
            default:
                break
            }
            let url = project.package.url.appending(path: record.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                logger.error("Microphone segment \(record.index): \(record.file, privacy: .public) is missing; exporting silence")
                leaveOut(.fileMissing)
                continue
            }
            let asset = AVURLAsset(url: url)
            let audio: AVAssetTrack
            let sourceRate: Double
            let sourceChannels: Int
            let frames: Double?
            do {
                guard let first = try await asset.loadTracks(withMediaType: .audio).first,
                      let format = try await first.load(.formatDescriptions).first,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0
                else {
                    logger.error("Microphone segment \(record.index): no audio track; exporting silence")
                    leaveOut(.cannotOpen("the file has no audio track"))
                    continue
                }
                audio = first
                sourceRate = asbd.mSampleRate
                sourceChannels = Int(asbd.mChannelsPerFrame)
                let range = try await first.load(.timeRange).duration
                frames = range.isNumeric ? range.seconds * sampleRate : nil
            } catch {
                logger.error("Microphone segment \(record.index): cannot be loaded (\(String(describing: error), privacy: .public)); exporting silence")
                leaveOut(.cannotOpen(String(describing: error)))
                continue
            }
            maxChannels = max(maxChannels, sourceChannels)
            let anchors = clockAnchors(of: track.id, from: record.startHostTime, before: next, sourceRate: sourceRate, in: project.events)
            rejectedAnchors += anchors.rejected
            let map = ClockMap(
                start: record.startHostTime, anchors: anchors.kept, sourceRate: sourceRate,
                timelineStart: timelineStart, outputRate: sampleRate)
            segments.append(Segment(
                index: record.index, file: record.file, asset: asset, track: audio, map: map, channels: sourceChannels,
                frames: frames, span: (start, end)))
        }
        if rejectedAnchors > 0 {
            logger.error("Microphone track \(track.id, privacy: .public): \(rejectedAnchors) audio clock anchor(s) out of order or off by more than 5000 ppm; not used")
        }
        return try MicrophoneTimeline(segments: segments, missingAudio: missing, channels: min(maxChannels, 2), totalFrames: totalFrames)
    }

    /// `MissingAudio` for output seconds `start ..< end` clamped to the export (`0 ... duration`); `nil` when
    /// the span lies outside it.
    static func missingEntry(file: String, start: Double, end: Double, duration: Double, reason: MissingAudio.Reason) -> MissingAudio? {
        guard end >= 0, start <= duration else { return nil }
        let from = min(max(start, 0), duration)
        return MissingAudio(file: file, start: from, end: max(from, min(end, duration)), reason: reason)
    }

    /// The audio clock anchors of `track` logged at or after `start` and before `end`, in time order:
    /// `(frame, host time)` with both increasing, and how many were left out.
    ///
    /// The events do not name the segment: an anchor belongs to the segment whose span of host time holds
    /// it, which is unambiguous because a track's segments follow one another. An anchor is left out when it
    /// does not move forward, in both frame and time, from the last one kept (frame 0 at `start` to begin
    /// with), or when the rate it implies against the anchor logged before it (kept or not) is more than
    /// `maxClockDeviation` from `sourceRate`. Comparing with the one logged before means a single bad anchor,
    /// or a jump in the device's timestamps, costs at most the anchor after it too, not every later one.
    static func clockAnchors(
        of track: String, from start: HostTime, before end: HostTime?, sourceRate: Double, in events: [InputEvent]
    ) -> (kept: [(frame: Int, t: HostTime)], rejected: Int) {
        let logged = events.enumerated()
            .compactMap { offset, event -> (offset: Int, frame: Int, t: HostTime)? in
                guard case let .audioClock(other, frame) = event.kind, other == track, event.t >= start else { return nil }
                if let end, event.t >= end { return nil }
                return (offset, frame, event.t)
            }
            .sorted { ($0.t, $0.offset) < ($1.t, $1.offset) }
        var kept: [(frame: Int, t: HostTime)] = []
        var rejected = 0
        var lastKept = (frame: 0, t: start)
        var previous = lastKept
        for anchor in logged {
            defer { previous = (anchor.frame, anchor.t) }
            guard anchor.frame > lastKept.frame, anchor.t > lastKept.t else {
                rejected += 1
                continue
            }
            let reference = anchor.frame > previous.frame && anchor.t > previous.t ? previous : lastKept
            let rate = Double(anchor.frame - reference.frame) / (anchor.t.seconds(since: reference.t) * sourceRate)
            guard abs(rate - 1) <= maxClockDeviation else {
                rejected += 1
                continue
            }
            lastKept = (anchor.frame, anchor.t)
            kept.append(lastKept)
        }
        return (kept, rejected)
    }

    init(segments: [Segment], missingAudio: [MissingAudio] = [], channels: Int, totalFrames: Int64) throws {
        self.segments = segments
        self.missingAudio = missingAudio
        self.channels = channels
        self.totalFrames = max(0, totalFrames)
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = Self.layoutTag(channels: channels)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else {
            throw ExportError.writerFailed("cannot describe the audio blocks (OSStatus \(status))")
        }
        formatDescription = format
    }

    static func layoutTag(channels: Int) -> AudioChannelLayoutTag {
        channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
    }

    /// `AVChannelLayoutKey` data for `channels` (1 or 2).
    static func channelLayoutData(channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = layoutTag(channels: channels)
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// The next block of at most `blockFrames` frames, presented at its output time; `nil` once
    /// `totalFrames` have been read.
    func nextBlock() throws -> CMSampleBuffer? {
        guard position < totalFrames else { return nil }
        let count = Int(min(Int64(Self.blockFrames), totalFrames - position))
        var samples = [Float](repeating: 0, count: count * channels)
        fill(&samples, frames: count)
        let block = try makeSampleBuffer(samples, frames: count, at: position)
        position += Int64(count)
        return block
    }

    /// Writes output frames `position ..< position + count` into `samples`, which starts silent.
    private func fill(_ samples: inout [Float], frames count: Int) {
        var i = 0
        while i < count {
            let frame = position + Int64(i)
            guard let segment = active ?? activateNext(at: frame) else { return }  // no more audio: silence
            if frame < segment.firstOutputFrame {
                i += Int(min(Int64(count - i), segment.firstOutputFrame - frame))  // silence until it starts
                continue
            }
            if segment.read(outputFrame: frame, into: &samples, at: i * channels) {
                i += 1
            } else {
                if let failure = segment.readFailure {
                    note(segment.segment, from: Double(frame) / Self.sampleRate, .readFailed(failure))
                }
                lastAudioEnd = frame
                active = nil
            }
        }
    }

    /// Opens the next segment that still has audio at or after output frame `frame`. A segment that starts
    /// within `maxClosedGap` of where the audio before it ended follows on from there.
    private func activateNext(at frame: Int64) -> SegmentReader? {
        while nextSegment < segments.count {
            var segment = segments[nextSegment]
            nextSegment += 1
            if let end = lastAudioEnd {
                let gap = segment.map.output(atDecoded: 0) - Double(end)
                if abs(gap) <= Self.maxClosedGap * Self.sampleRate { segment.map.shift(by: -gap) }
            }
            if let frames = segment.frames, segment.map.output(atDecoded: frames) <= Double(frame) { continue }
            do {
                active = try SegmentReader(segment, channels: channels)
                return active
            } catch {
                Self.logger.error(
                    "Microphone segment \(segment.index): cannot be read (\(String(describing: error), privacy: .public)); exporting silence")
                note(segment, from: segment.span.start, .cannotOpen(String(describing: error)))
            }
        }
        return nil
    }

    /// Adds `segment`'s span from output second `start` on to `missingAudio`.
    private func note(_ segment: Segment, from start: Double, _ reason: MissingAudio.Reason) {
        let duration = Double(totalFrames) / Self.sampleRate
        if let entry = Self.missingEntry(file: segment.file, start: start, end: segment.span.end, duration: duration, reason: reason) {
            missingAudio.append(entry)
        }
    }

    private func makeSampleBuffer(_ samples: [Float], frames: Int, at position: Int64) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw ExportError.writerFailed("no audio block buffer (OSStatus \(status))") }
        status = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == noErr else { throw ExportError.writerFailed("cannot fill an audio block (OSStatus \(status))") }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription, sampleCount: frames,
            presentationTimeStamp: CMTime(value: position, timescale: CMTimeScale(Self.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw ExportError.writerFailed("no audio sample buffer (OSStatus \(status))") }
        return sample
    }
}

/// Where the frames of one microphone segment go: a piecewise-linear map between its frames, decoded at
/// the output rate, and output frames, through knots that pair a frame with its host time.
///
/// The first knot is frame 0 at the segment's start; the clock anchors add one each. Beyond the last
/// knot the map goes on at the rate of the last interval between two knots, or at the nominal rate with
/// only one.
struct ClockMap {
    /// Output frame and decoded frame of each knot, both increasing.
    private(set) var knots: [(output: Double, decoded: Double)]

    init(start: HostTime, anchors: [(frame: Int, t: HostTime)], sourceRate: Double, timelineStart: HostTime, outputRate: Double) {
        let scale = outputRate / sourceRate
        knots = [(start.seconds(since: timelineStart) * outputRate, 0)]
            + anchors.map { ($0.t.seconds(since: timelineStart) * outputRate, Double($0.frame) * scale) }
    }

    /// Moves every knot by `frames` output frames.
    mutating func shift(by frames: Double) {
        knots = knots.map { ($0.output + frames, $0.decoded) }
    }

    /// The decoded frame (fractional) that output frame `output` shows. For output frames read in order:
    /// `k`, the knot that starts the interval, starts at 0 and is kept between calls, so it only walks forward.
    func decoded(atOutput output: Double, interval k: inout Int) -> Double {
        while k + 1 < knots.count, knots[k + 1].output <= output { k += 1 }
        return knots[k].decoded + (output - knots[k].output) * slope(after: k)
    }

    /// The output frame (fractional) where decoded frame `decoded` goes.
    func output(atDecoded decoded: Double) -> Double {
        // The knot that starts the interval: the last one at or before `decoded`, the first before them all.
        var low = 0, high = knots.count
        while low < high {
            let mid = (low + high) / 2
            if knots[mid].decoded <= decoded { low = mid + 1 } else { high = mid }
        }
        let k = max(low - 1, 0)
        return knots[k].output + (decoded - knots[k].decoded) / slope(after: k)
    }

    /// Decoded frames per output frame from knot `k` on: towards the next knot, or as before the last one.
    private func slope(after k: Int) -> Double {
        guard knots.count > 1 else { return 1 }
        let (a, b) = k + 1 < knots.count ? (knots[k], knots[k + 1]) : (knots[k - 1], knots[k])
        return (b.decoded - a.decoded) / (b.output - a.output)
    }
}

/// Reads one segment's frames in order, decoded to interleaved Float32 at the output rate and mixed to the
/// stream's channels, and resamples them onto output frames through its clock map (linear interpolation).
private final class SegmentReader {
    let segment: MicrophoneTimeline.Segment
    let firstOutputFrame: Int64
    /// Why reading stopped before the end of the file, if it did.
    private(set) var readFailure: String?

    private let index: Int
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let map: ClockMap
    /// The interval of `map` the last frame read was in.
    private var knot = 0
    /// Channels of the stream (what `buffer` holds) and of the file.
    private let channels: Int
    private let sourceChannels: Int
    /// Decoded frames held, interleaved, from decoded frame `bufferStart`.
    private var buffer: [Float] = []
    private var bufferStart: Int64 = 0
    private var finished = false

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    init(_ segment: MicrophoneTimeline.Segment, channels: Int) throws {
        self.segment = segment
        index = segment.index
        map = segment.map
        self.channels = channels
        sourceChannels = segment.channels
        firstOutputFrame = Int64(segment.map.output(atDecoded: 0).rounded(.up))
        reader = try AVAssetReader(asset: segment.asset)
        output = AVAssetReaderTrackOutput(track: segment.track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MicrophoneTimeline.sampleRate,
            AVNumberOfChannelsKey: segment.channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.writerFailed("the reader takes no PCM output") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ExportError.writerFailed("the reader did not start")
        }
    }

    deinit {
        reader.cancelReading()
    }

    /// Writes the segment's sound at output frame `frame` into `samples` at `offset`. Returns false, writing
    /// nothing, once the segment has no frame there: it has ended.
    func read(outputFrame frame: Int64, into samples: inout [Float], at offset: Int) -> Bool {
        let position = max(0, map.decoded(atOutput: Double(frame), interval: &knot))
        let first = Int64(position.rounded(.down))
        guard hasFrame(first, keeping: first) else { return false }
        let fraction = Float(position - Double(first))
        let interpolates = fraction > 0 && hasFrame(first + 1, keeping: first)
        let a = Int(first - bufferStart) * channels
        if interpolates {
            let b = a + channels
            for c in 0..<channels { samples[offset + c] = buffer[a + c] + (buffer[b + c] - buffer[a + c]) * fraction }
        } else {
            for c in 0..<channels { samples[offset + c] = buffer[a + c] }
        }
        return true
    }

    /// One past the last decoded frame held.
    private var bufferEnd: Int64 { bufferStart + Int64(buffer.count / channels) }

    /// Whether decoded frame `frame` is held, decoding up to it if needed. Frames before `keep` may be let go.
    private func hasFrame(_ frame: Int64, keeping keep: Int64) -> Bool {
        while frame >= bufferEnd, !finished {
            discard(before: keep)
            decodeNext()
        }
        return frame >= bufferStart && frame < bufferEnd
    }

    /// Drops the held frames before `frame` once there are many of them.
    private func discard(before frame: Int64) {
        let stale = min(frame - bufferStart, Int64(buffer.count / channels))
        guard stale > 8192 else { return }
        buffer.removeFirst(Int(stale) * channels)
        bufferStart += stale
    }

    private func decodeNext() {
        guard let sample = output.copyNextSampleBuffer() else {
            finished = true
            if reader.status == .failed {
                let error = reader.error.map { String(describing: $0) } ?? "the reader failed"
                readFailure = error
                Self.logger.error("Microphone segment \(self.index): reading stopped (\(error, privacy: .public)); silence after it")
            }
            return
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var decoded = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
        let status = decoded.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard status == noErr else {
            finished = true
            readFailure = "cannot copy decoded audio (OSStatus \(status))"
            Self.logger.error("Microphone segment \(self.index): cannot copy decoded audio (OSStatus \(status)); silence after it")
            return
        }
        if sourceChannels == channels {
            buffer.append(contentsOf: decoded)
            return
        }
        // Mono to both channels, or every channel at unity gain into each, clipped.
        buffer.reserveCapacity(buffer.count + decoded.count / sourceChannels * channels)
        for frame in stride(from: 0, to: decoded.count - sourceChannels + 1, by: sourceChannels) {
            var sum: Float = 0
            for c in 0..<sourceChannels { sum += decoded[frame + c] }
            let mixed = min(max(sum, -1), 1)
            for _ in 0..<channels { buffer.append(mixed) }
        }
    }
}
