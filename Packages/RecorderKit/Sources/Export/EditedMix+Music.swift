// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import os

/// The music under the video (phase 3 design §7.4 to §7.6 and §13, step 3: `EditDocument.music`), with its fades and its
/// loops, lowered while someone speaks by the envelope of the ducking (`ducking-1`, `DuckingEnvelope`), each piece read
/// from the file `analysis.musicFiles` has for its source. Anchored to the output: the cuts never move it. `EditedMix`
/// adds it after the tracks, the clicks and the imported clips, before the limiter.
///
/// - Every file `analysis.musicFiles` names is opened once (`MusicFile(contentsOf:)`, mapped, never decoded) by `make`
///   and kept by the music of every other revision (`with(document:timeMap:cuts:)`). A piece whose source has no file
///   there, or whose file cannot be opened (gone, a link, not ours), is silent, and `make` logs it. The mix never makes a
///   file: `MusicAnalysis` (plan 3c, U8) does, and the export waits for it.
/// - A piece plays over the output frames `frames(start) ..< min(frames(end), frames(D))` (`EditedMix.frames(ofNanoseconds:)`:
///   it ends with the output, and the output never goes on for it), a start before 0 read as 0; its frame `f` plays the
///   frame `f − frames(start) + frames(offset)` of its file (an offset below 0 read as 0) at its gain, `10^(g / 20)` with
///   `g` held to +6 dB (one that is not a number is −14, `MusicItem`'s own) and silence at `GainRange.silence` (−∞) or
///   below, through a fade in and a fade out in amplitude, smoothsteps (`SynthMath.smoothstep`) from 0 at its start and
///   its end, each at most half of it (plan 3c decision 7).
/// - With `loop`, a theme of the library (`MusicThemes.id(ofSource:)`) starts again at its file's end with no fade (it
///   loops without a seam by construction); a file of one's own starts again with a crossfade of
///   `crossfadeFrames` (480, 10 ms; at most half the file): it plays its file whole, and every time it starts again its first
///   480 frames come in over its last 480 (smoothsteps that add up to 1), so it repeats every `length − 480` frames.
///   Without `loop`, silence after the file's end.
/// - The ducking (design §7.5, plan 3c decision 8): the voice is that of the microphone and device sound tracks of the take
///   of each clip that sounds (one without content and at 4× or less, `SpeedStretch.maximumSpeed`, of a take the mix has:
///   `tracks`), neither muted nor at 0 (`AudioPlan.trackGain(take:track:takes:)`; the ranges of volume do not count, so
///   the solo does not change it): their stretches with a voice (`analysis.voiceActivity`, in the source) are heard in the
///   output through the cuts of the sound (`AudioCuts`, the J and L cuts), within the window of each clip's sound, and
///   `DuckingEnvelope` makes the envelope of them. The gain of every frame is read from ramps worked out once for the
///   settings (`DuckingRamps`), never with a `pow` for each sample: `DuckingEnvelope.gain(atFrame:)`, bit for bit.
/// - A mono mix hears each piece as `(L + R) / 2`.
///
/// A sample is a function of the frame alone: any range, in any blocks, gives the same music.
///
/// Without a piece that sounds (the documents of phases 1 and 2) `hasSound` is false, no voice is looked at and `add`
/// adds nothing, so the mix is phase 2's.
struct MusicMix: Sendable {
    /// No music to hear.
    static let none = MusicMix()

    /// The crossfade where a file of one's own starts again: 10 ms at 48 kHz.
    static let crossfadeFrames: Int64 = 480

    /// One piece as the mix plays it, for the tests.
    struct PlayedItem: Equatable, Sendable {
        var id: String
        var source: String
        /// The output frames it sounds over: from its start to its end, or to the end of the content where that comes first.
        var frames: Range<Int64>
        /// In amplitude.
        var gain: Float
        /// The frames of its fades, each at most half of `frames`.
        var fadeIn: Int64
        var fadeOut: Int64
        /// The frame of its file at `frames.lowerBound`, before any loop.
        var offset: Int64
        var loop: Bool
        /// The frames of its file.
        var length: Int64
        /// The frames of the crossfade where it starts again: 0 for a theme of the library and without `loop`.
        var crossfade: Int64
    }

