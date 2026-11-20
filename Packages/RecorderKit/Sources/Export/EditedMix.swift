// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import Synchronization
import os

/// The sound of an edit document, at 48 kHz: the one mix of the export and of the preview (design §7.7).
///
/// For each clip, every audio track of the clip's take (phase 3 design §9: each take the sequence shows is a `Source` of
/// its own) reads the range of that take the clip keeps (each placed by host time with its own `audioClock` anchors,
/// `AudioTrackTimeline`), at its gain from `audio.tracks` (0 to 2, 0 when muted, 1 for a track the plan does not name),
/// found by `AudioPlan.trackGain(take:track:takes:)`: the track's own key, or else that of the same track in the first
/// take of the sequence that has one, so a row's gain holds in every take; the tracks are added together with the click
/// sounds, go through the limiter when `audio.limiter` is on, and are clipped to [−1, 1]. The mix is mono if every track
/// of every take is, stereo otherwise. A track that one take has and another does not is silent in the clips of the
/// other. With one take, the mix of phase 2, sample for sample.
///
/// - Clip `k` is output frames `round(O_k × 48 000 / 10⁹) ..< round(O_{k+1} × 48 000 / 10⁹)` (`TimeMap`'s starts, the
///   last clip ending at `round(D × 48 000 / 10⁹)`, where the content ends), reading its take from the frame of its
///   start, `round((s_k − origin) × 48 000 / 10⁹)`, with `origin` that take's timeline start (`TakeTimeline.bounds`).
/// - Where two clips meet and the sound would jump (a cut, another take, another speed, or a clip that is silent), the
///   one before fades out over its last 192 frames (4 ms) and the one after fades in over its first 192, linearly. Where
///   the clip after goes on with the source of the one before (the same take and speed, its start the other's end, as
///   a clip split without a cut), there is no fade and the source is read on without a break: the mix is the clip's
///   unsplit. The output's start fades in, and its end out, the same way only where the clip there starts or ends inside
///   its take (`TakeTimeline.editableBounds` of the take of the first clip and of the last): a trimmed start or end never
///   sounds as a step (final review C-M1). A clip at its take's own start or end never fades there (plan decision 7), so
///   the legacy document, one clip over the whole take, mixes the samples the export always did.
/// - A clip at another speed than 1, up to 4×, plays its source stretched to the clip's frames with its pitch kept
///   (`SpeedStretch`), track by track before its gain: the clips of one take at one speed that go on one from the
///   other are stretched as one, from where they start. A clip faster than 4×, a clip with content (phase 3 base plan
///   decision 8) or one of a take the mix has no source for (`with(document:framesPerSecond:)`) is silent.
/// - A click sound (`cursor.clickSound`, `ClickSounds`) plays at `clickSoundGain` from the output frame of every left
///   or right `mouseDown` of every take the clips keep where it can be seen (1c design §5.4): where the screen's opacity
///   (`LayoutTimeline.screenOpacity` of that take's layouts, with its camera readable as the render finds it) is at
///   least 0.5 then, so not under a settled Camera only or Camera full screen; one less than
///   `ClickSounds.minimumSpacing` after the last that sounded, of whichever take, does not sound. A document without
///   layouts (`LayoutTimeline.isTrivial`) sounds every one, as in 1b.
/// - A track with its clean voice (phase 2 design §5.6, `soundIsolation-2`: `analysis.cleanVoice` by the track's own
///   `AudioPlan.key`, a file for every segment heard, each exactly as long as its span) and a cleanup `c` above 0
///   (`TrackGain.cleanup` of the gain the track mixes at, 0 to 1) mixes
///   `c × clean + (1 − c) × dry` before its gain, frame for frame where the dry sound is (the clean voice's own line of the
///   same segments, `AudioTrackTimeline.cleaned`), and at another speed each stretched with a stretch of its own. At
///   cleanup 0, or without its clean voice (a file missing or of another length), the track mixes as recorded and nothing
///   of the clean voice is read; a clean file that is gone while the mix plays (macOS emptied the caches) turns the
///   track dry from the next range on.
/// - With `audio.normalize` (design §5.7, `loudness-1`), a track whose whole measure is there (`analysis.loudness` by its
///   own `AudioPlan.key`, and
///   its clean voice's blocks when it is mixed clean) is brought to its target loudness by `Loudness.gain` of its blocks
///   as it plays (`Loudness.blocks(of:cleanup:mixChannels:)`, with its cleanup when mixed clean and 0 when not), before
///   the user's gain; without the measure, it has no gain of its own. The limiter is on with Normalize, whatever
///   `audio.limiter` says.
/// - The mix lasts `totalFrames`, what the video lasts at its frame rate (`totalFrames(frameCount:framesPerSecond:)`):
///   past the content, silence; before its end, the content is cut.
/// - The export of a range of the output (`ExportRange`, 1c design §7.1) plays the frames of this mix from the range's
///   start on (`frames(of:frameCount:framesPerSecond:)`), as the whole video plays them: the range's edges get no fade
///   of their own.
/// - Phase 3 adds its sound in the order of its design (§13) through four seams, empty in its base (base plan task B9),
///   so a document of phase 1 or 2 mixes the same samples: where the sound of each clip starts and the source it reads
///   there (`AudioCuts`, the J and L cuts), the volume of the ranges of each track (`GainRangePlan`, on each track's
///   frames), then, after the tracks and the clicks and within the content, the sound of the imported clips
///   (`MediaAudio`) and the music with its ducking (`MusicMix`), all before the limiter.
///
/// A range of the mix is the same whatever was rendered before it, rendered without a preroll. With the limiter, whose
/// gain depends on the frames before, a range that does not follow on from the one rendered last starts a limiter
/// `PeakLimiter.settleFrames` before it (at frame 0, when that is closer), which by then gives what the limiter of a mix
/// played from the start does, but for an inaudible trace of an older peak in a loud sustained sound (`PeakLimiter`); a stretched clip is stretched from its start. `render` holds a lock while it mixes (its
/// readers, its stretches and its limiter have state): calls take turns, and the export and the preview each have a mix
/// of their own.
public final class EditedMix: Sendable {
    /// 1 or 2.
    public let channels: Int
    /// Length of the mix, in frames.
    public let totalFrames: Int64
    /// The frames the document's clips last: `round(D × 48 000 / 10⁹)`. Silence from there on.
    let contentFrames: Int64
    /// One for each take the document the mix was made for shows (`LoadedProject.takesShown(by:)`), in the order its
    /// sequence first shows them; the project's own take when it shows none the package has. Shared with the mixes of
    /// other revisions (`with(document:framesPerSecond:)`).
    let sources: [Source]
    /// The segments this mix decoded to find where their audio ends: none for one made by `with(document:framesPerSecond:)`.
    let prereadSegments: Int
    /// What the mix reads of the project's analysis caches (phase 2 design §10), kept by the mixes of other revisions
    /// (`with(document:framesPerSecond:)`): `.none` in phase 1.
    public let analysis: AnalysisInputs
    /// The tracks mixed with their clean voice, by `AudioPlan.key`: those with a cleanup above 0 whose clean voice is
    /// there for every segment heard.
    public let cleanTracks: Set<String>
    /// Where the sound of each clip starts and the source it reads there (phase 3 design §7.3): the clips' own starts
    /// in the base.
    let cuts: AudioCuts
    /// The volume of the ranges of each track (phase 3 design §7.2): empty in the base.
    let gainRanges: GainRangePlan
    /// The sound of the imported clips (phase 3 design §5.4): `none` in the base. Kept by the mixes of other revisions
    /// and of another analysis.
    let media: MediaAudio
    /// The music, with its ducking (phase 3 design §7.4 to §7.6): `none` in the base. Kept by the mixes of other
    /// revisions; made again for another analysis, which says where its files are.
    let music: MusicMix

