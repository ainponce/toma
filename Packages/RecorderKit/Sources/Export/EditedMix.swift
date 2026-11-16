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
/// - Where two clips meet and the sound would jump (a cut, another take, another speed, or a clip that is silent), the
///   one before fades out over its last 192 frames (4 ms) and the one after fades in over its first 192, linearly. Where
///   the clip after goes on with the source of the one before (the same take and speed, its start the other's end, as
///   a clip split without a cut), there is no fade and the source is read on without a break: the mix is the clip's
///   unsplit. The output never fades at its start or its end (plan decision 7), so the legacy document, one clip, mixes
///   the samples the export always did.
/// - A clip at another speed than 1, up to 4×, plays its source stretched to the clip's frames with its pitch kept
///   (`SpeedStretch`), track by track before its gain: the clips of one take at one speed that go on one from the
///   other are stretched as one, from where they start. A clip faster than 4×, or of another take, is silent.
/// - A click sound (`cursor.clickSound`, `ClickSounds`) plays at `clickSoundGain` from the output frame of every left
///   or right `mouseDown` the clips keep; one less than `ClickSounds.minimumSpacing` after the last that sounded does
///   not sound.
/// - The mix lasts `totalFrames`, what the video lasts at its frame rate (`totalFrames(frameCount:framesPerSecond:)`):
///   past the content, silence; before its end, the content is cut.
///
/// A range of the mix is the same whatever was rendered before it, rendered without a preroll. With the limiter, whose
/// gain depends on the frames before, a range that does not follow on from the one rendered last starts a limiter
/// `PeakLimiter.settleFrames` before it (at frame 0, when that is closer), which by then gives what the limiter of a mix
/// played from the start does; a stretched clip is stretched from its start. `render` holds a lock while it mixes (its
/// readers, its stretches and its limiter have state): calls take turns, and the export and the preview each have a mix
/// of their own.
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
    /// The runs of clips the stretched pieces play.
    private let runs: [SpeedStretch.Run]
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

    /// One clip as the mix plays it: output frames `start ..< end` of `sound`, fading in at its start and out at its end
    /// where the sound jumps from or to another clip.
    private struct Piece: Sendable {
        var start: Int64
        var end: Int64
        var sound: Sound
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

    /// What a clip plays.
    private enum Sound: Equatable, Sendable {
        /// Nothing: a clip of another take, or faster than `SpeedStretch.maximumSpeed`.
        case silent
        /// At 1×: the tracks' timeline from this frame on, frame for frame.
        case source(Int64)
        /// At another speed: its frames of `runs[run]`, stretched.
        case stretched(run: Int)
    }

    /// What `render` changes: each track's reader and stretch, and the limiter with the output frame it gives next.
    private struct State {
        var readers: [AudioTrackTimeline.Reader]
        var stretches: [SpeedStretch]
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
        (pieces, runs) = Self.pieces(of: document.sequence, timeMap: timeMap, contentFrames: contentFrames, source: source)
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
        state = Mutex(State(
            readers: source.tracks.map(AudioTrackTimeline.Reader.init), stretches: source.tracks.map(SpeedStretch.init),
            limiter: PeakLimiter(channels: source.channels)))
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
    ///
    /// `preroll` is for a range that does not follow on from the one rendered last and starts in a stretched clip: with
    /// 0 (the export) its stretch starts from where the clip's run does, so the range is what it always is; with more
    /// (0.2 s in the preview after a jump) it starts that many seconds of output before the range, which is faster and
    /// can differ from the export in the first samples (design §7.7). A range that follows on goes on with the stretch
    /// under way, whatever `preroll` is; at 1× it changes nothing.
    ///
    /// It decodes the tracks as it goes, and blocks in `AVAssetReader` until AVFoundation's own reads finish: call it
    /// from a thread or queue of its own, never from Swift's cooperative pool (where enough callers at once would leave
    /// those reads no thread to run on) nor from the main thread.
    public func render(outputFrames: Range<Int64>, into samples: inout [Float], preroll: Double = 0) {
        let count = outputFrames.count
        // At most an hour, so the frames always fit; not a number, none.
        let prerollFrames = preroll > 0 ? Int64((min(preroll, 3_600) * AudioTrackTimeline.sampleRate).rounded()) : 0
        state.withLock { state in
            if limited {
                // The limiter gives each frame `lookaheadFrames` after it took it: it takes the frames that far ahead.
                let lookahead = Int64(PeakLimiter.lookaheadFrames)
                if state.limiterNext != outputFrames.lowerBound {
                    // A new limiter, given the frames before the range to settle on (from 0, where the whole mix starts it).
                    let start = outputFrames.lowerBound
                    let settling = min(start, max(0, start - Int64(PeakLimiter.settleFrames)))
                    state.limiter = PeakLimiter(channels: channels)
                    var before: [Float] = []
                    mix(settling..<(start + lookahead), preroll: prerollFrames, into: &before, state: &state)
                    state.limiter.process(&before)
                }
                let ahead = (outputFrames.lowerBound + lookahead)..<(outputFrames.upperBound + lookahead)
                mix(ahead, preroll: prerollFrames, into: &samples, state: &state)
                state.limiter.process(&samples)
                state.limiterNext = outputFrames.upperBound
            } else {
                mix(outputFrames, preroll: prerollFrames, into: &samples, state: &state)
            }
        }
        precondition(samples.count == count * channels, "EditedMix: \(samples.count) samples for \(count) frames")
        for i in samples.indices { samples[i] = min(max(samples[i], -1), 1) }
    }

    /// The sum of the tracks and the click sounds over output frames `frames`, into `samples`, before the limiter; a
    /// stretch that starts anew starts `preroll` frames before (0: at its run's start).
    private func mix(_ frames: Range<Int64>, preroll: Int64, into samples: inout [Float], state: inout State) {
        samples.removeAll(keepingCapacity: true)
        samples.append(contentsOf: repeatElement(0, count: frames.count * channels))
        let heard = frames.clamped(to: 0..<max(0, min(contentFrames, totalFrames)))
        guard !heard.isEmpty else { return }
        var k = Self.first(in: pieces.count) { pieces[$0].end <= heard.lowerBound }
        while k < pieces.count, pieces[k].start < heard.upperBound {
            let piece = pieces[k]
            k += 1
            guard piece.sound != .silent else { continue }
            let from = max(heard.lowerBound, piece.start), to = min(heard.upperBound, piece.end)
            for t in state.readers.indices where gains[t] != 0 {
                switch piece.sound {
                case .silent:
                    continue
                case .source(let source):
                    state.readers[t].read((source + (from - piece.start))..<(source + (to - piece.start)), into: &state.track)
                case .stretched(let run):
                    state.stretches[t].read(runs[run], frames: from..<to, preroll: preroll, into: &state.track)
                }
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

    /// The clips of `sequence` with any output frames, in order, as the mix plays them: faded where the sound would
    /// jump, read on where a clip goes on with the source of the one before (at 1× frame for frame, at another speed in
    /// the same run), and the runs the stretched ones play.
    private static func pieces(
        of sequence: [Clip], timeMap: TimeMap, contentFrames: Int64, source: Source
    ) -> (pieces: [Piece], runs: [SpeedStretch.Run]) {
        let starts = timeMap.clipOutputStarts.map(frames(ofNanoseconds:))
        var pieces: [Piece] = []
        var runs: [SpeedStretch.Run] = []
        // The clip of the last piece.
        var previous: Clip?
        for (k, clip) in sequence.enumerated() {
            let start = starts[k], end = k + 1 < starts.count ? starts[k + 1] : contentFrames
            guard start < end else { continue }
            // Read as `TimeMap` reads it, which gives the clip its frames: the picture and the sound agree on it.
            let clipSpeed = ClipSpeed.clamped(clip.speed)
            let from = frames(ofNanoseconds: nanoseconds(from: source.origin, to: clip.start))
            var piece = Piece(start: start, end: end, sound: .silent, fadesIn: false, fadesOut: false)
            if clip.take == source.takeID, clipSpeed == 1 {
                piece.sound = .source(from)
            } else if clip.take == source.takeID, clipSpeed <= SpeedStretch.maximumSpeed {
                piece.sound = .stretched(run: runs.count)
                runs.append(SpeedStretch.Run(
                    output: start..<end, source: from, sourceEnd: frames(ofNanoseconds: nanoseconds(from: source.origin, to: clip.end)),
                    speed: clipSpeed))
            }
            if let previous, let last = pieces.indices.last {
                let followsOn = clip.take == previous.take && clip.start == previous.end
                let goesOn = followsOn && clipSpeed == ClipSpeed.clamped(previous.speed)
                switch (pieces[last].sound, piece.sound) {
                case (.source(let before), .source) where goesOn:
                    // The source frames on from where the clip before left off, so the seam is not there at all.
                    piece.sound = .source(before + (pieces[last].end - pieces[last].start))
                case (.stretched(let run), .stretched) where goesOn:
                    // The same stretch goes on, so the seam is not there either.
                    runs[run].output = runs[run].output.lowerBound..<end
                    runs[run].sourceEnd = runs[runs.count - 1].sourceEnd
                    runs.removeLast()
                    piece.sound = .stretched(run: run)
                default:
                    piece.fadesIn = true
                    pieces[last].fadesOut = true
                    if case .stretched(let run) = pieces[last].sound { runs[run].followedBySource = followsOn && piece.sound != .silent }
                }
            }
            pieces.append(piece)
            previous = clip
        }
        return (pieces, runs)
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
