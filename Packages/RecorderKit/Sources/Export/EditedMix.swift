// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Synchronization

/// The sound of an edit document, at 48 kHz: the one mix of the export and of the preview (design §7.7).
///
/// For each clip, every audio track reads the range of the source the clip keeps (each placed by host time with its own
/// `audioClock` anchors, `AudioTrackTimeline`), at its gain from `audio.tracks` (0 to 2, 0 when muted, 1 for a track the
/// plan does not name); the tracks are added together with the click sounds, go through the limiter when
/// `audio.limiter` is on, and are clipped to [−1, 1]. The mix is mono if every track is, stereo otherwise.
///
/// - Clip `k` is output frames `round(O_k × 48 000 / 10⁹) ..< round(O_{k+1} × 48 000 / 10⁹)` (`TimeMap`'s starts, the
///   last clip ending at `round(D × 48 000 / 10⁹)`, where the content ends), reading the source from the frame of its
///   start, `round((s_k − origin) × 48 000 / 10⁹)`, with `origin` the take's timeline start (`TakeTimeline.bounds`).
/// - Between two clips the one before fades out over its last 192 frames (4 ms) and the one after fades in over its
///   first 192, linearly; the output never fades at its start or its end (plan decision 7), so the legacy document,
///   one clip, mixes the samples the export always did.
/// - A clip at another speed than 1, or of another take, is silent (plan decision 21: until its audio is stretched).
/// - A click sound (`cursor.clickSound`, `ClickSounds`) plays at `clickSoundGain` from the output frame of every left
///   or right `mouseDown` the clips keep; one less than `ClickSounds.minimumSpacing` after the last that sounded does
///   not sound.
/// - The mix lasts `totalFrames`, what the video lasts at its frame rate (`totalFrames(frameCount:framesPerSecond:)`):
///   past the content, silence; before its end, the content is cut.
///
/// A range of the mix is the same whatever was rendered before it. With the limiter, whose gain depends on the frames
/// before, a range that does not follow on from the one rendered last starts the limiter over there, so the same
/// ranges asked for in the same order give the same bits. `render` holds a lock while it mixes (its readers and its
/// limiter have state): calls take turns, and the export and the preview each have a mix of their own.
public final class EditedMix: Sendable {
    /// 1 or 2.
    public let channels: Int
    /// Length of the mix, in frames.
    public let totalFrames: Int64
    /// The frames the document's clips last: `round(D × 48 000 / 10⁹)`. Silence from there on.
    let contentFrames: Int64
    /// The source, shared with the mixes of other revisions (`with(document:framesPerSecond:)`).
    let source: Source
    /// The segments this mix decoded to find where their audio ends: none for one made by `with(document:framesPerSecond:)`.
    let prereadSegments: Int

    /// The clips with any output, in order.
    private let pieces: [Piece]
    /// The gain of each of `source.tracks`.
    private let gains: [Float]
    /// The output frames the click sound starts at, in order, and the sound at its gain.
    private let clickFrames: [Int64]
    private let clickSound: [Float]
    private let limited: Bool
    private let missing: [MissingAudio]
    private let state: Mutex<State>

    /// What the mixes of every revision of a project's document share: the take's audio tracks, read and placed once.
    final class Source: Sendable {
        let takeID: String
        /// Frame 0 of the tracks' timeline: the take's timeline start, where its legacy document starts.
        let origin: HostTime
        let channels: Int
        /// Every microphone and system audio track of the take, in the take's order.
        let tracks: [AudioTrackTimeline]
        /// `AudioPlan.key` of each of `tracks`.
        let keys: [String]
        /// The host times of the take's left and right `mouseDown`s, in order.
        let clicks: [HostTime]

        init(takeID: String, origin: HostTime, channels: Int, tracks: [AudioTrackTimeline], clicks: [HostTime]) {
            self.takeID = takeID
            self.origin = origin
            self.channels = channels
            self.tracks = tracks
            keys = tracks.map { AudioPlan.key(take: takeID, track: $0.track) }
            self.clicks = clicks
        }
    }

