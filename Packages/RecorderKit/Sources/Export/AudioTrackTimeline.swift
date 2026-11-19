// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import Synchronization
import os

/// One audio track of a take, a microphone or system audio, as one continuous stream of 48 kHz Float32 PCM on the take's
/// timeline, whose frame 0 is host time `origin` (`TakeTimeline.bounds`, where the legacy document starts). A `Reader`
/// reads any range of it (`EditedMix` reads the ranges its clips keep).
///
/// Each segment is placed by host time: its frames go to timeline frame `(host − origin) × 48 kHz`, where a frame's host
/// time comes from its segment's clock map (`ClockMap`), made from the track's own `audioClock` anchors. Segments that
/// are not `SegmentAvailability.present` (marked `.empty` or `.unreadable`, a file of 0 bytes or none) and files that
/// cannot be read are silence, listed in `missing`; so is every gap between segments longer than `maxClosedGap` (a gap
/// is not missing audio: nothing was recorded there). A shorter gap (or overlap) after audio is closed: the next segment
/// follows on where the audio before it ended, which shifts that segment, and only it, by up to `maxClosedGap` (20 ms)
/// from its host time. Before frame 0, before the first segment and after the last there is silence too.
///
/// Where each segment's audio goes is settled once, by `load`, the way the export read the track in order from frame 0
/// before 1b: every segment that is heard is decoded to its end beforehand, so where its audio ends, which is where the
/// next one follows on from over a closed gap, comes from that reading and never from what a reader has decoded so
/// far. A range of the stream is then the same whatever was read before it.
///
/// A range is read from near where it starts: the segments are ALAC or Float32 LPCM (`FragmentedTrackWriter`), whose
/// packets decode on their own, so a reader that starts its file `seekPreroll` frames before the range (an
/// `AVAssetReader.timeRange`) decodes the same samples a reader from the file's start does. A segment recorded at
/// another rate (a microphone at 44.1 kHz, or a Bluetooth one at 16 or 24 kHz) is resampled to 48 kHz as it is decoded:
/// started where one of its samples and a decoded frame fall at the same time (`seekGrid`: every 160 frames at
/// 44.1 kHz), the resampler runs at the phase it has there when read from the start, and after taking in a few frames
/// (at most 185, at 8 kHz, on macOS 26) gives the same samples; started anywhere else it never does. So a reader starts
/// it at the last such point at least `seekPreroll` frames before the range, if `load` saw that starting one in the
/// middle gives the frames of a reader from the start (`startsExactly`); such a reader can end up to 4 frames before
/// that one, and `load` keeps the last frames for it. A segment whose timestamps do not run on exactly with its decoded
/// frames, or that fails the check, is decoded from its start.
///
/// The stream has the `channels` it was loaded with, 1 or 2 (`channelCount(of:in:)` says how many the track needs):
/// a segment with that many goes as it is, a mono one goes to both channels, and any other is mixed down with every
/// channel at unity gain into each, clipped to full scale. That keeps the level of the one or two live inputs a
/// multichannel interface usually has; AVFoundation's own downmix gives silence for a discrete layout
/// (`kAudioChannelLayoutTag_DiscreteInOrder`).
final class AudioTrackTimeline: Sendable {
    static let sampleRate = 48_000.0
    /// The longest gap between two segments that is closed instead of filled with silence.
    static let maxClosedGap = 0.020
    /// The largest difference between the rate two consecutive clock anchors imply and the file's sample
    /// rate for the later one to be used: 5000 ppm, well beyond any real device clock.
    static let maxClockDeviation = 0.005

    fileprivate static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    /// The track's ID (`TrackRecord.id`), for `MissingAudio`.
    let track: String
    /// Channels of the stream: what a `Reader` interleaves.
    let channels: Int
    /// The segments that are heard, in order, over timeline frames that never overlap.
    let placed: [Placed]
    /// Spans of the source that are silent because a segment's audio could not be used, in the order of the segments:
    /// those that could not be opened, then where reading one stopped.
    let missing: [MissingSpan]
    /// The segments `load` decoded to find where their audio ends.
    var decodedSegments: Int { placed.count }

