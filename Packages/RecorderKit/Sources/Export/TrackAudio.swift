// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// One segment of an audio track as it is heard: its file, and the timeline frames its audio is on (`TrackAudio`).
public struct TrackAudioSpan: Equatable, Sendable {
    /// `SegmentRecord.file`.
    public var segment: String
    /// Timeline frames, at 48 kHz from `TrackAudio.origin`: the segments that are heard never overlap.
    public var frames: Range<Int64>

    public init(segment: String, frames: Range<Int64>) {
        self.segment = segment
        self.frames = frames
    }
}

/// Why `TrackAudio.load` loaded nothing.
public enum TrackAudioError: Error, Equatable {
    /// The take has no microphone, system audio or device audio track of this ID.
    case noAudioTrack(String)
}

/// One audio track of a take, a microphone, system audio or a device's audio, as the analysis of phase 2 reads it (the
/// transcription, the cleanup, the loudness, the silences): one stream of 48 kHz Float32 PCM on the take's timeline,
/// frame 0 at host time `origin` (`TakeTimeline.bounds`), placed exactly where `EditedMix` places it, so what the
/// analysis finds at a frame is what the mix plays from there. A public front of the export's own `AudioTrackTimeline`.
///
/// `load` decodes every segment that is heard once, to its end, to find where its audio ends; the stream is then read
/// in ranges, from anywhere, by a reader (`makeReader`), never the whole take at once.
public final class TrackAudio: Sendable {
    public static let sampleRate = AudioTrackTimeline.sampleRate

    /// The track's ID (`TrackRecord.id`).
    public let track: String
    /// Channels of the stream (1 or 2), what a reader interleaves.
    public let channels: Int
    /// Host time of timeline frame 0: the start of the take's timeline, as in the mix.
    public let origin: HostTime
    /// The segments that are heard, in order (the timeline's `placed`): between them, before the first and after the
    /// last, the stream is silence.
    public let spans: [TrackAudioSpan]
    /// The timeline frame of the end of what a document can show of the take (`TakeTimeline.editableBounds`): past it,
    /// no document plays the track.
    let endFrame: Int64
    let timeline: AudioTrackTimeline

    private init(timeline: AudioTrackTimeline, origin: HostTime, endFrame: Int64) {
        self.timeline = timeline
        track = timeline.track
        channels = timeline.channels
        self.origin = origin
        self.endFrame = endFrame
        spans = timeline.placed.map { TrackAudioSpan(segment: $0.segment.file, frames: $0.start..<$0.end) }
    }

    /// Track `track` of `project`, with `channels` channels (1 or 2; `nil`, what the track needs: 2 if any of its
    /// segments is not mono), on the timeline of the mix. Opens its segments and decodes those that are heard to their
    /// end, on a thread of its own, never on Swift's cooperative pool.
    /// - Precondition: `channels` is `nil`, 1 or 2.
    /// - Throws: `TrackAudioError.noAudioTrack` if the take has no audio track `track`; `CancellationError` if the task
    ///   is cancelled while loading.
    public static func load(_ project: LoadedProject, track: String, channels: Int? = nil) async throws -> TrackAudio {
        precondition(channels.map { $0 == 1 || $0 == 2 } ?? true, "TrackAudio: \(channels ?? 0) channels")
        guard let record = project.take.tracks.first(where: { $0.id == track && !$0.kind.isVideo }) else {
            throw TrackAudioError.noAudioTrack(track)
        }
        try Task.checkCancellation()
        let events = project.events
        let origin = TakeTimeline.bounds(take: project.take, events: events).start
        let end = TakeTimeline.editableBounds(take: project.take, events: events).end
        let count: Int
        if let channels { count = channels } else { count = await AudioTrackTimeline.channelCount(of: record, in: project) }
        let timeline: AudioTrackTimeline
        do {
            timeline = try await AudioTrackTimeline.load(project, track: record, origin: origin, channels: count)
        } catch ExportError.cancelled {
            throw CancellationError()
        }
        let endFrame = EditedMix.frames(ofNanoseconds: end >= origin ? Int64(clamping: end.nanoseconds - origin.nanoseconds) : 0)
        return TrackAudio(timeline: timeline, origin: origin, endFrame: endFrame)
    }

    /// The host time of timeline frame `frame`: `origin` plus `frame / 48 000` s, to the nearest nanosecond.
    public func host(atFrame frame: Int64) -> HostTime {
        // 10⁹ / 48 000 = 62 500 / 3 ns a frame; n / 3 to the nearest is (n + 1) / 3 rounded towards 0, never a half.
        let (scaled, overflow) = frame.multipliedReportingOverflow(by: 62_500)
        if overflow { return origin.adding(seconds: Double(frame) / Self.sampleRate) }
        let offset = scaled >= 0 ? (scaled + 1) / 3 : -((-scaled + 1) / 3)
        if offset >= 0 {
            let (sum, past) = origin.nanoseconds.addingReportingOverflow(UInt64(offset))
            return HostTime(nanoseconds: past ? .max : sum)
        }
        let back = UInt64(-offset)
        return HostTime(nanoseconds: origin.nanoseconds > back ? origin.nanoseconds - back : 0)
    }

    /// A reader of the stream, of its own: one for each thread that reads.
    public func makeReader() -> TrackAudioReader {
        TrackAudioReader(AudioTrackTimeline.Reader(timeline))
    }
}

/// Reads ranges of a `TrackAudio`'s stream, from anywhere; a range is the same however it is reached. It decodes as it
/// goes, blocking in `AVAssetReader` until AVFoundation's own reads finish: read it from a thread or queue of its own,
/// never from Swift's cooperative pool nor from the main thread.
///
/// Not thread-safe: one owner reads it, from one thread at a time (as `AudioTrackTimeline.Reader`).
public final class TrackAudioReader {
    private let reader: AudioTrackTimeline.Reader

    init(_ reader: AudioTrackTimeline.Reader) {
        self.reader = reader
    }

    /// Reads timeline frames `frames` into `samples`, which then holds exactly `frames.count × channels` values,
    /// interleaved: zeros where there is no audio (between the spans, before the first, after the last).
    public func read(_ frames: Range<Int64>, into samples: inout [Float]) {
        reader.read(frames, into: &samples)
    }
}