    /// One clip as the mix plays it: output frames `start ..< end`, reading the tracks' timeline from `source` (`nil`
    /// when it is silent), fading in at its start and out at its end when another clip is there.
    private struct Piece: Sendable {
        var start: Int64
        var end: Int64
        var source: Int64?
        var fadesIn: Bool
        var fadesOut: Bool

        /// The fade at output frame `frame` of the clip: 1 out of the fades, from 0 at the clip's edge up to 191/192.
        func fade(at frame: Int64) -> Float {
            var fade: Float = 1
            if fadesIn, frame - start < EditedMix.fadeFrames { fade = Float(frame - start) / Float(EditedMix.fadeFrames) }
            if fadesOut, end - 1 - frame < EditedMix.fadeFrames { fade = min(fade, Float(end - 1 - frame) / Float(EditedMix.fadeFrames)) }
            return fade
        }
    }

    /// What `render` changes: each track's reader, and the limiter with the output frame it gives next.
    private struct State {
        var readers: [AudioTrackTimeline.Reader]
        var limiter: PeakLimiter
        var limiterNext: Int64?
        /// One track's frames of the range being mixed.
        var track: [Float] = []
    }

    /// 4 ms at 48 kHz: the fades between two clips.
    static let fadeFrames: Int64 = 192

    /// The mix of `document` of `project` at `framesPerSecond`: reads every microphone and system audio track of the take
    /// (opening its segments and decoding them once, off Swift's cooperative pool, to find where each one's audio ends).
    /// - Precondition: `framesPerSecond` is positive.
    /// - Throws: `ExportError.cancelled` if the task is cancelled while reading.
    public static func make(project: LoadedProject, document: EditDocument, framesPerSecond: Int) async throws -> EditedMix {
        let tracks = project.take.tracks.filter { !$0.kind.isVideo }
        var channels = 1
        for track in tracks { channels = max(channels, await AudioTrackTimeline.channelCount(of: track, in: project)) }
        let origin = TakeTimeline.bounds(take: project.take, events: project.events).start
        var timelines: [AudioTrackTimeline] = []
        for track in tracks {
            timelines.append(try await AudioTrackTimeline.load(project, track: track, origin: origin, channels: channels))
        }
        let clicks = project.events.sortedByTime().compactMap { event -> HostTime? in
            guard case .mouseDown(let button, _, _) = event.kind, button == .left || button == .right else { return nil }
            return event.t
        }
        let source = Source(takeID: project.take.id, origin: origin, channels: channels, tracks: timelines, clicks: clicks)
        return EditedMix(source: source, document: document, framesPerSecond: framesPerSecond, prereadSegments: timelines.reduce(0) {
            $0 + $1.decodedSegments
        })
    }

    /// The mix of another revision of the document, `document` at `framesPerSecond`, of the same project: it reads the
    /// same source, without decoding it again to place it.
    /// - Precondition: `framesPerSecond` is positive.
    public func with(document: EditDocument, framesPerSecond: Int) -> EditedMix {
        EditedMix(source: source, document: document, framesPerSecond: framesPerSecond, prereadSegments: 0)
    }

    private init(source: Source, document: EditDocument, framesPerSecond: Int, prereadSegments: Int) {
        precondition(framesPerSecond > 0, "EditedMix: \(framesPerSecond) frames per second")
        self.source = source
        self.prereadSegments = prereadSegments
        channels = source.channels
        let timeMap = TimeMap(sequence: document.sequence)
        totalFrames = Self.totalFrames(frameCount: timeMap.frameCount(frameRate: framesPerSecond), framesPerSecond: framesPerSecond)
        contentFrames = Self.frames(ofNanoseconds: timeMap.duration)
        pieces = Self.pieces(of: document.sequence, timeMap: timeMap, contentFrames: contentFrames, source: source)
        gains = source.keys.map { key in
            guard let plan = document.audio.tracks[key] else { return 1 }
            if plan.muted { return 0 }
            return plan.gain.isNaN ? 1 : Float(min(max(plan.gain, 0), 2))
        }
        let clickGain = document.cursor.clickSoundGain.isNaN ? 0 : Float(min(max(document.cursor.clickSoundGain, 0), 1))
        if let sound = ClickSounds.samples(document.cursor.clickSound), clickGain > 0 {
            clickSound = sound.map { $0 * clickGain }
            clickFrames = Self.clickFrames(of: source, timeMap: timeMap)
        } else {
            clickSound = []
            clickFrames = []
        }
        limited = document.audio.limiter
        missing = Self.missing(of: source, timeMap: timeMap, totalFrames: totalFrames)
        state = Mutex(State(readers: source.tracks.map(AudioTrackTimeline.Reader.init), limiter: PeakLimiter(channels: source.channels)))
    }