    /// A segment that can be read, and where its frames go.
    ///
    /// Unchecked because `AVAssetTrack` is not marked `Sendable`: a segment never changes once loaded, and its track,
    /// with its properties loaded, is only handed to a new `AVAssetReaderTrackOutput` whenever a reader opens the file.
    struct Segment: @unchecked Sendable {
        /// `SegmentRecord.file`.
        var file: String
        var asset: AVURLAsset
        var track: AVAssetTrack
        var map: ClockMap
        /// Channels of the file.
        var channels: Int
        /// The file's sample rate.
        var sourceRate: Double
        /// Frames of the file at `sampleRate`, when its track says.
        var frames: Double?
        /// Host time of the segment's recorded span: its start, and its end or the next segment's start (`nil` when
        /// there is neither), for `missing`.
        var start: HostTime
        var end: HostTime?
    }

    /// A segment as it is heard: its audio over timeline frames `start ..< end`, where `segment.map` (shifted to close a
    /// gap, if it was) puts it.
    struct Placed: Sendable {
        var segment: Segment
        var start: Int64
        var end: Int64
        /// The presentation time of decoded frame 0, when a reader can start the file at any point of its
        /// `seekGrid` (see the type).
        var seekOrigin: CMTime?
        /// The frames a reader from the file's start decodes, which a reader started in the middle never goes past.
        var decodedFrames: Int64
        /// The last of those frames (up to `tailFrames`, interleaved), for a reader started in the middle that ends a
        /// few frames earlier (see the type).
        var tail: [Float]
    }

    /// How many frames before the first one it needs a reader starts its file, at least, when it can start it in the
    /// middle: one ALAC packet, and far more than the resampler takes in before it gives the frames it gives from the
    /// start (at most 185 frames, at 8 kHz, on macOS 26).
    static let seekPreroll: Int64 = 4_096
    /// How far ahead of what it holds a reader reads on, rather than starting the file again near the frame asked for.
    static let readAhead: Int64 = 48_000
    /// The decoded frames after `seekPreroll` that `load` compares, for a segment it resamples, to see whether starting
    /// it in the middle gives the frames of a reader from its start.
    static let seekCheckFrames: Int64 = 8_192
    /// The last decoded frames of a segment that `load` keeps: a resampled file started in the middle can end up to 4
    /// frames before one read from its start (at 8 kHz, on macOS 26), with the same frames up to there.
    static let tailFrames: Int64 = 256

    /// Where a reader can start a file at `sourceRate` and decode the frames a reader from its start does: the decoded
    /// frames (at `sampleRate`) where one of the file's samples falls too, every `decoded` frames, which are `source`
    /// samples of the file. Every frame at 48 kHz; every 160 frames, 147 samples, at 44.1 kHz; every 3 frames, 1 sample,
    /// at 16 kHz. `nil` for a rate that is not a whole number of hertz.
    static func seekGrid(sourceRate: Double) -> (decoded: Int64, source: Int64)? {
        guard sourceRate >= 1, sourceRate <= 1_000_000, sourceRate.rounded() == sourceRate else { return nil }
        let rate = Int64(sourceRate), output = Int64(sampleRate)
        var (a, b) = (rate, output)
        while b != 0 { (a, b) = (b, a % b) }
        return (output / a, rate / a)
    }

    /// The decoded frames `startsExactly` compares for a reader started at decoded frame `start`.
    static func seekCheck(at start: Int64) -> Range<Int64> {
        (start + seekPreroll)..<(start + seekPreroll + seekCheckFrames)
    }

    /// The presentation time of decoded frame `frame` of a file at `sourceRate` whose decoded frame 0 is at `origin`:
    /// counted in the file's own samples when the frame is on its `seekGrid`, in decoded frames otherwise.
    static func time(ofDecoded frame: Int64, origin: CMTime, sourceRate: Double) -> CMTime {
        if let grid = seekGrid(sourceRate: sourceRate), frame % grid.decoded == 0 {
            return CMTimeAdd(origin, CMTime(value: frame / grid.decoded * grid.source, timescale: CMTimeScale(sourceRate)))
        }
        return CMTimeAdd(origin, CMTime(value: frame, timescale: CMTimeScale(sampleRate)))
    }