    /// The pieces that sound, in the order of their start (then of the document).
    private let pieces: [Piece]
    /// The output frame where the last of them ends.
    private let soundEnd: Int64
    /// The files opened, by source: shared by the music of every revision.
    private let files: [String: MusicFile]
    /// How many files this music opened itself: none for the music of another revision.
    let openedFiles: Int
    /// The microphone and device sound tracks of each take whose voice can lower the music, by take ID.
    private let voiceTracks: [String: [String]]
    /// The stretches with a voice of each of `voiceTracks`, by `AudioPlan.key`, in ns of the source, in order.
    private let voice: [String: [Range<Int64>]]
    /// The envelope of the ducking: unity without a piece that sounds.
    let envelope: DuckingEnvelope
    /// Its gains, for its settings: `nil` while it is unity and nothing was worked out before.
    private let ramps: DuckingRamps?

    /// One piece: `played`, read from `file`.
    private struct Piece: Sendable {
        var played: PlayedItem
        var file: MusicFile
        /// The frames after which the file starts again (`length − crossfade`); 0 without `loop`.
        var period: Int64
        /// Where its frame 0 (with `offset` held below two periods) is in the output.
        var start: Int64
        var offset: Int64

        /// The fades at output frame `frame`, from 0 at the piece's edges to 1.
        func fade(at frame: Int64) -> Float {
            var fade = 1.0
            let into = frame - played.frames.lowerBound, left = played.frames.upperBound - frame
            if into < played.fadeIn { fade = SynthMath.smoothstep(Double(into) / Double(played.fadeIn)) }
            if left < played.fadeOut { fade *= SynthMath.smoothstep(Double(left) / Double(played.fadeOut)) }
            return Float(fade)
        }
    }

    /// The gains of the envelope of the ducking for its settings (`DuckingEnvelope.held`), worked out once: within a run,
    /// `attack` frames before one (`d` frames before, `d` from 0 to `attack`) and `release` frames after one (`d` from 0).
    struct DuckingRamps: Sendable {
        /// The settings, held.
        let settings: Ducking
        /// The gain within a run: the whole amount.
        let full: Float
        /// The gain `d` frames before a run: `attack.count − 1` frames of attack.
        let attack: [Float]
        /// The gain `d` frames after a run's end: `release.count` frames of release.
        let release: [Float]

        /// The ramps of `settings`, held as `DuckingEnvelope.held` holds them, worked out as `DuckingEnvelope` does: its
        /// amount `a`, a descent of `A = max(1, round(attack × 48 000))` frames and a climb of `R` frames, `d` frames before a
        /// run at `a × (A − d) / A` dB and `d` after one at `a × (R − d) / R`, each `10^(dB / 20)` (exactly 1 at 0 dB).
        init(_ settings: Ducking) {
            self.settings = settings
            let amount = settings.amount
            let attackFrames = max(1, Int64((settings.attack * 48_000).rounded()))
            let releaseFrames = max(1, Int64((settings.release * 48_000).rounded()))
            func gain(_ decibels: Double) -> Float { decibels == 0 ? 1 : Float(pow(10, decibels / 20)) }
            full = gain(amount)
            attack = (0...attackFrames).map { d in gain(amount * Double(attackFrames - d) / Double(attackFrames)) }
            release = (0..<releaseFrames).map { d in gain(amount * Double(releaseFrames - d) / Double(releaseFrames)) }
        }

