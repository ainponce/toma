// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import os

/// One audio track of a take, a microphone or system audio, as one continuous stream of 48 kHz Float32 PCM on the
/// export's timeline, read in order (`AudioMix` adds the tracks together).
///
/// Each segment is placed by host time: its frames go to output time `host − timelineStart`, where a frame's host
/// time comes from its segment's clock map (`ClockMap`), made from the track's own `audioClock` anchors. Segments
/// that are not `SegmentAvailability.present` (marked `.empty` or `.unreadable`, a file of 0 bytes or none) and
/// files that cannot be read are silence, listed in `missingAudio`; so is every gap between segments longer than
/// `maxClosedGap` (a gap is not missing audio: nothing was recorded there). A shorter gap (or overlap) after audio is
/// closed: the next segment follows on where the audio before it ended, which shifts that segment, and only it, by
/// up to `maxClosedGap` (20 ms) from its host time. Output before the first segment, after the last and past
/// `totalFrames` is silence too.
///
/// The stream has the `channels` it was loaded with, 1 or 2 (`channelCount(of:in:)` says how many the track needs):
/// a segment with that many goes as it is, a mono one goes to both channels, and any other is mixed down with every
/// channel at unity gain into each, clipped to full scale. That keeps the level of the one or two live inputs a
/// multichannel interface usually has; AVFoundation's own downmix gives silence for a discrete layout
/// (`kAudioChannelLayoutTag_DiscreteInOrder`).
///
/// Not thread-safe: one owner reads it, from one thread at a time.
final class AudioTrackTimeline {
    static let sampleRate = 48_000.0
    /// The longest gap between two segments that is closed instead of filled with silence.
    static let maxClosedGap = 0.020
    /// The largest difference between the rate two consecutive clock anchors imply and the file's sample
    /// rate for the later one to be used: 5000 ppm, well beyond any real device clock.
    static let maxClockDeviation = 0.005

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    /// The track's ID (`TrackRecord.id`), for `missingAudio`.
    let track: String
    /// Channels of the stream: what `read(into:frames:)` interleaves.
    let channels: Int
    /// Length of the stream, in frames.
    let totalFrames: Int64
    /// Output frame of the next frame read.
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

    /// The audio of one segment's file, as far as reading it needs, or why it cannot be used.
    private enum SegmentAudio {
        case audio(asset: AVURLAsset, track: AVAssetTrack, sampleRate: Double, channels: Int, frames: Double?)
        case unusable(MissingAudio.Reason)
    }

    /// `track` of `project` on a timeline whose frame 0 is host time `timelineStart`, `totalFrames` long, with
    /// `channels` channels (1 or 2). Loads every segment's track, so the stream can then be read without waiting.
    /// - Throws: `ExportError.cancelled` if the task is cancelled while loading.
    static func load(
        _ project: LoadedProject, track: TrackRecord, timelineStart: HostTime, totalFrames: Int64, channels: Int
    ) async throws -> AudioTrackTimeline {
        precondition(channels == 1 || channels == 2, "AudioTrackTimeline: \(channels) channels")
        let records = track.segments.sorted { $0.startHostTime < $1.startHostTime }
        let duration = Double(max(0, totalFrames)) / sampleRate
        var segments: [Segment] = []
        var missing: [MissingAudio] = []
        var rejectedAnchors = 0
        for (k, record) in records.enumerated() {
            guard !Task.isCancelled else { throw ExportError.cancelled }
            let next = k + 1 < records.count ? records[k + 1].startHostTime : nil
            // Where the segment's audio would go, for the summary: up to its end, the next segment or the export's end.
            let start = record.startHostTime.seconds(since: timelineStart)
            let end = (record.endHostTime ?? next).map { $0.seconds(since: timelineStart) } ?? duration
            switch await openAudio(of: record, in: project.package) {
            case let .audio(asset, audioTrack, sourceRate, sourceChannels, frames):
                let anchors = clockAnchors(of: track.id, from: record.startHostTime, before: next, sourceRate: sourceRate, in: project.events)
                rejectedAnchors += anchors.rejected
                let map = ClockMap(
                    start: record.startHostTime, anchors: anchors.kept, sourceRate: sourceRate,
                    timelineStart: timelineStart, outputRate: sampleRate)
                segments.append(Segment(
                    file: record.file, asset: asset, track: audioTrack, map: map, channels: sourceChannels, frames: frames,
                    span: (start, end)))
            case .unusable(let reason):
                logger.error("Audio segment \(record.file, privacy: .public): \(String(describing: reason), privacy: .public); exporting silence")
                if let entry = missingEntry(track: track.id, file: record.file, start: start, end: end, duration: duration, reason: reason) {
                    missing.append(entry)
                }
            }
        }
        if rejectedAnchors > 0 {
            logger.error("Audio track \(track.id, privacy: .public): \(rejectedAnchors) audio clock anchor(s) out of order or off by more than 5000 ppm; not used")
        }
        return AudioTrackTimeline(track: track.id, segments: segments, missingAudio: missing, channels: channels, totalFrames: totalFrames)
    }