    /// The project the mix is of, for the music of another analysis (`with(analysis:)`).
    private let project: LoadedProject
    /// The document and the frame rate the mix plays, for `with(analysis:)`.
    private let document: EditDocument
    private let framesPerSecond: Int
    /// `AudioPlan.key` of every audio track of `sources`, one take after the other, each in its take's order: the tracks
    /// the arrays of one value per track below go by. With one take, that take's tracks.
    private let keys: [String]
    /// Where the tracks of each of `sources` are in `keys`.
    private let trackRanges: [Range<Int>]
    /// The clean voice of each track that `analysis` has whole, opened once (`AudioTrackTimeline.cleaned`): shared by the
    /// mixes of every revision.
    private let cleanLines: [AudioTrackTimeline?]
    /// How much of its clean voice each track mixes, 0 to 1: 0 for a track mixed dry.
    private let cleanups: [Float]
    /// The clean files of each track mixed clean, which `render` looks for before it mixes.
    private let cleanFiles: [[String]]
    /// The clips with any output, in order.
    private let pieces: [Piece]
    /// The runs of clips the stretched pieces play.
    private let runs: [SpeedStretch.Run]
    /// The gain of each track: the user's, times the one that normalizes the track as it plays.
    private let gains: [Float]
    /// The gain of each track once it turns dry (its clean files gone): normalized as dry.
    private let dryGains: [Float]
    /// The output frames the click sound starts at, in order, and the sound at its gain.
    let clickFrames: [Int64]
    private let clickSound: [Float]
    private let limited: Bool
    private let missing: [MissingAudio]
    private let state: Mutex<State>

    /// The takes the mix has a source for, in its order (`sources`): a clip of any other take is silent in it, so the
    /// editor makes the mix again (`make`) when the sequence comes to show one of those.
    public var takeIDs: [String] { sources.map(\.takeID) }

    /// What a document can show of each take the mix has a source for (`TakeTimeline.editableBounds`), by take ID: what the
    /// mix holds each cut of the sound to (`AudioCuts`), and the commands that write the sequence with it (phase 3 design
    /// §7.3), so a document they write sounds as `TimeMap` maps it.
    public var takeBounds: [String: ClosedRange<HostTime>] { Self.takeBounds(of: sources) }

    /// `editable` of each of `sources` by take ID, the first for a take there twice.
    private static func takeBounds(of sources: [Source]) -> [String: ClosedRange<HostTime>] {
        Dictionary(sources.map { ($0.takeID, $0.editable) }) { first, _ in first }
    }

    /// What the mixes of every revision of a project's document share: one take's audio tracks, read and placed once.
    final class Source: Sendable {
        let takeID: String
        /// Frame 0 of the tracks' timeline: the take's timeline start, where its legacy document starts.
        let origin: HostTime
        /// What a document can show of the take (`TakeTimeline.editableBounds`): a clip that starts after its start, or
        /// ends before its end, is trimmed there.
        let editable: ClosedRange<HostTime>
        /// The mix's: the most any take's tracks need.
        let channels: Int
        /// Every microphone and system audio track of the take, in the take's order.
        let tracks: [AudioTrackTimeline]
        /// `AudioPlan.key` of each of `tracks`.
        let keys: [String]
        /// The kind of each of `tracks`, for its loudness target.
        let kinds: [TrackKind]
        /// The host times of the take's left and right `mouseDown`s, in order.
        let clicks: [HostTime]
        /// The take, whose layouts decide which clicks are seen.
        let take: TakeRecord
        /// Some camera track of the take can be read (`LayoutTimeline.cameraReadable`), as the render finds it.
        let cameraReadable: Bool