    /// Whether a reader that starts `segment`'s file at decoded frame `start` (its decoded frame 0 at `origin`) gives,
    /// from `seekPreroll` frames on and for `seekCheckFrames`, the bits a reader from the file's start gives there: its
    /// first frames come at the time asked for, and then the same frames. For a segment the reader resamples, which
    /// gives them only from a point of its `seekGrid` and only if its resampler forgets where it started (as macOS's
    /// does, after taking in a few frames), so `load` checks it instead of taking it for granted. `reference` is those
    /// frames from a reader from the start, when they are at hand; if not, they are decoded.
    /// - Throws: what opening the file throws.
    static func startsExactly(
        _ segment: Segment, channels: Int, origin: CMTime, at start: Int64, reference: [Float]? = nil
    ) throws -> Bool {
        let compared = seekCheck(at: start)
        let reference = try reference ?? SegmentDecoder(segment, channels: channels).frames(compared, decodedFrom: 0)
        let time = time(ofDecoded: start, origin: origin, sourceRate: segment.sourceRate)
        let fromMiddle = try SegmentDecoder(segment, channels: channels, from: time)
        guard let given = fromMiddle.frames(compared, decodedFrom: start, at: time) else { return false }
        return reference.map { $0.map(\.bitPattern) } == given.map(\.bitPattern)
    }

    /// Source host times `start ..< end` (to the end of the take when `end` is `nil`) of the track left silent.
    struct MissingSpan: Sendable {
        var file: String
        var start: HostTime
        var end: HostTime?
        var reason: MissingAudio.Reason
    }

    /// The audio of one segment's file, as far as reading it needs, or why it cannot be used.
    private enum SegmentAudio {
        case audio(asset: AVURLAsset, track: AVAssetTrack, sampleRate: Double, channels: Int, frames: Double?)
        case unusable(MissingAudio.Reason)
    }

    /// `track` of `project` on a timeline whose frame 0 is host time `origin`, with `channels` channels (1 or 2). Opens
    /// every segment's track and decodes the segments that are heard to their end (on a thread of its own, never on
    /// Swift's cooperative pool), so the stream can then be read from anywhere without waiting.
    /// - Throws: `ExportError.cancelled` if the task is cancelled while loading.
    static func load(_ project: LoadedProject, track: TrackRecord, origin: HostTime, channels: Int) async throws -> AudioTrackTimeline {
        precondition(channels == 1 || channels == 2, "AudioTrackTimeline: \(channels) channels")
        let records = track.segments.sorted { $0.startHostTime < $1.startHostTime }
        var segments: [Segment] = []
        var missing: [MissingSpan] = []
        var rejectedAnchors = 0
        for (k, record) in records.enumerated() {
            guard !Task.isCancelled else { throw ExportError.cancelled }
            let next = k + 1 < records.count ? records[k + 1].startHostTime : nil
            // Where the segment's audio would be, for `missing`: up to its end, the next segment or the end of the take.
            let end = record.endHostTime ?? next
            switch await openAudio(of: record, in: project.package) {
            case let .audio(asset, audioTrack, sourceRate, sourceChannels, frames):
                let anchors = clockAnchors(of: track.id, from: record.startHostTime, before: next, sourceRate: sourceRate, in: project.events)
                rejectedAnchors += anchors.rejected
                let map = ClockMap(
                    start: record.startHostTime, anchors: anchors.kept, sourceRate: sourceRate, timelineStart: origin, outputRate: sampleRate)
                segments.append(Segment(
                    file: record.file, asset: asset, track: audioTrack, map: map, channels: sourceChannels, sourceRate: sourceRate,
                    frames: frames, start: record.startHostTime, end: end))
            case .unusable(let reason):
                logger.error("Audio segment \(record.file, privacy: .public): \(String(describing: reason), privacy: .public); exporting silence")
                missing.append(MissingSpan(file: record.file, start: record.startHostTime, end: end, reason: reason))
            }
        }
        if rejectedAnchors > 0 {
            logger.error("Audio track \(track.id, privacy: .public): \(rejectedAnchors) audio clock anchor(s) out of order or off by more than 5000 ppm; not used")
        }
        let cancelled = CancellationFlag()
        let placed: [Placed], unread: [MissingSpan]
        do {
            (placed, unread) = try await withTaskCancellationHandler {
                try await offTheCooperativePool { [segments] in try place(segments, origin: origin, channels: channels, cancelled: cancelled) }
            } onCancel: {
                cancelled.cancel()
            }
        } catch is CancellationError {
            throw ExportError.cancelled  // while it waited for a decoding slot
        }
        return AudioTrackTimeline(track: track.id, channels: channels, placed: placed, missing: missing + unread)
    }