    /// The channels the stream of `track` needs: 1 if every segment that can be opened is mono, 2 otherwise.
    static func channelCount(of track: TrackRecord, in project: LoadedProject) async -> Int {
        for record in track.segments {
            if case let .audio(_, _, _, channels, _) = await openAudio(of: record, in: project.package), channels > 1 { return 2 }
        }
        return 1
    }

    /// Opens `record`'s file, unless the manifest and the file system already say it holds nothing
    /// (`SegmentAvailability`): its first audio track, the track's format and its length.
    private static func openAudio(of record: SegmentRecord, in package: ProjectPackage) async -> SegmentAudio {
        switch SegmentAvailability.classify(record, in: package) {
        case .present: break
        case .missing: return .unusable(.fileMissing)
        case .empty: return .unusable(.empty)
        case .unreadable: return .unusable(.unreadable)
        }
        let asset = AVURLAsset(url: package.fileURL(record.file))
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let format = try await track.load(.formatDescriptions).first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0
            else { return .unusable(.cannotOpen("the file has no audio track")) }
            let range = try await track.load(.timeRange).duration
            return .audio(
                asset: asset, track: track, sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame),
                frames: range.isNumeric ? range.seconds * sampleRate : nil)
        } catch {
            return .unusable(.cannotOpen(String(describing: error)))
        }
    }

    /// `MissingAudio` of `track` for output seconds `start ..< end` clamped to the export (`0 ... duration`); `nil`
    /// when the span lies outside it.
    static func missingEntry(
        track: String, file: String, start: Double, end: Double, duration: Double, reason: MissingAudio.Reason
    ) -> MissingAudio? {
        guard end >= 0, start <= duration else { return nil }
        let from = min(max(start, 0), duration)
        return MissingAudio(track: track, file: file, start: from, end: max(from, min(end, duration)), reason: reason)
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
        let logged = events
            .filter { event in
                guard case .audioClock(track, _) = event.kind, event.t >= start else { return false }
                return end.map { event.t < $0 } ?? true
            }
            .sortedByTime()
            .compactMap { event -> (frame: Int, t: HostTime)? in
                guard case let .audioClock(_, frame) = event.kind else { return nil }
                return (frame, event.t)
            }
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

    private init(track: String, segments: [Segment], missingAudio: [MissingAudio], channels: Int, totalFrames: Int64) {
        self.track = track
        self.segments = segments
        self.missingAudio = missingAudio
        self.channels = channels
        self.totalFrames = max(0, totalFrames)
    }

    /// Reads the next `frames` frames of the stream into `samples`, which then holds exactly `frames × channels`
    /// values, interleaved: zeros where there is no audio (gaps, before the first segment, after the last, past
    /// `totalFrames`).
    func read(into samples: inout [Float], frames: Int) {
        samples.removeAll(keepingCapacity: true)
        samples.append(contentsOf: repeatElement(0, count: frames * channels))
        fill(&samples, frames: Int(min(Int64(frames), max(0, totalFrames - position))))
        position += Int64(frames)
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
                    "Audio segment \(segment.file, privacy: .public): cannot be read (\(String(describing: error), privacy: .public)); exporting silence")
                note(segment, from: segment.span.start, .cannotOpen(String(describing: error)))
            }
        }
        return nil
    }

    /// Adds `segment`'s span from output second `start` on to `missingAudio`.
    private func note(_ segment: Segment, from start: Double, _ reason: MissingAudio.Reason) {
        let duration = Double(totalFrames) / Self.sampleRate
        if let entry = Self.missingEntry(
            track: track, file: segment.file, start: start, end: segment.span.end, duration: duration, reason: reason) {
            missingAudio.append(entry)
        }
    }
}

/// Where the frames of one audio segment go: a piecewise-linear map between its frames, decoded at
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
    let segment: AudioTrackTimeline.Segment
    let firstOutputFrame: Int64
    /// Why reading stopped before the end of the file, if it did.
    private(set) var readFailure: String?

    /// `SegmentRecord.file`, for the log.
    private let file: String
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

    init(_ segment: AudioTrackTimeline.Segment, channels: Int) throws {
        self.segment = segment
        file = segment.file
        map = segment.map
        self.channels = channels
        sourceChannels = segment.channels
        firstOutputFrame = Int64(segment.map.output(atDecoded: 0).rounded(.up))
        reader = try AVAssetReader(asset: segment.asset)
        output = AVAssetReaderTrackOutput(track: segment.track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioTrackTimeline.sampleRate,
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
                Self.logger.error("Audio segment \(self.file, privacy: .public): reading stopped (\(error, privacy: .public)); silence after it")
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
            Self.logger.error("Audio segment \(self.file, privacy: .public): cannot copy decoded audio (OSStatus \(status)); silence after it")
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
