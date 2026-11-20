// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import os

/// The sound of the imported clips (phase 3 design §5.4 and §13, step 2; plan 3a decision 15): those of the sequence
/// (`ClipContent.media`) and those over it (`AnnotationKind.clip`), each read from its file of `assets/`
/// (`ProjectPackage.mediaAsset(_:as:)`, `AudioTrackTimeline.load(_:id:channels:holding:)`). `EditedMix` adds it after the
/// tracks and the clicks, before the music and the limiter.
///
/// - Every file the document's clips name (`assets(namedBy:)`, muted or not) is opened by `make` as a line of its own
///   from frame 0 in two channels (a mono file in both, one of more by ITU-R BS.775), at 48 kHz (a file at another rate
///   resampled as a take's segment is), and decoded once, off Swift's cooperative pool, keeping in memory what the budget
///   lets it (`AudioTrackTimeline.load(_:id:channels:holding:)`): the AAC of a clip does not decode the same bits twice,
///   so a range read again from the file would not mix the same. The lines of one mix hold `heldBudget` frames at most
///   all together (10 minutes, 230 MB): first, in the order of their paths, the stretch of each file its clips read (from
///   the first frame read to the last), then each whole file while it fits; what a line does not hold it reads from its
///   file as it plays, which keeps the sound but not its last bits. A remade mix takes the lines of the mix before that
///   hold all it reads of them (`EditedMix.make(…reusing:)`), never decoding them again. The sound of every other
///   revision (`with(document:timeMap:)`) and of another analysis keeps the lines. Two mixes made apart each decode their
///   own, which can be a few units in the last place apart (−134 dBFS). A file that is not one of `assets/`
///   (`mediaAsset` refuses it: gone, a link, too large, not a clip) or that has no audio track AVFoundation can open is
///   silent, and is looked at all the same (`assets`): the mix lacks nothing for it, so the editor does not make it again
///   (`EditedMix.lacksMedia(for:)`).
/// - A clip of the sequence plays over its output frames, `frames(O_k) ..< frames(O_{k+1})` (`EditedMix.frames(ofNanoseconds:)`,
///   the last one to `frames(D)`: no cut of the sound moves a clip with content, `AudioCuts`), its stretch of the file
///   `frames(start) ..< frames(end)`, silence outside it: at 1× its frame `S + i` plays the file's `frames(start) + i`;
///   at another speed `v` (`ClipSpeed.clamped`), up to `SpeedStretch.maximumSpeed`, the stretch is stretched with its
///   pitch kept (`SpeedStretch`, a run of its own from its start, fed only that stretch); faster, it is silent, as a clip
///   of the take is.
/// - A clip over the video (anchored to the output or the whole video; one anchored to the take is never shown) that is
///   not muted plays at 1× over its anchor cut to its file (`end − start`, from where it starts, so it never repeats, as
///   the picture shows it: `FrameEvaluator`), within the content: output frame `o` plays the file's
///   `frames(start) + (o − frames(anchor start))`, silence outside `frames(start) ..< frames(end)`.
/// - Each at its volume, `10^(dB / 20)` (dB held to at most `maximumDecibels`; one that is not a number is 0 dB; at
///   `GainRange.silence` or below, silent), faded in over its first `EditedMix.fadeFrames` and out over its last, linearly
///   from 0 at its edge, as two clips of the take where the sound jumps. A mono mix hears each as `(L + R) / 2`, which
///   keeps a file's level (the mix's own mixdown adds the channels, for a recorded interface's inputs).
///
/// A range is the same however it is reached: at 1× a line gives the same bits of what it holds from anywhere, and a
/// stretch that does not go on from the frames it gave last starts again from its clip's start (or `preroll` frames
/// before the range, the preview after a jump), as the take's do. Each sound has a state of its own (its readers and
/// stretches), which only `add`, with its mix's lock held, touches: `make` and `with(document:timeMap:)` each give a new
/// one, so two mixes never share it.
///
/// Without an imported clip (the documents of phases 1 and 2) nothing is opened, `hasSound` is false and `add` adds
/// nothing, so the mix is phase 2's.
struct MediaAudio: Sendable {
    /// No imported clip to hear.
    static let none = MediaAudio(assets: [], lines: [:], pieces: [], runs: [], decodedFiles: 0)