    /// Where the audio of each of `segments` (in time order) is heard, as reading the track in order from frame 0 finds
    /// it: each segment from where the one before ended (frame 0 for the first), shifted to follow on from there over a
    /// closed gap, skipped if its audio ends before that frame, decoded to find where its audio ends. Also the spans of
    /// the segments that could not be read, from where reading stopped.
    private static func place(
        _ segments: [Segment], origin: HostTime, channels: Int, cancelled: CancellationFlag
    ) throws -> (placed: [Placed], missing: [MissingSpan]) {
        var placed: [Placed] = []
        var missing: [MissingSpan] = []
        // Where the audio placed last ended, and where the next segment's reading begins.
        var lastAudioEnd: Int64?
        var reading: Int64 = 0
        for var segment in segments {
            if cancelled.isCancelled { throw ExportError.cancelled }
            if let end = lastAudioEnd {
                let gap = segment.map.output(atDecoded: 0) - Double(end)
                if abs(gap) <= maxClosedGap * sampleRate { segment.map.shift(by: -gap) }
            }
            if let frames = segment.frames, segment.map.output(atDecoded: frames) <= Double(reading) { continue }
            let decoded: (frames: Int64, failure: String?, seekOrigin: CMTime?, tail: [Float])
            do {
                decoded = try SegmentDecoder.length(of: segment, channels: channels, cancelled: cancelled)
            } catch ExportError.cancelled {
                throw ExportError.cancelled
            } catch {
                logger.error("Audio segment \(segment.file, privacy: .public): cannot be read (\(String(describing: error), privacy: .public)); exporting silence")
                missing.append(MissingSpan(file: segment.file, start: segment.start, end: segment.end, reason: .cannotOpen(String(describing: error))))
                continue
            }
            let start = max(reading, Int64(segment.map.output(atDecoded: 0).rounded(.up)))
            let end = audioEnd(of: segment.map, decodedFrames: decoded.frames, from: start)
            placed.append(Placed(
                segment: segment, start: start, end: end, seekOrigin: decoded.seekOrigin, decodedFrames: decoded.frames,
                tail: decoded.seekOrigin == nil ? [] : decoded.tail))
            if let failure = decoded.failure {
                missing.append(MissingSpan(
                    file: segment.file, start: origin.adding(seconds: Double(end) / sampleRate), end: segment.end,
                    reason: .readFailed(failure)))
            }
            lastAudioEnd = end
            reading = end
        }
        return (placed, missing)
    }