    /// The spans left silent, track by track, in output seconds within the mix (with the cuts in them closed): the
    /// segments that could not be opened, then where reading one stopped.
    public var missingAudio: [MissingAudio] { missing }

    /// Whether there is anything to hear: an audio track, or a click sound the clips keep. Without, the export has no audio.
    var hasSound: Bool { !source.tracks.isEmpty || !clickFrames.isEmpty }

    /// The frames of audio that `frameCount` frames of video at `fps` last: `round(frameCount / fps × 48 000)`.
    static func totalFrames(frameCount: Int, framesPerSecond fps: Int) -> Int64 {
        Int64((Double(frameCount) / Double(fps) * AudioTrackTimeline.sampleRate).rounded())
    }

    /// `round(ns × 48 000 / 10⁹)`, halves away from zero, in integers (exact for any `ns`).
    static func frames(ofNanoseconds ns: Int64) -> Int64 {
        // 48 000 / 10⁹ = 6 / 125 000.
        let (whole, part) = ns.quotientAndRemainder(dividingBy: 125_000)
        let sixths = part * 6
        let rounded = sixths >= 0 ? (sixths + 62_500) / 125_000 : -((-sixths + 62_500) / 125_000)
        return whole * 6 + rounded
    }

    /// Writes output frames `outputFrames` of the mix into `samples`, which then holds exactly
    /// `outputFrames.count × channels` values, interleaved: silence outside `0 ..< totalFrames` and past the content.
    public func render(outputFrames: Range<Int64>, into samples: inout [Float]) {
        let count = outputFrames.count
        state.withLock { state in
            if limited {
                // The limiter gives each frame `lookaheadFrames` after it took it: it takes the frames that far ahead.
                let lookahead = Int64(PeakLimiter.lookaheadFrames)
                if state.limiterNext != outputFrames.lowerBound {
                    state.limiter = PeakLimiter(channels: channels)
                    var ahead: [Float] = []
                    mix(outputFrames.lowerBound..<(outputFrames.lowerBound + lookahead), into: &ahead, state: &state)
                    state.limiter.process(&ahead)
                }
                mix((outputFrames.lowerBound + lookahead)..<(outputFrames.upperBound + lookahead), into: &samples, state: &state)
                state.limiter.process(&samples)
                state.limiterNext = outputFrames.upperBound
            } else {
                mix(outputFrames, into: &samples, state: &state)
            }
        }
        precondition(samples.count == count * channels, "EditedMix: \(samples.count) samples for \(count) frames")
        for i in samples.indices { samples[i] = min(max(samples[i], -1), 1) }
    }

    /// The sum of the tracks and the click sounds over output frames `frames`, into `samples`, before the limiter.
    private func mix(_ frames: Range<Int64>, into samples: inout [Float], state: inout State) {
        samples.removeAll(keepingCapacity: true)
        samples.append(contentsOf: repeatElement(0, count: frames.count * channels))
        let heard = frames.clamped(to: 0..<max(0, min(contentFrames, totalFrames)))
        guard !heard.isEmpty else { return }
        var k = Self.first(in: pieces.count) { pieces[$0].end <= heard.lowerBound }
        while k < pieces.count, pieces[k].start < heard.upperBound {
            let piece = pieces[k]
            k += 1
            guard let source = piece.source else { continue }
            let from = max(heard.lowerBound, piece.start), to = min(heard.upperBound, piece.end)
            let read = (source + (from - piece.start))..<(source + (to - piece.start))
            for (t, reader) in state.readers.enumerated() where gains[t] != 0 {
                reader.read(read, into: &state.track)
                for frame in from..<to {
                    let gain = gains[t] * piece.fade(at: frame)
                    let input = Int(frame - from) * channels, output = Int(frame - frames.lowerBound) * channels
                    for c in 0..<channels { samples[output + c] += state.track[input + c] * gain }
                }
            }
        }
        guard !clickSound.isEmpty else { return }
        let length = Int64(clickSound.count)
        var c = Self.first(in: clickFrames.count) { clickFrames[$0] + length <= heard.lowerBound }
        while c < clickFrames.count, clickFrames[c] < heard.upperBound {
            let start = clickFrames[c]
            c += 1
            for frame in max(start, heard.lowerBound)..<min(start + length, heard.upperBound) {
                let value = clickSound[Int(frame - start)], output = Int(frame - frames.lowerBound) * channels
                for channel in 0..<channels { samples[output + channel] += value }
            }
        }
    }