    /// The loudest an imported clip is heard, in dB: what the commands hold its volume to (`ContentClipCommands.volumeRange`).
    static let maximumDecibels = 12.0
    /// The most frames the lines of one mix hold in memory, all together: 10 minutes at 48 kHz, 230 MB in two channels.
    static let heldBudget: Int64 = 28_800_000

    /// One clip as the mix plays it, for the tests.
    struct PlayedClip: Equatable, Sendable {
        /// The file's path, as the document names it.
        var asset: String
        /// The output frames it sounds over.
        var frames: Range<Int64>
        /// The frame of the file's line at `frames.lowerBound`.
        var source: Int64
        /// The frames of the file's line it plays: silence outside them.
        var heard: Range<Int64>
        /// 1 over the video; as `ClipSpeed.clamped` reads it in the sequence, at most `SpeedStretch.maximumSpeed`.
        var speed: Double
        /// In amplitude.
        var gain: Float
    }

    /// The files `make` looked at, by the path the document names them by: those its clips named, with sound or not.
    /// Kept by the sound of every other revision.
    let assets: Set<String>
    /// The line of each of `assets` with something placed in it.
    private let lines: [String: AudioTrackTimeline]
    /// How many files `make` decoded: none for the sound of another revision, nor for a line taken from the mix before.
    let decodedFiles: Int
    /// The clips that sound: those of the sequence in its order, then those over the video in the document's.
    private let pieces: [Piece]
    /// The runs the stretched clips of the sequence play, one each.
    private let runs: [SpeedStretch.Run]
    private let state: State

    /// One clip: `played`, read from `line`, stretched by `runs[run]` when `run` is set.
    private struct Piece: Sendable {
        var played: PlayedClip
        var line: AudioTrackTimeline
        var run: Int?

        /// The fade at output frame `frame`: 1 out of the fades, from 0 at the clip's edge up to 191/192.
        func fade(at frame: Int64) -> Float {
            let fades = EditedMix.fadeFrames
            var fade: Float = 1
            if frame - played.frames.lowerBound < fades { fade = Float(frame - played.frames.lowerBound) / Float(fades) }
            if played.frames.upperBound - 1 - frame < fades { fade = min(fade, Float(played.frames.upperBound - 1 - frame) / Float(fades)) }
            return fade
        }
    }