    /// The first timeline frame from `start` on where `map` shows no decoded frame of the `decodedFrames` there are:
    /// where a reader of the segment, reading in order from `start`, runs out (`SegmentReader.read`).
    static func audioEnd(of map: ClockMap, decodedFrames: Int64, from start: Int64) -> Int64 {
        func runsOut(_ frame: Int64) -> Bool {
            max(0, map.decoded(atOutput: Double(frame))).rounded(.down) >= Double(decodedFrames)
        }
        // From where the last frame goes, the first frame there or next to it.
        var frame = max(start, Int64(map.output(atDecoded: Double(decodedFrames)).rounded(.up)))
        while frame > start, runsOut(frame - 1) { frame -= 1 }
        while !runsOut(frame) { frame += 1 }
        return frame
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

    private init(track: String, channels: Int, placed: [Placed], missing: [MissingSpan]) {
        self.track = track
        self.channels = channels
        self.placed = placed
        self.missing = missing
    }

    /// The clean voice of `dry` (`soundIsolation-2`, plan decision 14) as a stream of its own with `channels` channels:
    /// the same `placed` as `dry`, each segment reading its clean file of `files` (by `SegmentRecord.file`) frame for
    /// frame from where the segment is heard (a map that is the identity from `placed.start`, the file at 48 kHz read
    /// from anywhere, `decodedFrames` its length), so it plays over exactly the frames the dry sound plays. A file is
    /// used only if it is a regular file (by `lstat`: a link is never followed) of mono Float32 LPCM at 48 kHz with
    /// exactly its span's frames; `nil` if a segment that is heard has no such file. Opens the files, never decodes them.
    static func cleaned(_ dry: AudioTrackTimeline, files: [String: URL], channels: Int) async -> AudioTrackTimeline? {
        precondition(channels == 1 || channels == 2, "AudioTrackTimeline: \(channels) channels")
        var placed: [Placed] = []
        for heard in dry.placed {
            let frames = heard.end - heard.start
            guard let url = files[heard.segment.file], isCleanFile(url, frames: frames) else { return nil }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
            // Decoded frame 0 at timeline frame `heard.start`, one for one.
            var map = ClockMap(
                start: HostTime(nanoseconds: 0), anchors: [], sourceRate: sampleRate, timelineStart: HostTime(nanoseconds: 0),
                outputRate: sampleRate)
            map.shift(by: Double(heard.start))
            let segment = Segment(
                file: url.lastPathComponent, asset: asset, track: track, map: map, channels: 1, sourceRate: sampleRate,
                frames: Double(frames), start: heard.segment.start, end: heard.segment.end)
            placed.append(Placed(
                segment: segment, start: heard.start, end: heard.end, seekOrigin: CMTime.zero, decodedFrames: frames, tail: []))
        }
        return AudioTrackTimeline(track: dry.track, channels: channels, placed: placed, missing: [])
    }

    /// Whether `url` is a regular file (never a link) of mono Float32 LPCM at 48 kHz, `frames` frames long.
    private static func isCleanFile(_ url: URL, frames: Int64) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        else { return false }
        let format = file.fileFormat
        return format.commonFormat == .pcmFormatFloat32 && format.sampleRate == sampleRate && format.channelCount == 1
            && file.length == frames
    }

    /// Reads ranges of the stream, from anywhere: the reader of the segment being read is kept while the ranges go
    /// forward and stay within `readAhead` of what it holds; otherwise the segment is opened again, near the range when
    /// it can be (`seekPreroll`), from its start when not. A range is the same however it is reached.
    ///
    /// Not thread-safe: one owner reads it, from one thread at a time.
    final class Reader {
        let timeline: AudioTrackTimeline
        /// The reader open, of `timeline.placed[segment]`.
        private var active: (segment: Int, reader: SegmentReader)?
        /// The decoded frame the last reader opened started its file at, for the tests.
        private(set) var lastOpening: Int64?

        init(_ timeline: AudioTrackTimeline) {
            self.timeline = timeline
        }

        /// Reads timeline frames `frames` into `samples`, which then holds exactly `frames.count × channels` values,
        /// interleaved: zeros where there is no audio (gaps, before the first segment, after the last).
        func read(_ frames: Range<Int64>, into samples: inout [Float]) {
            let channels = timeline.channels
            samples.removeAll(keepingCapacity: true)
            samples.append(contentsOf: repeatElement(0, count: frames.count * channels))
            let placed = timeline.placed
            // The first segment whose audio ends after the range starts.
            var low = 0, high = placed.count
            while low < high {
                let middle = (low + high) / 2
                if placed[middle].end <= frames.lowerBound { low = middle + 1 } else { high = middle }
            }
            var k = low
            while k < placed.count, placed[k].start < frames.upperBound {
                let from = max(frames.lowerBound, placed[k].start), to = min(frames.upperBound, placed[k].end)
                if from < to, let reader = reader(of: k, from: from) {
                    var frame = from
                    while frame < to, reader.read(frame: frame, into: &samples, at: Int(frame - frames.lowerBound) * channels) {
                        frame += 1
                    }
                }
                k += 1
            }
        }