    // MARK: - From the document

    /// The clips of `sequence` with any output frames, in order, as the mix plays them.
    private static func pieces(of sequence: [Clip], timeMap: TimeMap, contentFrames: Int64, source: Source) -> [Piece] {
        let starts = timeMap.clipOutputStarts.map(frames(ofNanoseconds:))
        var pieces: [Piece] = []
        for (k, clip) in sequence.enumerated() {
            let start = starts[k], end = k + 1 < starts.count ? starts[k + 1] : contentFrames
            guard start < end else { continue }
            // At 1× as `TimeMap` reads its speed (one that is not a number is 1).
            let atOneTimes = clip.speed.isNaN || clip.speed == 1
            let plays = clip.take == source.takeID && atOneTimes
            pieces.append(Piece(
                start: start, end: end, source: plays ? frames(ofNanoseconds: nanoseconds(from: source.origin, to: clip.start)) : nil,
                fadesIn: !pieces.isEmpty, fadesOut: false))
        }
        for k in pieces.indices.dropLast() { pieces[k].fadesOut = true }
        return pieces
    }

    /// The output frames where a click sounds: each kept `mouseDown` at its output time, unless it comes less than
    /// `ClickSounds.minimumSpacing` after the last that sounded.
    private static func clickFrames(of source: Source, timeMap: TimeMap) -> [Int64] {
        let times = source.clicks.compactMap { timeMap.output(atSource: $0, take: source.takeID) }.sorted()
        var frames: [Int64] = []
        var last: Int64?
        for time in times {
            if let last, time - last < ClickSounds.minimumSpacing { continue }
            last = time
            frames.append(Self.frames(ofNanoseconds: time))
        }
        return frames
    }

    /// The tracks' silent spans in output seconds, clamped to the mix: from the first instant kept in each to the end of
    /// the last (the cuts in it closed), to the end of the mix for one open to the end; none for a span all cut.
    private static func missing(of source: Source, timeMap: TimeMap, totalFrames: Int64) -> [MissingAudio] {
        let duration = Double(totalFrames) / AudioTrackTimeline.sampleRate
        return source.tracks.flatMap { track in
            track.missing.compactMap { span -> MissingAudio? in
                let start: Int64, end: Double
                if let spanEnd = span.end, span.start < spanEnd {
                    guard let range = timeMap.outputRange(ofSource: span.start..<spanEnd, take: source.takeID) else { return nil }
                    start = range.lowerBound
                    end = Double(range.upperBound) / 1e9
                } else {
                    guard let first = timeMap.firstKeptOutput(atOrAfter: span.start, take: source.takeID) else { return nil }
                    start = first
                    end = span.end == nil ? duration : Double(first) / 1e9
                }
                return AudioTrackTimeline.missingEntry(
                    track: track.track, file: span.file, start: Double(start) / 1e9, end: end, duration: duration, reason: span.reason)
            }
        }
    }

    /// `to − from` in nanoseconds, saturating at the ends of `Int64`.
    private static func nanoseconds(from: HostTime, to: HostTime) -> Int64 {
        to >= from ? Int64(clamping: to.nanoseconds - from.nanoseconds) : -Int64(clamping: from.nanoseconds - to.nanoseconds)
    }

    /// The first index in `0..<count` for which `isBefore` is false, given that it is true for a prefix and false after.
    private static func first(in count: Int, _ isBefore: (Int) -> Bool) -> Int {
        var (low, high) = (0, count)
        while low < high {
            let middle = low + (high - low) / 2
            if isBefore(middle) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
