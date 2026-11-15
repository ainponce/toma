// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat

/// The verdict on one track of a take.
public struct TrackVerification: Sendable {
    public var trackID: String
    /// Seconds of media that can be read, summed over the track's segments.
    public var seconds: Double
    /// `droppedFrames` summed over the track's segments, from the manifest.
    public var droppedFrames: Int
    public var ok: Bool
    /// Why the track failed (every reason, separated by "; "); `nil` when `ok`.
    public var reason: String?

    public init(trackID: String, seconds: Double, droppedFrames: Int, ok: Bool, reason: String? = nil) {
        self.trackID = trackID
        self.seconds = seconds
        self.droppedFrames = droppedFrames
        self.ok = ok
        self.reason = reason
    }
}

/// Checks that a take on disk is what a good recording looks like. Read-only.
public enum TakeVerifier {
    /// How far readable media may fall short of where it should end, in a take the recorder closed:
    /// it finished every file at the stop time.
    static let completeEndTolerance = 1.0
    /// The same in a take a crash left open (recovered or still `recording`): each track is readable up
    /// to its last complete fragment, so two healthy tracks can differ by up to a fragment, plus the
    /// one being written. Two of `FragmentedTrackWriter.defaultFragmentInterval` (1 s).
    static let openEndTolerance = 2.0
    /// The dropped frames of an audio track (a microphone or system audio) are 10 ms blocks, the block length
    /// of the synthetic audio sources.
    static let audioFramesPerSecond = 100.0

    /// Verifies every track of `project.take`, of every kind, in manifest order. A track passes when:
    ///
    /// - every segment file opens and has media of the track's kind (not missing, not empty), and its
    ///   readable media does not end more than the tolerance before the segment's `endHostTime`;
    /// - its readable media, summed over its segments, lasts at least `minDuration` seconds;
    /// - its readable media ends no more than the tolerance before the take's, which is the latest
    ///   readable end of any of its tracks;
    /// - with `maxDropRatio`, `droppedFrames / (frames + droppedFrames)` is at most `maxDropRatio`.
    ///   `frames` are the frames that were written: for a video track (a display, a window or a camera),
    ///   the video samples in its files (heartbeat repeats included); for an audio track (a microphone or
    ///   system audio), which drops 10 ms blocks, the readable seconds × 100. A real device's blocks are
    ///   longer than 10 ms, so its ratio reads low.
    ///
    /// The tolerance is 1 s for a `complete` take and 2 s for one a crash left open (`recovered` or
    /// still `recording`), whose tracks end at their last complete 1 s fragment.
    public static func verify(_ project: LoadedProject, minDuration: Double, maxDropRatio: Double?) async -> [TrackVerification] {
        let tolerance = project.take.status == .complete ? completeEndTolerance : openEndTolerance
        var measured: [Measurement] = []
        for track in project.take.tracks {
            measured.append(await measure(
                track, in: project.package, tolerance: tolerance, countingFrames: maxDropRatio != nil))
        }
        let takeEnd = measured.compactMap(\.end).max()
        return measured.map { track in
            var problems = track.problems
            if track.segments == 0 { problems.append("no segments") }
            if track.seconds < minDuration {
                problems.append("\(format(track.seconds)) s of readable media, minimum \(format(minDuration)) s")
            }
            if let takeEnd, let end = track.end, takeEnd.seconds(since: end) > tolerance {
                problems.append("ends \(format(takeEnd.seconds(since: end))) s before the end of the take")
            }
            if let maxDropRatio {
                let arrived = track.frames + Double(track.dropped)
                let ratio = arrived > 0 ? Double(track.dropped) / arrived : 0
                if ratio > maxDropRatio {
                    problems.append(
                        "dropped \(track.dropped) of \(Int(arrived.rounded())) frames "
                            + "(\(format(ratio * 100)) % > \(format(maxDropRatio * 100)) %)")
                }
            }
            return TrackVerification(
                trackID: track.id, seconds: track.seconds, droppedFrames: track.dropped, ok: problems.isEmpty,
                reason: problems.isEmpty ? nil : problems.joined(separator: "; "))
        }
    }

    private struct Measurement {
        var id: String
        var segments = 0
        var seconds = 0.0
        var dropped = 0
        var frames = 0.0
        /// Latest host time a segment's readable media reaches.
        var end: HostTime?
        var problems: [String] = []
    }

    private static func measure(
        _ track: TrackRecord, in package: ProjectPackage, tolerance: Double, countingFrames: Bool
    ) async -> Measurement {
        var result = Measurement(id: track.id, segments: track.segments.count)
        for segment in track.segments {
            result.dropped += segment.droppedFrames
            let name = (segment.file as NSString).lastPathComponent
            let file: SegmentMedia
            do {
                file = try await SegmentMedia.inspect(package.fileURL(segment.file), kind: track.kind)
            } catch {
                result.problems.append("\(name) cannot be opened: \(error.localizedDescription)")
                continue
            }
            switch file {
            case .missing:
                result.problems.append("\(name) is missing")
            case .empty:
                result.problems.append("\(name) is empty")
            case .unreadable(let bytes, let error):
                result.problems.append("\(name) (\(bytes) bytes) cannot be read: \(error.localizedDescription)")
            case .readable(let asset, let mediaTrack, let duration):
                let seconds = duration.seconds
                result.seconds += seconds
                let end = HostTime(nanoseconds: segment.startHostTime.nanoseconds + HostTime(duration).nanoseconds)
                result.end = max(result.end ?? end, end)
                if let recorded = segment.endHostTime, recorded.seconds(since: end) > tolerance {
                    result.problems.append(
                        "\(name) holds \(format(seconds)) s, \(format(recorded.seconds(since: end))) s less than "
                            + "the manifest says")
                }
                guard countingFrames else { continue }
                switch track.kind {
                case .display, .window, .camera:
                    do {
                        result.frames += Double(try countSamples(of: mediaTrack, in: asset))
                    } catch {
                        result.problems.append("\(name): frames cannot be counted: \(error.localizedDescription)")
                    }
                case .microphone, .systemAudio:
                    result.frames += seconds * audioFramesPerSecond
                }
            }
        }
        return result
    }

    /// The samples of `track`, read without decoding them.
    private static func countSamples(of track: AVAssetTrack, in asset: AVURLAsset) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VerificationError.readerRefusedTrack }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VerificationError.readerRefusedTrack }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sample)
        }
        if reader.status == .failed { throw reader.error ?? VerificationError.readerRefusedTrack }
        return count
    }

    private enum VerificationError: Error {
        case readerRefusedTrack
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