        /// A reader of segment `k` that can read on from `frame`: the one already open if it has not read past it and
        /// the frame is not far ahead of it, otherwise a new one; `nil` if the segment's file can no longer be read.
        private func reader(of k: Int, from frame: Int64) -> SegmentReader? {
            let placed = timeline.placed[k]
            let needed = Int64(max(0, placed.segment.map.decoded(atOutput: Double(frame))).rounded(.down))
            if let active, active.segment == k, active.reader.canRead(from: frame),
               placed.seekOrigin == nil || needed < active.reader.decodedEnd + AudioTrackTimeline.readAhead {
                return active.reader
            }
            active = nil
            do {
                let reader = try SegmentReader(placed, channels: timeline.channels, near: needed)
                active = (k, reader)
                lastOpening = reader.opening
                return reader
            } catch {
                AudioTrackTimeline.logger.error(
                    "Audio segment \(self.timeline.placed[k].segment.file, privacy: .public): cannot be read again (\(String(describing: error), privacy: .public)); silence")
                return nil
            }
        }
    }
}

/// Runs `body` on a thread of its own once one of the process's decoding slots is free (`DecodingSlots.shared`), and
/// waits for it without holding a thread of Swift's cooperative pool: decoding blocks in `copyNextSampleBuffer` until
/// AVFoundation's own reads finish, and those reads never run with every thread of the pool blocked that way, nor with
/// too many readers pulled at once from threads of their own.
/// - Throws: what `body` throws, or `CancellationError` if the task is cancelled while it waits for a slot.
func offTheCooperativePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await DecodingSlots.shared.run(label: "dev.toma.AudioDecoding", body)
}

/// Set once its task is cancelled, for work that runs off the task.
final class CancellationFlag: Sendable {
    private let flag = Atomic(false)
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func cancel() { flag.store(true, ordering: .relaxed) }
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