    /// What `add` changes: the reader of each clip at 1× and the stretch of each run, by index, made when it is first read
    /// and let go once a range does not reach its clip; the frames of one clip being added.
    ///
    /// Unchecked: only `add` touches it, with the lock of the one mix whose sound it is held (`EditedMix.render`).
    private final class State: @unchecked Sendable {
        var readers: [Int: AudioTrackTimeline.Reader] = [:]
        var stretches: [Int: SpeedStretch] = [:]
        var frames: [Float] = []
    }

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    /// The sound of the imported clips of `document` of `project`, at the output frames `timeMap` gives them: opens every
    /// file the clips name and decodes it once, off Swift's cooperative pool (`AudioTrackTimeline.load(_:id:channels:holding:)`),
    /// holding in memory what `budget` lets it (see the type). The lines of `previous` (the sound of an earlier mix of
    /// the same project) that hold all this document reads of them are taken as they are, never decoded again.
    /// - Throws: `ExportError.cancelled` if the task is cancelled while reading.
    static func make(
        project: LoadedProject, document: EditDocument, timeMap: TimeMap, reusing previous: MediaAudio? = nil,
        budget: Int64 = heldBudget
    ) async throws -> MediaAudio {
        let named = assets(namedBy: document)
        guard !named.isEmpty else { return .none }
        let reads = read(by: planned(document, timeMap: timeMap))
        var lines: [String: AudioTrackTimeline] = [:]
        var left = max(0, budget)
        // The lines of the mix before that hold what is read of them (or of which nothing is read), within the budget.
        var fresh: [String] = []
        for asset in named.sorted() {
            if let line = previous?.lines[asset], let held = Self.held(by: line, of: reads[asset]), held <= left {
                lines[asset] = line
                left -= held
            } else {
                fresh.append(asset)
            }
        }
        // The other files, opened; what each holds: first what is read of each, then the whole file, while the budget lasts.
        var opened: [(asset: String, file: AudioTrackTimeline.OpenedFile)] = []
        for asset in fresh {
            guard let url = project.package.mediaAsset(asset, as: .video) else {
                logger.error("Imported clip \(asset, privacy: .public): not a clip of assets/ that can be read; it is silent")
                continue
            }
            opened.append((asset, await AudioTrackTimeline.open(file: url)))
        }
        var windows: [String: Range<Int64>] = [:]
        for (asset, file) in opened {
            guard var read = reads[asset] else { continue }
            if let frames = file.estimatedFrames { read = read.clamped(to: 0..<frames) }
            guard !read.isEmpty, Int64(read.count) <= left else { continue }
            windows[asset] = read
            left -= Int64(read.count)
        }
        for (asset, file) in opened {
            guard let frames = file.estimatedFrames, frames > 0 else { continue }
            let held = Int64(windows[asset]?.count ?? 0)
            guard frames - held <= left else { continue }
            windows[asset] = 0..<frames
            left -= frames - held
        }
        var decoded = 0
        for (asset, file) in opened {
            if windows[asset] == nil, let line = previous?.lines[asset], Int64(line.heldFrames?.count ?? 0) <= left {
                // Nothing more of it to hold: the line of the mix before as it is, rather than decoding it again.
                lines[asset] = line
                left -= Int64(line.heldFrames?.count ?? 0)
                continue
            }
            let line = try await AudioTrackTimeline.load(file, id: asset, channels: 2, holding: windows[asset])
            decoded += 1
            if !line.placed.isEmpty { lines[asset] = line }
        }
        return MediaAudio(assets: named, lines: lines, document: document, timeMap: timeMap, decodedFiles: decoded)
    }

    /// The frames `line` holds, if it holds all of `read` (or `read` is `nil`: nothing of it is read); `nil` if it does
    /// not hold some of it.
    private static func held(by line: AudioTrackTimeline, of read: Range<Int64>?) -> Int64? {
        let held = line.heldFrames ?? 0..<0
        guard let read, let end = line.placed.last?.end else { return Int64(held.count) }
        // What is past the file's end is silence, whatever is held.
        let needed = read.clamped(to: 0..<end)
        guard needed.isEmpty || held.clamped(to: needed) == needed else { return nil }
        return Int64(held.count)
    }

    /// The sound of another revision of the document, `document` with its map `timeMap`: the same lines, planned again
    /// without opening anything, with a state of its own. A file this sound did not look at is silent in it.
    func with(document: EditDocument, timeMap: TimeMap) -> MediaAudio {
        MediaAudio(assets: assets, lines: lines, document: document, timeMap: timeMap, decodedFiles: 0)
    }

    /// Every file `document`'s imported clips name, in the sequence and over the video, muted or not.
    static func assets(namedBy document: EditDocument) -> Set<String> {
        var assets: Set<String> = []
        for clip in document.sequence {
            if case let .media(media)? = clip.content { assets.insert(media.asset) }
        }
        for annotation in document.annotations.items {
            if case let .clip(clip) = annotation.kind { assets.insert(clip.asset) }
        }
        return assets
    }

    private init(
        assets: Set<String>, lines: [String: AudioTrackTimeline], pieces: [Piece], runs: [SpeedStretch.Run], decodedFiles: Int
    ) {
        self.assets = assets
        self.lines = lines
        self.pieces = pieces
        self.runs = runs
        self.decodedFiles = decodedFiles
        state = State()
    }