        init(
            take: TakeRecord, origin: HostTime, editable: ClosedRange<HostTime>, channels: Int, tracks: [AudioTrackTimeline],
            clicks: [HostTime], cameraReadable: Bool
        ) {
            takeID = take.id
            self.take = take
            self.origin = origin
            self.editable = editable
            self.channels = channels
            self.tracks = tracks
            keys = tracks.map { AudioPlan.key(take: take.id, track: $0.track) }
            kinds = tracks.map { line in take.tracks.first { $0.id == line.track }?.kind ?? .microphone }
            self.clicks = clicks
            self.cameraReadable = cameraReadable
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

    /// What a clip plays: the tracks of `sources[take]`.
    private enum Sound: Equatable, Sendable {
        /// Nothing: a clip with content, of a take the mix has no source for, or faster than `SpeedStretch.maximumSpeed`.
        case silent
        /// At 1×: the tracks' timeline from this frame on, frame for frame.
        case source(take: Int, frame: Int64)
        /// At another speed: its frames of `runs[run]`, stretched.
        case stretched(take: Int, run: Int)

        /// The source whose tracks it plays; `nil` for silence.
        var take: Int? {
            switch self {
            case .silent: nil
            case .source(let take, _), .stretched(let take, _): take
            }
        }
    }

    /// What `render` changes: each track's reader and stretch, those of its clean voice when it is mixed clean, and the
    /// limiter with the output frame it gives next.
    private struct State {
        var readers: [AudioTrackTimeline.Reader]
        var stretches: [SpeedStretch]
        var cleanReaders: [AudioTrackTimeline.Reader?]
        var cleanStretches: [SpeedStretch?]
        /// The tracks mixed clean whose clean files were found gone: dry from then on.
        var turnedDry: [Bool]
        var limiter: PeakLimiter
        var limiterNext: Int64?
        /// One track's frames of the range being mixed, and its clean voice's.
        var track: [Float] = []
        var clean: [Float] = []
    }

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    /// 4 ms at 48 kHz: the fades between two clips.
    static let fadeFrames: Int64 = 192

    /// The mix of `document` of `project` at `framesPerSecond`, reading `analysis` of the caches: reads every microphone and
    /// system audio track of each take the sequence shows (`LoadedProject.takesShown(by:)`; of `project`'s own take when
    /// it shows none the package has), opening its segments and decoding them once, off Swift's cooperative pool, to find
    /// where each one's audio ends. Each take's events are read first, off that pool too (another take's event log is read
    /// from the disk the first time, `LoadedProject.events(ofTake:)`); a take whose event log cannot be read
    /// (`LoadedProject.readEvents()` throws) is silent: none of its tracks is read and none of its clicks sounds.
    /// - Precondition: `framesPerSecond` is positive.
    /// - Throws: `ExportError.cancelled` if the task is cancelled while reading.
    public static func make(
        project: LoadedProject, document: EditDocument, framesPerSecond: Int, analysis: AnalysisInputs = .none
    ) async throws -> EditedMix {
        let shown = project.takesShown(by: document)
        let takes = shown.isEmpty ? [project] : shown
        var tracks: [[TrackRecord]] = []
        for take in takes {
            tracks.append(try await eventsCanBeRead(take) ? take.take.tracks.filter { !$0.kind.isVideo } : [])
        }
        var channels = 1
        for (take, own) in zip(takes, tracks) {
            for track in own { channels = max(channels, await AudioTrackTimeline.channelCount(of: track, in: take)) }
        }
        var sources: [Source] = []
        for (take, own) in zip(takes, tracks) {
            sources.append(try await source(of: take, tracks: own, channels: channels))
        }
        let prereadSegments = sources.reduce(0) { sum, source in source.tracks.reduce(sum) { $0 + $1.decodedSegments } }
        let timeMap = TimeMap(sequence: document.sequence)
        let media = await MediaAudio.make(project: project, document: document, timeMap: timeMap, channels: channels)
        let music = await MusicMix.make(project: project, document: document, timeMap: timeMap, analysis: analysis, channels: channels)
        return EditedMix(
            project: project, sources: sources, cleanLines: await cleanLines(of: sources, analysis: analysis), media: media, music: music,
            document: document, framesPerSecond: framesPerSecond, prereadSegments: prereadSegments, analysis: analysis)
    }

    /// Reads the events of the take `project` is focused on if they were not read yet, off Swift's cooperative pool, and
    /// whether they could be read; logs why not.
    /// - Throws: `ExportError.cancelled` if the task is cancelled while it waits to read them.
    private static func eventsCanBeRead(_ project: LoadedProject) async throws -> Bool {
        do {
            return try await offTheCooperativePool {
                do {
                    try project.readEvents()
                    return true
                } catch {
                    let take = project.take.id
                    logger.error("The events of \(take, privacy: .public) cannot be read (\(String(describing: error), privacy: .public)): it is silent")
                    return false
                }
            }
        } catch is CancellationError {
            throw ExportError.cancelled
        }
    }

    /// The source of the take `project` is focused on (`LoadedProject.focused(on:)`), whose events are read: its audio
    /// tracks `tracks` read with `channels` channels on its timeline, its clicks (none when its events could not be read),
    /// what a document can show of it and whether its camera can be read.
    private static func source(of project: LoadedProject, tracks: [TrackRecord], channels: Int) async throws -> Source {
        let origin = TakeTimeline.bounds(take: project.take, events: project.events).start
        var timelines: [AudioTrackTimeline] = []
        for track in tracks {
            timelines.append(try await AudioTrackTimeline.load(project, track: track, origin: origin, channels: channels))
        }
        let clicks = project.events.sortedByTime().compactMap { event -> HostTime? in
            guard case .mouseDown(let button, _, _) = event.kind, button == .left || button == .right else { return nil }
            return event.t
        }
        let editable = TakeTimeline.editableBounds(take: project.take, events: project.events)
        // The render's rule (`FrameRenderer.cameraReadable`): the layouts that need the camera are Screen only without it.
        let cameraReadable = LayoutTimeline.cameraReadable(take: project.take) { SegmentAvailability.classify($0, in: project.package) }
        return Source(
            take: project.take, origin: origin, editable: editable.start...editable.end, channels: channels, tracks: timelines,
            clicks: clicks, cameraReadable: cameraReadable)
    }

    /// The mix of another revision of the document, `document` at `framesPerSecond`, of the same project: it reads the
    /// same sources and the same clean voice, without decoding the one again to place it nor opening the other. A clip of
    /// a take it has no source for (`takeIDs`) is silent in it. It keeps the sound of the imported clips and the music
    /// this mix opened (empty in the base of phase 3: plans 3a and 3c plan them again here for `document`, without
    /// waiting).
    /// - Precondition: `framesPerSecond` is positive.
    public func with(document: EditDocument, framesPerSecond: Int) -> EditedMix {
        EditedMix(
            project: project, sources: sources, cleanLines: cleanLines, media: media, music: music, document: document,
            framesPerSecond: framesPerSecond, prereadSegments: 0, analysis: analysis)
    }

    /// The mix of this document reading `analysis` of the caches instead: the same sources and imported clips, without
    /// decoding them again; only the clean files `analysis` names are opened (never decoded), and the music is made again
    /// (`MusicMix.make`), its files and its voice being `analysis`'s.
    public func with(analysis: AnalysisInputs) async -> EditedMix {
        let music = await MusicMix.make(
            project: project, document: document, timeMap: TimeMap(sequence: document.sequence), analysis: analysis, channels: channels)
        return EditedMix(
            project: project, sources: sources, cleanLines: await Self.cleanLines(of: sources, analysis: analysis), media: media,
            music: music, document: document, framesPerSecond: framesPerSecond, prereadSegments: 0, analysis: analysis)
    }

    /// Whether a mix reads the same of the caches in `a` as in `b`: the same clean voice and the same loudness. The
    /// person's masks and the faces are the picture's, so a mix made with one sounds as one made with the other.
    public static func hearsTheSame(_ a: AnalysisInputs, _ b: AnalysisInputs) -> Bool {
        a.cleanVoice == b.cleanVoice && a.loudness == b.loudness
    }

    /// The clean voice of each track of `sources` (one take after the other) that `analysis` has, by the track's own key,
    /// if it has it whole.
    private static func cleanLines(of sources: [Source], analysis: AnalysisInputs) async -> [AudioTrackTimeline?] {
        var lines: [AudioTrackTimeline?] = []
        for source in sources {
            for (t, track) in source.tracks.enumerated() {
                guard let voice = analysis.cleanVoice[source.keys[t]] else {
                    lines.append(nil)
                    continue
                }
                lines.append(await AudioTrackTimeline.cleaned(track, files: voice.files, channels: source.channels))
            }
        }
        return lines
    }

    private init(
        project: LoadedProject, sources: [Source], cleanLines: [AudioTrackTimeline?], media: MediaAudio, music: MusicMix,
        document: EditDocument, framesPerSecond: Int, prereadSegments: Int, analysis: AnalysisInputs
    ) {
        precondition(framesPerSecond > 0, "EditedMix: \(framesPerSecond) frames per second")
        precondition(!sources.isEmpty, "EditedMix: no take")
        // Every track of every take, one take after the other.
        let tracks = sources.flatMap(\.tracks)
        let takes = sources.flatMap { source in source.tracks.map { _ in source.takeID } }
        let keys = sources.flatMap(\.keys), kinds = sources.flatMap(\.kinds)
        precondition(cleanLines.count == tracks.count, "EditedMix: \(cleanLines.count) clean lines")
        self.project = project
        self.sources = sources
        self.keys = keys
        self.media = media
        self.music = music
        var next = 0
        trackRanges = sources.map { source in
            defer { next += source.tracks.count }
            return next..<(next + source.tracks.count)
        }
        self.cleanLines = cleanLines
        self.document = document
        self.framesPerSecond = framesPerSecond
        self.prereadSegments = prereadSegments
        self.analysis = analysis
        let mixChannels = sources[0].channels
        channels = mixChannels
        let timeMap = TimeMap(sequence: document.sequence)
        totalFrames = Self.totalFrames(frameCount: timeMap.frameCount(frameRate: framesPerSecond), framesPerSecond: framesPerSecond)
        contentFrames = Self.frames(ofNanoseconds: timeMap.duration)
        // The cuts of the sound held to what each take has (phase 3 design §7.3).
        let cuts = AudioCuts(document: document, timeMap: timeMap, takeBounds: Self.takeBounds(of: sources))
        self.cuts = cuts
        (pieces, runs) = Self.pieces(of: document.sequence, cuts: cuts, contentFrames: contentFrames, sources: sources)
        gainRanges = GainRangePlan(document: document, timeMap: timeMap, keys: sources.map(\.keys), cuts: cuts)
        // The takes the sequence shows, in the order it first shows them: where a track's gain is looked for by its id
        // when its own take has none (phase 3 base plan decision 11).
        var seen: Set<String> = []
        let shownTakes = document.sequence.compactMap { seen.insert($0.take).inserted ? $0.take : nil }
        let plans = tracks.indices.map { t in
            document.audio.trackGain(take: takes[t], track: tracks[t].track, takes: shownTakes)
        }
        let userGains = plans.map { plan -> Float in
            guard let plan else { return 1 }
            if plan.muted { return 0 }
            return plan.gain.isNaN ? 1 : Float(min(max(plan.gain, 0), 2))
        }
        // The cleanup of each track, 0 to 1, where its clean voice is there to mix.
        let cleanup = tracks.indices.map { t -> Double in
            guard cleanLines[t] != nil, let plan = plans[t], !plan.cleanup.isNaN else { return 0 }
            return min(max(plan.cleanup, 0), 1)
        }
        cleanups = cleanup.map(Float.init)
        cleanTracks = Set(tracks.indices.filter { cleanup[$0] > 0 }.map { keys[$0] })
        cleanFiles = tracks.indices.map { t in
            cleanup[t] > 0 ? (cleanLines[t]?.placed.map(\.segment.asset.url.path) ?? []) : []
        }
        if document.audio.normalize {
            let normalized = { (t: Int, cleanup: Double) -> Float in
                userGains[t] * Self.normalizingGain(
                    analysis.loudness[keys[t]], cleanup: cleanup, mixChannels: mixChannels, kind: kinds[t])
            }
            gains = tracks.indices.map { normalized($0, cleanup[$0]) }
            dryGains = tracks.indices.map { normalized($0, 0) }
        } else {
            gains = userGains
            dryGains = userGains
        }
        let clickGain = document.cursor.clickSoundGain.isNaN ? 0 : Float(min(max(document.cursor.clickSoundGain, 0), 1))
        if let sound = ClickSounds.samples(document.cursor.clickSound), clickGain > 0 {
            clickSound = sound.map { $0 * clickGain }
            clickFrames = Self.clickFrames(of: sources, document: document, timeMap: timeMap)
        } else {
            clickSound = []
            clickFrames = []
        }
        limited = document.audio.limiter || document.audio.normalize
        var missing: [MissingAudio] = []
        for source in sources {
            missing += Self.missing(of: source, in: document.sequence, timeMap: timeMap, totalFrames: totalFrames)
        }
        self.missing = missing
        // Nothing of the clean voice is made for a track mixed dry.
        let mixedClean = cleanLines.indices.map { cleanup[$0] > 0 ? cleanLines[$0] : nil }
        state = Mutex(State(
            readers: tracks.map(AudioTrackTimeline.Reader.init), stretches: tracks.map(SpeedStretch.init),
            cleanReaders: mixedClean.map { $0.map(AudioTrackTimeline.Reader.init) },
            cleanStretches: mixedClean.map { $0.map(SpeedStretch.init) }, turnedDry: Array(repeating: false, count: tracks.count),
            limiter: PeakLimiter(channels: mixChannels)))
    }

    /// The gain that brings a track of `kind` measured as `loudness` to its target as the mix plays it, with `cleanup` of
    /// its clean voice (0: dry) and `mixChannels` channels: 1 without the measure, or without its clean voice's blocks
    /// when it is mixed clean (the measure is not whole yet).
    private static func normalizingGain(_ loudness: TrackLoudness?, cleanup: Double, mixChannels: Int, kind: TrackKind) -> Float {
        guard let loudness else { return 1 }
        if cleanup > 0 {
            guard let wet = loudness.wet, let cross = loudness.cross, wet.count == loudness.dry.count, cross.count == loudness.dry.count
            else { return 1 }
        }
        let blocks = Loudness.blocks(of: loudness, cleanup: cleanup, mixChannels: mixChannels)
        return Loudness.gain(measured: Loudness.integrated(blocks), kind: kind)
    }

    /// The spans left silent, track by track, in output seconds within the mix (with the cuts in them closed): the
    /// segments that could not be opened, then where reading one stopped.
    public var missingAudio: [MissingAudio] { missing }

    /// Whether there is anything to hear: an audio track of a take, a click sound the clips keep, an imported clip that
    /// sounds or music. Without, the export has no audio.
    var hasSound: Bool { !keys.isEmpty || !clickFrames.isEmpty || media.hasSound || music.hasSound }

    /// What the mix plays, as text, for the tests that hold it as it was (`MultiTakeMixTests`): its channels and lengths,
    /// each piece (its output frames, what it plays and its fades), each run, each track's key, gains and cleanup, the
    /// click frames and the spans left silent. What the first take plays reads as in phase 2, without its index.
    var playDescription: String {
        var lines = ["channels \(channels) total \(totalFrames) content \(contentFrames) limited \(limited)"]
        for piece in pieces {
            let sound: String
            switch piece.sound {
            case .silent: sound = "silent"
            case .source(let take, let frame): sound = take == 0 ? "source \(frame)" : "source \(take):\(frame)"
            case .stretched(let take, let run): sound = take == 0 ? "run \(run)" : "run \(take):\(run)"
            }
            lines.append("piece \(piece.start)..<\(piece.end) \(sound)\(piece.fadesIn ? " in" : "")\(piece.fadesOut ? " out" : "")")
        }
        for run in runs { lines.append("run \(run.output) from \(run.source) heard \(run.heard) at \(run.speed)") }
        for t in gains.indices {
            lines.append("track \(keys[t]) gain \(gains[t]) dry \(dryGains[t]) cleanup \(cleanups[t])")
        }
        lines.append("clicks \(clickFrames)")
        for span in missing {
            let reason = "\(span.reason)".prefix { $0 != "(" }
            lines.append("missing \(span.track) \(span.file) \(span.start) \(span.end) \(reason)")
        }
        return lines.joined(separator: "\n")
    }

    /// The frames of audio that `frameCount` frames of video at `fps` last: `round(frameCount / fps × 48 000)`.
    static func totalFrames(frameCount: Int, framesPerSecond fps: Int) -> Int64 {
        Int64((Double(frameCount) / Double(fps) * AudioTrackTimeline.sampleRate).rounded())
    }

    /// The output frames of the mix that the export of `range` plays, drawing `frameCount` frames at `fps` from its
    /// start: from `round(start × 48 000 / 10⁹)` on, as many as those frames last (`totalFrames(frameCount:framesPerSecond:)`).
    /// For the whole output (`ExportRange.whole`, with the video's frames), `0 ..< totalFrames`.
    static func frames(of range: ExportRange, frameCount: Int, framesPerSecond fps: Int) -> Range<Int64> {
        let first = frames(ofNanoseconds: range.start)
        return first..<(first + totalFrames(frameCount: frameCount, framesPerSecond: fps))
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
            turnDryWhereTheCleanVoiceIsGone(&state, near: outputFrames)
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

    /// Marks the tracks mixed clean whose clean files are no longer there (macOS emptied the caches) as dry from now on:
    /// a reader of the clean voice opened before could read on, one opened after would give silence. Only those of the
    /// takes that mixing output frames `frames` can read (`takes(near:)`); another take's are looked at when a range
    /// comes to read them.
    private func turnDryWhereTheCleanVoiceIsGone(_ state: inout State, near frames: Range<Int64>) {
        for take in takes(near: frames) {
            for t in trackRanges[take] where !cleanFiles[t].isEmpty && !state.turnedDry[t] {
                guard let gone = cleanFiles[t].first(where: { !FileManager.default.fileExists(atPath: $0) }) else { continue }
                let file = (gone as NSString).lastPathComponent, key = keys[t]
                Self.logger.error("Clean voice \(file, privacy: .public) is gone: track \(key, privacy: .public) mixes dry from here")
                state.turnedDry[t] = true
                state.cleanReaders[t] = nil
                state.cleanStretches[t] = nil
            }
        }
    }

    /// The sources whose tracks mixing output frames `frames` can read, in order: those of the pieces from
    /// `PeakLimiter.settleFrames` before it (where a new limiter settles) to `PeakLimiter.lookaheadFrames` after it (its
    /// lookahead). With one take, that one, wherever `frames` is.
    private func takes(near frames: Range<Int64>) -> [Int] {
        guard sources.count > 1 else { return [0] }
        let (before, under) = frames.lowerBound.subtractingReportingOverflow(Int64(PeakLimiter.settleFrames))
        let (after, over) = frames.upperBound.addingReportingOverflow(Int64(PeakLimiter.lookaheadFrames))
        let from = under ? Int64.min : before, to = over ? Int64.max : after
        var near = [Bool](repeating: false, count: sources.count)
        var k = Self.first(in: pieces.count) { pieces[$0].end <= from }
        while k < pieces.count, pieces[k].start < to {
            if let take = pieces[k].sound.take { near[take] = true }
            k += 1
        }
        return near.indices.filter { near[$0] }
    }

    /// The sum of the tracks (each piece's, those of its take, at the volume of their ranges), the click sounds, the
    /// imported clips and the music over output frames `frames`, into `samples`, before the limiter: silence outside the
    /// content. A stretch that starts anew starts `preroll` frames before (0: at its run's start).
    private func mix(_ frames: Range<Int64>, preroll: Int64, into samples: inout [Float], state: inout State) {
        samples.removeAll(keepingCapacity: true)
        samples.append(contentsOf: repeatElement(0, count: frames.count * channels))
        let heard = frames.clamped(to: 0..<max(0, min(contentFrames, totalFrames)))
        guard !heard.isEmpty else { return }
        var k = Self.first(in: pieces.count) { pieces[$0].end <= heard.lowerBound }
        while k < pieces.count, pieces[k].start < heard.upperBound {
            let piece = pieces[k]
            k += 1
            guard let take = piece.sound.take else { continue }
            let from = max(heard.lowerBound, piece.start), to = min(heard.upperBound, piece.end)
            let firstTrack = trackRanges[take].lowerBound
            for t in trackRanges[take] where gains[t] != 0 {
                // A track turned dry has no clean reader any more.
                let cleanReader = state.cleanReaders[t]
                let cleanup = cleanReader == nil ? 0 : cleanups[t]
                let trackGain = state.turnedDry[t] ? dryGains[t] : gains[t]
                // The dry sound, unless only the clean voice is heard.
                if cleanup < 1 {
                    play(piece, from..<to, preroll: preroll, reader: state.readers[t], stretch: &state.stretches[t], into: &state.track)
                }
                if cleanup == 1, let cleanReader {
                    play(piece, from..<to, preroll: preroll, reader: cleanReader, stretch: &state.cleanStretches[t]!, into: &state.track)
                } else if cleanup > 0, let cleanReader {
                    play(piece, from..<to, preroll: preroll, reader: cleanReader, stretch: &state.cleanStretches[t]!, into: &state.clean)
                    let dry = 1 - cleanup
                    for i in state.track.indices { state.track[i] = state.track[i] * dry + state.clean[i] * cleanup }
                }
                for frame in from..<to {
                    var gain = trackGain * piece.fade(at: frame)
                    if !gainRanges.isEmpty { gain *= gainRanges.gain(take: take, track: t - firstTrack, atOutputFrame: frame) }
                    let input = Int(frame - from) * channels, output = Int(frame - frames.lowerBound) * channels
                    for c in 0..<channels { samples[output + c] += state.track[input + c] * gain }
                }
            }
        }
        if !clickSound.isEmpty {
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
        // The imported clips, then the music (phase 3 design §13, steps 2 and 3), kept within the content.
        guard media.hasSound || music.hasSound else { return }
        media.add(frames, into: &samples, channels: channels)
        music.add(frames, into: &samples, channels: channels)
        let before = Int(heard.lowerBound - frames.lowerBound) * channels, after = Int(heard.upperBound - frames.lowerBound) * channels
        for i in 0..<before { samples[i] = 0 }
        for i in after..<samples.count { samples[i] = 0 }
    }

    /// Output frames `frames` of `piece` of one track, as `reader` reads it at 1× and `stretch` stretches it at another
    /// speed, into `samples`.
    private func play(
        _ piece: Piece, _ frames: Range<Int64>, preroll: Int64, reader: AudioTrackTimeline.Reader, stretch: inout SpeedStretch,
        into samples: inout [Float]
    ) {
        switch piece.sound {
        case .silent:
            samples.removeAll(keepingCapacity: true)
            samples.append(contentsOf: repeatElement(0, count: frames.count * reader.timeline.channels))
        case .source(_, let source):
            reader.read((source + (frames.lowerBound - piece.start))..<(source + (frames.upperBound - piece.start)), into: &samples)
        case .stretched(_, let run):
            stretch.read(runs[run], frames: frames, preroll: preroll, into: &samples)
        }
    }

    // MARK: - From the document

    /// The clips of `sequence` with any output frames, in order, as the mix plays them, each from the source of its take:
    /// from where `cuts` starts its sound, reading its take from where `cuts` moves its start to (and fed to its stretch
    /// on past its end where an L cut has it heard after it, `AudioCuts.heardEnd(ofClip:)`); faded where the sound
    /// would jump (between two takes too, as at a cut), read on where a clip goes on with the source of the one before
    /// (at 1× frame for frame, at another speed in the same run), and the runs the stretched ones play. A clip with
    /// content is silent here (phase 3 base plan decision 8: the sound of an imported clip is `EditedMix+Media`'s), and so
    /// is a clip of a take `sources` does not have; the clips on both sides of either fade.
    private static func pieces(
        of sequence: [Clip], cuts: AudioCuts, contentFrames: Int64, sources: [Source]
    ) -> (pieces: [Piece], runs: [SpeedStretch.Run]) {
        // The source of each take, the first one for a take there twice.
        let sourceOf = Dictionary(sources.enumerated().map { ($1.takeID, $0) }) { first, _ in first }
        let starts = cuts.starts
        var pieces: [Piece] = []
        var runs: [SpeedStretch.Run] = []
        // The clips of the first and the last piece.
        var first: Clip?
        var previous: Clip?
        // Where the source heard in one go up to the last piece starts (the clips before it that it goes on from, at any
        // speed), and the runs in that stretch of source, whose effects are fed it: none after a silent piece.
        var heardFrom: Int64?
        var heardRuns: [Int] = []
        for (k, clip) in sequence.enumerated() {
            let start = starts[k], end = k + 1 < starts.count ? starts[k + 1] : contentFrames
            guard start < end else { continue }
            // Read as `TimeMap` reads it, which gives the clip its frames: the picture and the sound agree on it.
            let clipSpeed = ClipSpeed.clamped(clip.speed)
            // The frames of its take's timeline (none for a clip without a source: it is silent).
            let take = sourceOf[clip.take]
            let origin = take.map { sources[$0].origin } ?? clip.start
            let from = frames(ofNanoseconds: nanoseconds(from: origin, to: clip.start)) + cuts.sourceShift[k]
            var to = frames(ofNanoseconds: nanoseconds(from: origin, to: clip.end))
            if let take, let heard = cuts.heardEnd(ofClip: k) {
                // An L cut at the clip after has this one heard on past its end, never past what its take has.
                let last = min(heard, Int64(clamping: sources[take].editable.upperBound.nanoseconds))
                to = max(to, frames(ofNanoseconds: last - Int64(clamping: origin.nanoseconds)))
            }
            var piece = Piece(start: start, end: end, sound: .silent, fadesIn: false, fadesOut: false)
            if clip.content != nil {
                // Silent: a point of the take that lasts.
            } else if let take, clipSpeed == 1 {
                piece.sound = .source(take: take, frame: from)
            } else if let take, clipSpeed <= SpeedStretch.maximumSpeed {
                piece.sound = .stretched(take: take, run: runs.count)
                runs.append(SpeedStretch.Run(output: start..<end, source: from, heard: from..<to, speed: clipSpeed))
            }
            let followsOn = previous.map { clip.take == $0.take && clip.start == $0.end } ?? false
            if !followsOn || pieces.last?.sound == .silent || piece.sound == .silent {
                heardFrom = nil
                heardRuns = []
            }
            if piece.sound != .silent, heardFrom == nil { heardFrom = from }
            if let previous, let last = pieces.indices.last {
                let goesOn = followsOn && clipSpeed == ClipSpeed.clamped(previous.speed)
                switch (pieces[last].sound, piece.sound) {
                case (.source(let take, let before), .source) where goesOn:
                    // The source frames on from where the clip before left off, so the seam is not there at all.
                    piece.sound = .source(take: take, frame: before + (pieces[last].end - pieces[last].start))
                case (.stretched(let take, let run), .stretched) where goesOn:
                    // The same stretch goes on, so the seam is not there either.
                    runs[run].output = runs[run].output.lowerBound..<end
                    runs.removeLast()
                    piece.sound = .stretched(take: take, run: run)
                default:
                    piece.fadesIn = true
                    pieces[last].fadesOut = true
                }
            }
            // A stretch is fed the source heard in one go with it, from where that starts to where this clip ends.
            if case .stretched(_, let run) = piece.sound, !heardRuns.contains(run) {
                heardRuns.append(run)
                runs[run].heard = min(heardFrom ?? from, from)..<to
            }
            for run in heardRuns { runs[run].heard = runs[run].heard.lowerBound..<max(runs[run].heard.lowerBound, to) }
            pieces.append(piece)
            if first == nil { first = clip }
            previous = clip
        }
        // The output's own edges fade only where they are trimmed inside the take of the clip there.
        if let first, let take = sourceOf[first.take], first.start > sources[take].editable.lowerBound, !pieces.isEmpty {
            pieces[0].fadesIn = true
        }
        if let previous, let take = sourceOf[previous.take], previous.end < sources[take].editable.upperBound,
           let last = pieces.indices.last {
            pieces[last].fadesOut = true
        }
        return (pieces, runs)
    }

    /// The output frames where a click sounds: each kept `mouseDown` of each of `sources` at its output time where the
    /// layouts of its take (`LayoutTimeline` of `document`) show the screen at an opacity of at least 0.5 (every one when
    /// they are trivial), unless it comes less than `ClickSounds.minimumSpacing` after the last that sounded, of any take.
    private static func clickFrames(of sources: [Source], document: EditDocument, timeMap: TimeMap) -> [Int64] {
        // Each kept click's output time, the source it is of (which orders two at the same time) and whether it is seen.
        var clicks: [(time: Int64, take: Int, seen: Bool)] = []
        for (take, source) in sources.enumerated() {
            let layouts = LayoutTimeline(document: document, take: source.take, timeMap: timeMap, cameraReadable: source.cameraReadable)
            for click in source.clicks {
                guard let time = timeMap.output(atSource: click, take: source.takeID) else { continue }
                // Not under 0.5, as 1c reads it.
                clicks.append((time, take, layouts.isTrivial || !(layouts.screenOpacity(atOutput: time) < 0.5)))
            }
        }
        clicks.sort { ($0.time, $0.take) < ($1.time, $1.take) }
        var frames: [Int64] = []
        var last: Int64?
        for (time, _, seen) in clicks {
            // A click that cannot be seen does not sound (1c design §5.4), nor keeps the next one quiet.
            if !seen { continue }
            if let last, time - last < ClickSounds.minimumSpacing { continue }
            last = time
            frames.append(Self.frames(ofNanoseconds: time))
        }
        return frames
    }

    /// The silent spans of `source`'s tracks in output seconds, clamped to the mix, where its take is heard: in each run of
    /// clips of its take that follow one another in `sequence` (a clip of another take, or one with content, ends a run),
    /// one span from the first instant of it the run keeps to the end of the last (the cuts in the run closed), and for a
    /// span open to the end, to the end of the run (the end of the mix, for a run that ends the output); none in a run
    /// that keeps nothing of it, so a span never covers another take's clips. A span of no length is one point, the first
    /// instant of the take kept at or after it. With one take and no content, the one run is the whole sequence: the
    /// spans of phase 2.
    private static func missing(of source: Source, in sequence: [Clip], timeMap: TimeMap, totalFrames: Int64) -> [MissingAudio] {
        let duration = Double(totalFrames) / AudioTrackTimeline.sampleRate
        // Each run's own time map (its outputs are the sequence's less where it starts), where it starts and ends in the
        // output, and whether it ends the output (only clips that last nothing after it).
        var runs: [(map: TimeMap, start: Int64, end: Int64, endsOutput: Bool)] = []
        var k = 0
        while k < sequence.count {
            guard sequence[k].take == source.takeID, sequence[k].content == nil else {
                k += 1
                continue
            }
            let first = k
            while k < sequence.count, sequence[k].take == source.takeID, sequence[k].content == nil { k += 1 }
            let end = k < sequence.count ? timeMap.clipOutputStarts[k] : timeMap.duration
            runs.append((
                TimeMap(sequence: Array(sequence[first..<k])), timeMap.clipOutputStarts[first], end, end >= timeMap.duration))
        }
        return source.tracks.flatMap { track in
            track.missing.flatMap { span -> [MissingAudio] in
                func entry(_ start: Int64, _ end: Double) -> MissingAudio? {
                    AudioTrackTimeline.missingEntry(
                        track: track.track, file: span.file, start: Double(start) / 1e9, end: end, duration: duration, reason: span.reason)
                }
                if let spanEnd = span.end, span.start < spanEnd {
                    return runs.compactMap { run in
                        guard let range = run.map.outputRange(ofSource: span.start..<spanEnd, take: source.takeID) else { return nil }
                        return entry(run.start + range.lowerBound, Double(run.start + range.upperBound) / 1e9)
                    }
                }
                if span.end == nil {
                    return runs.compactMap { run in
                        guard let first = run.map.firstKeptOutput(atOrAfter: span.start, take: source.takeID) else { return nil }
                        return entry(run.start + first, run.endsOutput ? duration : Double(run.end) / 1e9)
                    }
                }
                guard let first = timeMap.firstKeptOutput(atOrAfter: span.start, take: source.takeID) else { return [] }
                return entry(first, Double(first) / 1e9).map { [$0] } ?? []
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