    /// `decoded(atOutput:interval:)` with the interval found from the first knot: the same value as when it is walked
    /// to in order.
    func decoded(atOutput output: Double) -> Double {
        var k = 0
        return decoded(atOutput: output, interval: &k)
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

/// Decodes one segment's file in order, to interleaved Float32 at the output rate mixed to the stream's channels.
private final class SegmentDecoder {
    /// Why reading stopped before the end of the file, if it did.
    private(set) var failure: String?
    /// The presentation time of the frames `next()` gave last.
    private(set) var time = CMTime.invalid

    /// `SegmentRecord.file`, for the log.
    private let file: String
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    /// Channels of the stream (what `next()` gives) and of the file.
    private let channels: Int
    private let sourceChannels: Int
    private var finished = false

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    /// A decoder of `segment`'s file from its start, or from presentation time `start`.
    init(_ segment: AudioTrackTimeline.Segment, channels: Int, from start: CMTime? = nil) throws {
        file = segment.file
        self.channels = channels
        sourceChannels = segment.channels
        reader = try AVAssetReader(asset: segment.asset)
        if let start { reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity) }
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

    /// The decoded frames of `segment`, as a reader gets them, and why reading stopped early if it did; the
    /// presentation time of decoded frame 0 when a reader can start the file at any point of its `seekGrid`: every
    /// block's timestamp is the first one's plus the frames before it, and the file is at 48 kHz, or, resampled, a
    /// reader started on the grid in its middle gives what this one does there (`AudioTrackTimeline.startsExactly`);
    /// and the last `tailFrames` frames.
    /// - Throws: what opening the file throws, or `ExportError.cancelled` once `cancelled` is set.
    static func length(
        of segment: AudioTrackTimeline.Segment, channels: Int, cancelled: CancellationFlag
    ) throws -> (frames: Int64, failure: String?, seekOrigin: CMTime?, tail: [Float]) {
        let decoder = try SegmentDecoder(segment, channels: channels)
        let rate = CMTimeScale(AudioTrackTimeline.sampleRate)
        let grid = AudioTrackTimeline.seekGrid(sourceRate: segment.sourceRate)
        let resampled = segment.sourceRate != AudioTrackTimeline.sampleRate
        // For a resampled file, where in its middle a reader is started to compare, and what this one decodes there.
        var check: (start: Int64, frames: Range<Int64>)?
        if resampled, let grid, let length = segment.frames, length.isFinite, length < 1e15 {
            let start = Int64(length / 2) / grid.decoded * grid.decoded
            if start > 0 { check = (start, AudioTrackTimeline.seekCheck(at: start)) }
        }
        var reference: [Float] = []
        var tail: [Float] = []
        let tailSamples = Int(AudioTrackTimeline.tailFrames) * channels
        var frames: Int64 = 0
        var origin: CMTime?
        var onTime = grid != nil && (!resampled || check != nil)
        while let block = decoder.next() {
            if cancelled.isCancelled { throw ExportError.cancelled }
            let first = origin ?? decoder.time
            origin = first
            onTime = onTime && first.isNumeric && CMTimeCompare(decoder.time, CMTimeAdd(first, CMTime(value: frames, timescale: rate))) == 0
            let count = Int64(block.count / channels)
            if let compared = check?.frames {
                let kept = (frames..<(frames + count)).clamped(to: compared)
                if !kept.isEmpty { reference += block[(Int(kept.lowerBound - frames) * channels)..<(Int(kept.upperBound - frames) * channels)] }
            }
            frames += count
            tail += block
            if tail.count > 2 * tailSamples { tail.removeFirst(tail.count - tailSamples) }
        }
        if tail.count > tailSamples { tail.removeFirst(tail.count - tailSamples) }
        if onTime, let check, let first = origin {
            // Why a reader cannot start it in the middle, if it cannot: each seek then decodes it from its start.
            let reason: String?
            if Int64(reference.count / channels) != Int64(check.frames.count) {
                reason = "it ended before the frames compared"
            } else {
                do {
                    let exact = try AudioTrackTimeline.startsExactly(segment, channels: channels, origin: first, at: check.start, reference: reference)
                    reason = exact ? nil : "started at frame \(check.start), the resampler gave other samples"
                } catch {
                    reason = "starting it at frame \(check.start) failed (\(String(describing: error)))"
                }
            }
            if let reason {
                onTime = false
                logger.info("Audio segment \(segment.file, privacy: .public) at \(segment.sourceRate, privacy: .public) Hz: \(reason, privacy: .public); each seek decodes it from its start")
            }
        }
        return (frames, decoder.failure, onTime ? origin : nil, tail)
    }

    /// Decoded frames `range`, interleaved, of a decoder whose first frame is decoded frame `first`, decoding on to them
    /// from where it is; `nil` if the file ends or reading stops before their end, or if `time` is given and its first
    /// frames do not come at it.
    func frames(_ range: Range<Int64>, decodedFrom first: Int64, at time: CMTime? = nil) -> [Float]? {
        var frames: [Float] = []
        var position = first
        var checked = time == nil
        while position < range.upperBound, let block = next() {
            if !checked {
                guard let time, CMTimeCompare(self.time, time) == 0 else { return nil }
                checked = true
            }
            let count = Int64(block.count / channels)
            let kept = (position..<(position + count)).clamped(to: range)
            if !kept.isEmpty { frames += block[(Int(kept.lowerBound - position) * channels)..<(Int(kept.upperBound - position) * channels)] }
            position += count
        }
        return position >= range.upperBound ? frames : nil
    }

    /// The next decoded frames, interleaved with the stream's channels; `nil` once the file is read to its end or
    /// reading stopped (`failure` says why).
    func next() -> [Float]? {
        while !finished {
            guard let sample = output.copyNextSampleBuffer() else {
                finished = true
                if reader.status == .failed {
                    let error = reader.error.map { String(describing: $0) } ?? "the reader failed"
                    failure = error
                    Self.logger.error("Audio segment \(self.file, privacy: .public): reading stopped (\(error, privacy: .public)); silence after it")
                }
                return nil
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            time = sample.presentationTimeStamp
            var decoded = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
            let status = decoded.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            guard status == noErr else {
                finished = true
                failure = "cannot copy decoded audio (OSStatus \(status))"
                Self.logger.error("Audio segment \(self.file, privacy: .public): cannot copy decoded audio (OSStatus \(status)); silence after it")
                return nil
            }
            if sourceChannels == channels { return decoded }
            // Mono to both channels, or every channel at unity gain into each, clipped.
            var mixed: [Float] = []
            mixed.reserveCapacity(decoded.count / sourceChannels * channels)
            for frame in stride(from: 0, to: decoded.count - sourceChannels + 1, by: sourceChannels) {
                var sum: Float = 0
                for c in 0..<sourceChannels { sum += decoded[frame + c] }
                let value = min(max(sum, -1), 1)
                for _ in 0..<channels { mixed.append(value) }
            }
            return mixed
        }
        return nil
    }
}

/// Reads one segment's frames forward, decoded by a `SegmentDecoder`, and resamples them onto timeline frames through
/// its clock map (linear interpolation).
private final class SegmentReader {
    /// The decoded frame the file was started at: 0, or the point of its `seekGrid` at least `seekPreroll` before the
    /// one first needed.
    let opening: Int64

    private let decoder: SegmentDecoder
    private let map: ClockMap
    /// The interval of `map` the last frame read was in.
    private var knot = 0
    /// Channels of the stream: what `buffer` holds.
    private let channels: Int
    /// Decoded frames held, interleaved, from decoded frame `bufferStart`.
    private var buffer: [Float] = []
    private var bufferStart: Int64
    /// The frames a reader from the file's start decodes: none is held past them.
    private let decodedFrames: Int64
    /// The last of those frames, interleaved, from decoded frame `tailStart`.
    private let tail: [Float]
    private let tailStart: Int64
    /// The last timeline frame read: the reader only goes forward from it.
    private var lastFrame = Int64.min

    /// A reader of `placed` whose first frame read needs decoded frame `needed`: it starts the file at the last point
    /// of its `seekGrid` at least `seekPreroll` frames before it when `placed.seekOrigin` lets it and the first frames
    /// come at the time asked for, from its start otherwise.
    init(_ placed: AudioTrackTimeline.Placed, channels: Int, near needed: Int64) throws {
        map = placed.segment.map
        self.channels = channels
        decodedFrames = placed.decodedFrames
        tail = placed.tail
        tailStart = placed.decodedFrames - Int64(placed.tail.count / channels)
        let step = AudioTrackTimeline.seekGrid(sourceRate: placed.segment.sourceRate)?.decoded ?? 1
        let start = max(0, needed - AudioTrackTimeline.seekPreroll) / step * step
        if let origin = placed.seekOrigin, start > 0 {
            let time = AudioTrackTimeline.time(ofDecoded: start, origin: origin, sourceRate: placed.segment.sourceRate)
            let decoder = try SegmentDecoder(placed.segment, channels: channels, from: time)
            if let first = decoder.next(), CMTimeCompare(decoder.time, time) == 0 {
                self.decoder = decoder
                bufferStart = start
                opening = start
                hold(first)
                return
            }
        }
        decoder = try SegmentDecoder(placed.segment, channels: channels)
        bufferStart = 0
        opening = 0
    }

    /// One past the last decoded frame held.
    var decodedEnd: Int64 { bufferEnd }

    /// Whether timeline frame `frame` can be read: none before the last one read.
    func canRead(from frame: Int64) -> Bool {
        frame >= lastFrame
    }

    /// Writes the segment's sound at timeline frame `frame` into `samples` at `offset`. Returns false, writing nothing,
    /// once the segment has no frame there: it has ended.
    /// - Precondition: `canRead(from: frame)`.
    func read(frame: Int64, into samples: inout [Float], at offset: Int) -> Bool {
        precondition(canRead(from: frame), "SegmentReader: frame \(frame) is before \(lastFrame)")
        lastFrame = frame
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
        while frame >= bufferEnd, bufferEnd < decodedFrames {
            discard(before: keep)
            guard let decoded = decoder.next() else {
                // Started in the middle, a resampled file can end a few frames early: the rest as from the start.
                if bufferEnd >= tailStart { buffer += tail[(Int(bufferEnd - tailStart) * channels)...] }
                break
            }
            hold(decoded)
        }
        return frame >= bufferStart && frame < bufferEnd
    }

    /// Holds `decoded`, the frames from `bufferEnd` on, up to `decodedFrames`.
    private func hold(_ decoded: [Float]) {
        let room = Int(max(0, decodedFrames - bufferEnd)) * channels
        buffer += decoded.count > room ? decoded[..<room] : decoded[...]
    }

    /// Drops the held frames before `frame` once there are many of them.
    private func discard(before frame: Int64) {
        let stale = min(frame - bufferStart, Int64(buffer.count / channels))
        guard stale > 8192 else { return }
        buffer.removeFirst(Int(stale) * channels)
        bufferStart += stale
    }
}