    /// The clips of `document` that sound with `lines`, over the output frames of `timeMap`.
    private init(
        assets: Set<String>, lines: [String: AudioTrackTimeline], document: EditDocument, timeMap: TimeMap, decodedFiles: Int
    ) {
        var pieces: [Piece] = []
        var runs: [SpeedStretch.Run] = []
        for played in Self.planned(document, timeMap: timeMap) {
            guard let line = lines[played.asset] else { continue }
            var piece = Piece(played: played, line: line, run: nil)
            if played.speed != 1 {
                piece.run = runs.count
                runs.append(SpeedStretch.Run(output: played.frames, source: played.source, heard: played.heard, speed: played.speed))
            }
            pieces.append(piece)
        }
        self.init(assets: assets, lines: lines, pieces: pieces, runs: runs, decodedFiles: decodedFiles)
    }

    /// The clips of `document` that sound, whatever their files hold, over the output frames of `timeMap`: those of the
    /// sequence in its order, then those over the video in the document's (see the type).
    private static func planned(_ document: EditDocument, timeMap: TimeMap) -> [PlayedClip] {
        let contentEnd = EditedMix.frames(ofNanoseconds: timeMap.duration)
        var planned: [PlayedClip] = []
        let sequence = document.sequence
        for (k, clip) in sequence.enumerated() {
            guard case let .media(media)? = clip.content, let gain = gain(ofDecibels: media.volume) else { continue }
            let speed = ClipSpeed.clamped(media.speed)
            guard speed <= SpeedStretch.maximumSpeed else { continue }
            let start = EditedMix.frames(ofNanoseconds: timeMap.clipOutputStarts[k])
            let end = k + 1 < sequence.count ? EditedMix.frames(ofNanoseconds: timeMap.clipOutputStarts[k + 1]) : contentEnd
            let first = EditedMix.frames(ofNanoseconds: media.start)
            let heard = first..<max(first, EditedMix.frames(ofNanoseconds: media.end))
            guard start < end, !heard.isEmpty else { continue }
            planned.append(PlayedClip(asset: media.asset, frames: start..<end, source: first, heard: heard, speed: speed, gain: gain))
        }
        for annotation in document.annotations.items {
            guard case let .clip(clip) = annotation.kind, !clip.muted, let gain = gain(ofDecibels: clip.volume) else { continue }
            let (length, overflow) = clip.end.subtractingReportingOverflow(clip.start)
            guard !overflow, length > 0 else { continue }
            // Its anchor cut to its file, as the picture shows it.
            let from: Int64, to: Int64
            switch annotation.anchor {
            case .content:
                continue
            case let .output(start, end):
                let (last, past) = start.addingReportingOverflow(length)
                from = start
                to = past ? end : min(end, last)
            case .whole:
                from = 0
                to = min(timeMap.duration, length)
            }
            guard from < to else { continue }
            let anchorFrame = EditedMix.frames(ofNanoseconds: from)
            let start = max(0, anchorFrame), end = min(EditedMix.frames(ofNanoseconds: to), contentEnd)
            let first = EditedMix.frames(ofNanoseconds: clip.start)
            let heard = first..<max(first, EditedMix.frames(ofNanoseconds: clip.end))
            guard start < end, !heard.isEmpty else { continue }
            planned.append(PlayedClip(
                asset: clip.asset, frames: start..<end, source: first + (start - anchorFrame), heard: heard, speed: 1, gain: gain))
        }
        return planned
    }

    /// The frames of each file that the clips of `planned` read, by its path, from the first to the last (frames before 0
    /// left out): at 1× from `source` for as long as it sounds, within `heard`; stretched, all of `heard` it is fed.
    private static func read(by planned: [PlayedClip]) -> [String: Range<Int64>] {
        var read: [String: Range<Int64>] = [:]
        for played in planned {
            var range = played.heard
            if played.speed == 1 {
                let (last, overflow) = played.source.addingReportingOverflow(Int64(played.frames.count))
                range = (played.source..<(overflow ? .max : max(played.source, last))).clamped(to: played.heard)
            }
            range = range.clamped(to: 0..<Int64.max)
            guard !range.isEmpty else { continue }
            if let other = read[played.asset] {
                range = min(other.lowerBound, range.lowerBound)..<max(other.upperBound, range.upperBound)
            }
            read[played.asset] = range
        }
        return read
    }