        /// The gain of `envelope` (whose settings are these) at each of `frames`, into `gains`, which then holds
        /// `frames.count` values: `envelope.gain(atFrame:)` of each, the deeper of a release and an attack that overlap.
        func gains(of envelope: DuckingEnvelope, _ frames: Range<Int64>, into gains: inout [Float]) {
            gains.removeAll(keepingCapacity: true)
            gains.reserveCapacity(frames.count)
            let runs = envelope.runs
            guard !runs.isEmpty else {
                gains.append(contentsOf: repeatElement(1, count: frames.count))
                return
            }
            let attackFrames = Int64(attack.count - 1), releaseFrames = Int64(release.count)
            // The first run that starts after the frame; the one before it is the last that starts at or before.
            var next = MusicMix.first(in: runs.count) { runs[$0].lowerBound <= frames.lowerBound }
            for frame in frames {
                while next < runs.count, runs[next].lowerBound <= frame { next += 1 }
                var gain: Float = 1
                if next > 0 {
                    let run = runs[next - 1]
                    if frame < run.upperBound {
                        gain = full
                    } else if frame - run.upperBound < releaseFrames {
                        gain = release[Int(frame - run.upperBound)]
                    }
                }
                if next < runs.count, runs[next].lowerBound - frame <= attackFrames {
                    gain = min(gain, attack[Int(runs[next].lowerBound - frame)])
                }
                gains.append(gain)
            }
        }
    }

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    /// The music of `document` of `project` at the output frames `timeMap` gives, for a mix of `channels` channels (each
    /// `add` is given them), its files and the voice that ducks it read from `analysis`: opens every file `analysis.musicFiles` names, off the
    /// main thread (a file is mapped, never read whole). The voice is that of the tracks the mix has (`tracks`, by
    /// `AudioPlan.key`; every track of `project`'s takes when `nil`), heard through `cuts` (the cuts of `document` held to
    /// the clips alone when `nil`).
    static func make(
        project: LoadedProject, document: EditDocument, timeMap: TimeMap, analysis: AnalysisInputs, channels: Int,
        cuts: AudioCuts? = nil, tracks: Set<String>? = nil
    ) async -> MusicMix {
        var files: [String: MusicFile] = [:]
        for (source, url) in analysis.musicFiles.sorted(by: { $0.key < $1.key }) {
            do {
                files[source] = try open(url)
            } catch {
                logger.error("The music of \(source, privacy: .public) cannot be opened (\(String(describing: error), privacy: .public)): it is silent")
            }
        }
        for source in Set(document.music.items.map(\.source)).sorted() where analysis.musicFiles[source] == nil {
            logger.info("The music of \(source, privacy: .public) has no file yet: it is silent")
        }
        // The tracks whose voice lowers the music: those of the voice of each take.
        var voiceTracks: [String: [String]] = [:]
        for take in project.takes {
            let own = take.tracks.filter { track in
                (track.kind == .microphone || track.kind == .deviceAudio)
                    && tracks.map { $0.contains(AudioPlan.key(take: take.id, track: track.id)) } ?? true
            }
            if !own.isEmpty, voiceTracks[take.id] == nil { voiceTracks[take.id] = own.map(\.id) }
        }
        var voice: [String: [Range<Int64>]] = [:]
        for (take, ids) in voiceTracks {
            for id in ids {
                let key = AudioPlan.key(take: take, track: id)
                guard let activity = analysis.voiceActivity[key] else { continue }
                // In order and apart from one another, as `VoiceActivity` has them (one of the caches edited by hand too).
                var spans: [Range<Int64>] = []
                for span in activity.spans
                    .map({ Int64(clamping: $0.lowerBound.nanoseconds)..<Int64(clamping: max($0.lowerBound, $0.upperBound).nanoseconds) })
                    .filter({ !$0.isEmpty })
                    .sorted(by: { $0.lowerBound < $1.lowerBound }) {
                    if let last = spans.last, span.lowerBound <= last.upperBound {
                        spans[spans.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
                    } else {
                        spans.append(span)
                    }
                }
                voice[key] = spans
            }
        }
        return MusicMix(
            files: files, openedFiles: files.count, voiceTracks: voiceTracks, voice: voice, document: document, timeMap: timeMap,
            cuts: cuts, ramps: nil)
    }

    /// The music of another revision of the document, `document` with its map `timeMap` and its cuts of the sound `cuts`:
    /// the same files and the same voice, planned again without opening anything. A source this music has no file for is
    /// silent in it until the mix reads an analysis that has one (`EditedMix.with(analysis:)`).
    func with(document: EditDocument, timeMap: TimeMap, cuts: AudioCuts) -> MusicMix {
        MusicMix(
            files: files, openedFiles: 0, voiceTracks: voiceTracks, voice: voice, document: document, timeMap: timeMap, cuts: cuts,
            ramps: ramps)
    }

    private init() {
        pieces = []
        soundEnd = 0
        files = [:]
        openedFiles = 0
        voiceTracks = [:]
        voice = [:]
        envelope = DuckingEnvelope(voiced: [], ducking: .default)
        ramps = nil
    }

    private init(
        files: [String: MusicFile], openedFiles: Int, voiceTracks: [String: [String]], voice: [String: [Range<Int64>]],
        document: EditDocument, timeMap: TimeMap, cuts: AudioCuts?, ramps: DuckingRamps?
    ) {
        self.files = files
        self.openedFiles = openedFiles
        self.voiceTracks = voiceTracks
        self.voice = voice
        let contentEnd = EditedMix.frames(ofNanoseconds: timeMap.duration)
        pieces = document.music.items.enumerated()
            .compactMap { index, item in Self.piece(item, file: files[item.source], contentEnd: contentEnd).map { (index, $0) } }
            .sorted { ($0.1.played.frames.lowerBound, $0.0) < ($1.1.played.frames.lowerBound, $1.0) }
            .map(\.1)
        soundEnd = pieces.map(\.played.frames.upperBound).max() ?? 0
        let ducking = document.music.ducking
        guard !pieces.isEmpty, ducking.enabled, !voice.isEmpty else {
            envelope = DuckingEnvelope(voiced: [], ducking: ducking)
            self.ramps = ramps
            return
        }
        let cuts = cuts ?? AudioCuts(document: document, timeMap: timeMap)
        envelope = DuckingEnvelope(
            voiced: Self.voicedOutput(of: document, timeMap: timeMap, cuts: cuts, voiceTracks: voiceTracks, voice: voice),
            ducking: ducking)
        let held = DuckingEnvelope.held(ducking)
        if envelope.isUnity || ramps?.settings == held {
            self.ramps = ramps
        } else {
            self.ramps = DuckingRamps(held)
        }
    }

    /// Whether any piece of music sounds: without, `add` adds nothing.
    var hasSound: Bool { !pieces.isEmpty }

    /// The pieces that sound, in the order of their start.
    var played: [PlayedItem] { pieces.map(\.played) }

    /// Adds the music over output frames `frames` into `samples`, which holds those frames, interleaved with `channels`
    /// channels, from `frames.lowerBound`. The mix keeps only what falls within its content. Called with
    /// `EditedMix.render`'s lock held.
    func add(_ frames: Range<Int64>, into samples: inout [Float], channels: Int) {
        guard !pieces.isEmpty, !frames.isEmpty else { return }
        // The frames any piece plays, and the ducking over them.
        let lowest = max(frames.lowerBound, pieces[0].played.frames.lowerBound)
        let highest = min(frames.upperBound, soundEnd)
        guard lowest < highest else { return }
        var ducked: [Float] = []
        if let ramps, !envelope.isUnity { ramps.gains(of: envelope, lowest..<highest, into: &ducked) }
        var music: [Float] = []
        var tail: [Float] = []
        for piece in pieces {
            let from = max(lowest, piece.played.frames.lowerBound), to = min(highest, piece.played.frames.upperBound)
            guard from < to else { continue }
            var frame = from
            while frame < to {
                let count = Self.read(piece, frame..<to, into: &music, tail: &tail)
                guard count > 0 else { break }
                for i in 0..<count {
                    let f = frame + Int64(i)
                    var gain = piece.played.gain * piece.fade(at: f)
                    if !ducked.isEmpty { gain *= ducked[Int(f - lowest)] }
                    let output = Int(f - frames.lowerBound) * channels
                    if channels == 1 {
                        samples[output] += (music[2 * i] + music[2 * i + 1]) * 0.5 * gain
                    } else {
                        samples[output] += music[2 * i] * gain
                        samples[output + 1] += music[2 * i + 1] * gain
                    }
                }
                frame += Int64(count)
            }
        }
    }

    // MARK: - Private

    /// `item` as the mix plays it from `file`, over the content that ends at output frame `contentEnd`: `nil` without a
    /// file, for one of no frames, at −∞ or that sounds no frame.
    private static func piece(_ item: MusicItem, file: MusicFile?, contentEnd: Int64) -> Piece? {
        guard let file, file.frames > 0 else { return nil }
        let decibels = item.gain.isNaN ? -14 : min(item.gain, 6)
        guard decibels > GainRange.silence else { return nil }
        let start = EditedMix.frames(ofNanoseconds: max(0, item.start))
        let end = min(EditedMix.frames(ofNanoseconds: item.end), contentEnd)
        guard start < end else { return nil }
        let length = Int64(file.frames)
        let half = (end - start) / 2
        let fadeIn = min(EditedMix.frames(ofNanoseconds: max(0, item.fadeIn)), half)
        let fadeOut = min(EditedMix.frames(ofNanoseconds: max(0, item.fadeOut)), half)
        let ownFile = MusicThemes.id(ofSource: item.source) == nil
        let crossfade = item.loop && ownFile ? min(crossfadeFrames, length / 2) : 0
        let period = item.loop ? length - crossfade : 0
        var offset = EditedMix.frames(ofNanoseconds: max(0, item.offset))
        if item.loop {
            // Past the first time through, any time through is the same: held below two, so no frame overflows.
            if offset >= period { offset = period + (offset - period) % period }
        } else if offset >= length {
            return nil
        }
        let played = PlayedItem(
            id: item.id, source: item.source, frames: start..<end, gain: Float(pow(10, decibels / 20)), fadeIn: fadeIn,
            fadeOut: fadeOut, offset: offset, loop: item.loop, length: length, crossfade: crossfade)
        return Piece(played: played, file: file, period: period, start: start, offset: offset)
    }

    /// Reads the frames of `piece`'s file that output frames `frames` play, from their start, into `music` (interleaved,
    /// two channels), up to where the file starts again, a crossfade starts or ends or the file ends: how many frames it
    /// read (0 past the end of a file without a loop). `tail` holds the end of the file a crossfade fades out.
    private static func read(_ piece: Piece, _ frames: Range<Int64>, into music: inout [Float], tail: inout [Float]) -> Int {
        let position = frames.lowerBound - piece.start + piece.offset
        let length = piece.played.length, crossfade = piece.played.crossfade
        var count = Int64(frames.count)
        guard piece.period > 0 else {
            guard position < length else { return 0 }
            count = min(count, length - position)
            piece.file.read(Int(position)..<Int(position + count), into: &music)
            return Int(count)
        }
        let (time, into) = position.quotientAndRemainder(dividingBy: piece.period)
        count = min(count, piece.period - into)
        guard time > 0, into < crossfade else {
            piece.file.read(Int(into)..<Int(into + count), into: &music)
            return Int(count)
        }
        // The file's start coming in over its end, which goes on from the time before.
        count = min(count, crossfade - into)
        piece.file.read(Int(into)..<Int(into + count), into: &music)
        piece.file.read(Int(piece.period + into)..<Int(piece.period + into + count), into: &tail)
        for i in 0..<Int(count) {
            let rising = Float(SynthMath.smoothstep(Double(into + Int64(i)) / Double(crossfade)))
            for c in 0..<2 { music[2 * i + c] = music[2 * i + c] * rising + tail[2 * i + c] * (1 - rising) }
        }
        return Int(count)
    }

    /// The output frames with a voice of `document`: each clip that sounds, of a take with `voiceTracks`, hears in the
    /// window of its sound (`cuts`) the stretches of `voice` of the take's tracks that are neither muted nor at 0, each
    /// source instant at its output frame.
    private static func voicedOutput(
        of document: EditDocument, timeMap: TimeMap, cuts: AudioCuts, voiceTracks: [String: [String]], voice: [String: [Range<Int64>]]
    ) -> [Range<Int64>] {
        var seen: Set<String> = []
        let shownTakes = document.sequence.compactMap { seen.insert($0.take).inserted ? $0.take : nil }
        // The voice heard of each take, one list for each of its tracks.
        var heard: [String: [[Range<Int64>]]] = [:]
        for take in shownTakes {
            for track in voiceTracks[take] ?? [] {
                if let gain = document.audio.trackGain(take: take, track: track, takes: shownTakes) {
                    guard !gain.muted, gain.gain.isNaN || gain.gain > 0 else { continue }
                }
                guard let spans = voice[AudioPlan.key(take: take, track: track)], !spans.isEmpty else { continue }
                heard[take, default: []].append(spans)
            }
        }
        guard !heard.isEmpty else { return [] }
        var voiced: [Range<Int64>] = []
        for (k, clip) in document.sequence.enumerated() {
            let speed = ClipSpeed.clamped(clip.speed)
            guard clip.content == nil, speed <= SpeedStretch.maximumSpeed, let lists = heard[clip.take] else { continue }
            let window = cuts.window(ofClip: k)
            guard !window.isEmpty else { continue }
            // The source heard over the window, and the output frame (fractional) each instant of it is heard at.
            let heardFrom = cuts.sourceNanoseconds(ofClip: k, atOutputFrame: window.lowerBound)
            let heardTo = cuts.sourceNanoseconds(ofClip: k, atOutputFrame: window.upperBound)
            let start = Double(clip.start.nanoseconds), origin = Double(timeMap.clipOutputStarts[k])
            func frame(_ x: Int64) -> Int64 {
                let exact = (origin + (Double(x) - start) / speed) * 48_000 / 1e9
                return min(max(Int64(exact.rounded()), window.lowerBound), window.upperBound)
            }
            for spans in lists {
                var s = Self.first(in: spans.count) { spans[$0].upperBound <= heardFrom }
                while s < spans.count, spans[s].lowerBound < heardTo {
                    let range = frame(max(spans[s].lowerBound, heardFrom))..<frame(min(spans[s].upperBound, heardTo))
                    if !range.isEmpty { voiced.append(range) }
                    s += 1
                }
            }
        }
        return voiced
    }

    /// The file at `url`, opened again once if it is not there (a theme moved into place as it was opened).
    private static func open(_ url: URL) throws -> MusicFile {
        do {
            return try MusicFile(contentsOf: url)
        } catch let error as POSIXError where error.code == .ENOENT {
            return try MusicFile(contentsOf: url)
        }
    }

    /// The first index in `0..<count` for which `isBefore` is false, given that it is true for a prefix and false after.
    fileprivate static func first(in count: Int, _ isBefore: (Int) -> Bool) -> Int {
        var (low, high) = (0, count)
        while low < high {
            let middle = low + (high - low) / 2
            if isBefore(middle) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