    /// `10^(dB / 20)` of `volume` held to at most `maximumDecibels` (0 dB if it is not a number); `nil` at
    /// `GainRange.silence` or below.
    private static func gain(ofDecibels volume: Double) -> Float? {
        let decibels = volume.isNaN ? 0 : min(volume, maximumDecibels)
        guard decibels > GainRange.silence else { return nil }
        return decibels == 0 ? 1 : Float(pow(10, decibels / 20))
    }

    /// Whether any imported clip sounds: without, `add` adds nothing.
    var hasSound: Bool { !pieces.isEmpty }

    /// The clips that sound, in the order they are added.
    var played: [PlayedClip] { pieces.map(\.played) }

    /// The frames each file's line holds in memory, by its path: none for one read from its file as it plays.
    var heldFrames: [String: Range<Int64>] { lines.compactMapValues(\.heldFrames) }

    /// Adds the sound of the imported clips over output frames `frames` into `samples`, which holds those frames,
    /// interleaved with `channels` channels, from `frames.lowerBound`. A stretch that starts anew starts `preroll` frames
    /// before (0: at its clip's start). The mix keeps only what falls within its content. Called with
    /// `EditedMix.render`'s lock held.
    func add(_ frames: Range<Int64>, preroll: Int64 = 0, into samples: inout [Float], channels: Int) {
        guard !pieces.isEmpty, !frames.isEmpty else { return }
        let state = self.state
        for (p, piece) in pieces.enumerated() {
            let from = max(frames.lowerBound, piece.played.frames.lowerBound), to = min(frames.upperBound, piece.played.frames.upperBound)
            guard from < to else {
                // Out of reach: what it holds is let go, and made again if a range comes back to it.
                if let run = piece.run { state.stretches[run] = nil } else { state.readers[p] = nil }
                continue
            }
            if let run = piece.run {
                if state.stretches[run] == nil { state.stretches[run] = SpeedStretch(piece.line) }
                state.stretches[run]!.read(runs[run], frames: from..<to, preroll: preroll, into: &state.frames)
            } else {
                let reader = state.readers[p] ?? AudioTrackTimeline.Reader(piece.line)
                state.readers[p] = reader
                Self.read(piece.played, from..<to, reader: reader, into: &state.frames)
            }
            let sound = state.frames
            for frame in from..<to {
                let gain = piece.played.gain * piece.fade(at: frame)
                let input = Int(frame - from) * 2, output = Int(frame - frames.lowerBound) * channels
                if channels == 1 {
                    samples[output] += (sound[input] + sound[input + 1]) * 0.5 * gain
                } else {
                    samples[output] += sound[input] * gain
                    samples[output + 1] += sound[input + 1] * gain
                }
            }
        }
    }

    /// Output frames `frames` of `played` at 1×, as `reader` reads its line, into `samples` (two channels): the line from
    /// `played.source` at its first frame, silence outside `played.heard`.
    private static func read(_ played: PlayedClip, _ frames: Range<Int64>, reader: AudioTrackTimeline.Reader, into samples: inout [Float]) {
        let first = played.source + (frames.lowerBound - played.frames.lowerBound)
        let wanted = first..<(first + Int64(frames.count))
        let kept = wanted.clamped(to: played.heard)
        guard kept != wanted else {
            reader.read(wanted, into: &samples)
            return
        }
        var heard: [Float] = []
        if !kept.isEmpty { reader.read(kept, into: &heard) }
        samples.removeAll(keepingCapacity: true)
        samples.append(contentsOf: repeatElement(0, count: frames.count * 2))
        if !kept.isEmpty {
            let offset = Int(kept.lowerBound - wanted.lowerBound) * 2
            for i in heard.indices { samples[offset + i] = heard[i] }
        }
    }
}

extension EditedMix {
    /// Whether `document` names an imported clip's file this mix did not look at (`MediaAudio.assets`, kept by the mixes
    /// of other revisions and of another analysis): in a mix of it that file is silent, so the editor makes the mix again
    /// for it (`make`), which opens it. A file that was looked at and cannot be heard (gone, a link, no audio) is never
    /// lacked.
    public func lacksMedia(for document: EditDocument) -> Bool {
        !MediaAudio.assets(namedBy: document).isSubset(of: media.assets)
    }
}
