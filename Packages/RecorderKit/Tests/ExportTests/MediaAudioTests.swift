// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// The sound of the imported clips (phase 3 design §5.4 and §13, step 2; plan 3a task A10, decision 15): each file of
/// `assets/` a clip names is a line of its own from frame 0 (`AudioTrackTimeline.load(file:id:channels:)`); a clip of the
/// sequence plays its stretch of it over its output frames at its speed (stretched up to 4×, silent faster, as a clip of
/// the take), a clip over the video plays it once at 1× over its anchor cut to its file, unless muted; each at its volume,
/// `10^(dB / 20)`, with fades of `EditedMix.fadeFrames` at its edges, after the tracks and the clicks. A mono mix hears
/// `(L + R) / 2`. Without an imported clip the mix is the base's.
///
/// The clips are `MediaFixtures`' (a sine at 1/4 of full scale), copied into the package as the editor imports one; the
/// takes start their display at `base`, and their microphone is a sine of 1 kHz at 1/4 of full scale.
@Suite struct MediaAudioTests {
    /// Each case of golden 3 that mixes has no imported clip: nothing looked at, nothing to hear, nothing it lacks. With a
    /// clip over the video whose file is not in the package, the mix looks at it and stays the base, bit for bit, made for
    /// it or as another revision; it then lacks nothing, so the editor never makes it again for that file.
    @Test func noMediaNoSound() async throws {
        let cases = GoldenDocuments.golden3Cases.filter(\.mixes).map(\.name)
        #expect(!cases.isEmpty)
        try await withTemporaryDirectory { tmp in
            try await withThrowingTaskGroup { group in
                for name in cases { group.addTask { try await Self.checkHasNoMedia(name, in: tmp) } }
                try await group.waitForAll()
            }
        }
    }

    /// `noMediaNoSound` of the golden case `name`, its project written into `tmp`.
    private static func checkHasNoMedia(_ name: String, in tmp: URL) async throws {
        let project = try await GoldenDocuments.makeProject(name, in: tmp)
        let document = try GoldenDocuments.makeDocument(name, for: project)
        let plain = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        #expect(!plain.media.hasSound && plain.media.assets.isEmpty && plain.media.played.isEmpty, "\(name)")
        #expect(!plain.lacksMedia(for: document), "\(name)")
        var withGone = document
        withGone.annotations.items.append(overlay(gone, .whole, seconds: 2))
        #expect(plain.lacksMedia(for: withGone), "\(name)")
        let reference = bits(try await rendered(plain))
        let made = try await EditedMix.make(project: project, document: withGone, framesPerSecond: 60)
        #expect(made.media.assets == [gone] && !made.lacksMedia(for: withGone), "\(name)")
        for mix in [made, plain.with(document: withGone, framesPerSecond: 60), await made.with(analysis: .none)] {
            #expect(!mix.media.hasSound && mix.media.played.isEmpty, "\(name)")
            #expect(mix.playDescription == plain.playDescription, "\(name)")
            #expect(bits(try await rendered(mix)) == reference, "\(name)")
        }
    }

    /// A clip of the sequence at −6 dB plays its file over its output frames at 0.501 of its level, and the take is
    /// silent there: between its fades, each frame is the file's (its two channels' mean, in this mono mix) times the gain.
    /// The take plays on each side.
    @Test func mediaClipSoundsAtItsVolume() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "volume", seconds: 4)
            let asset = try await importedClip(dir, into: project, seconds: 2, tone: 440)
            let document = edited(project, [.take(0, 1), .media(asset, 0, 2, volume: -6), .take(1, 3)])
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 30)
            #expect(mix.channels == 1 && mix.media.hasSound)
            let gain = Float(pow(10, -6.0 / 20))
            #expect(abs(gain - 0.501) < 1e-3)
            #expect(mix.media.played == [MediaAudio.PlayedClip(
                asset: asset, frames: 48_000..<144_000, source: 0, heard: 0..<96_000, speed: 1, gain: gain)])
            let samples = try await rendered(mix)
            let file = try await fileFrames(asset, of: project, 0..<96_000)
            var worst: Float = 0, peak: Float = 0, filePeak: Float = 0
            for n in (192..<(96_000 - 192)) {
                let own = (file[2 * n] + file[2 * n + 1]) * 0.5
                worst = max(worst, abs(samples[48_000 + n] - own * gain))
                peak = max(peak, abs(samples[48_000 + n]))
                filePeak = max(filePeak, abs(own))
            }
            #expect(worst <= 1e-6, "\(worst)")
            #expect(filePeak > 0.2 && abs(peak / filePeak - 0.501) <= 1e-3, "\(peak) of \(filePeak)")
            #expect(toneAmplitude(samples, start: 0, frequency: 1_000, from: 1.1, to: 2.9) < 1e-3)
            #expect(abs(toneAmplitude(samples, start: 0, frequency: 1_000, from: 0.1, to: 0.9) - 0.25) < 0.01)
            #expect(abs(toneAmplitude(samples, start: 0, frequency: 1_000, from: 3.1, to: 4.9) - 0.25) < 0.01)
        }
    }

    /// At 2× a clip of 2 s lasts 1 s of output, and its tone keeps its pitch, 440 Hz; at 8× it lasts 0.25 s and is silent,
    /// as a clip of the take faster than 4× is.
    @Test func mediaAtSpeedIsStretchedAndSilentPast4x() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "speed", seconds: 4)
            let asset = try await importedClip(dir, into: project, seconds: 2, tone: 440)
            let twice = edited(project, [.take(0, 1), .media(asset, 0, 2, speed: 2), .take(1, 3)])
            let mix = try await EditedMix.make(project: project, document: twice, framesPerSecond: 30)
            #expect(mix.media.played.map(\.frames) == [48_000..<96_000] && mix.media.played.first?.speed == 2)
            let samples = try await rendered(mix)
            #expect(samples.count == 4 * 48_000)
            let tone = toneAmplitude(samples, start: 0, frequency: 440, from: 1.1, to: 1.9)
            #expect(abs(tone - 0.25) < 0.03, "\(tone)")
            #expect(toneAmplitude(samples, start: 0, frequency: 880, from: 1.1, to: 1.9) < 0.01)
            #expect(toneAmplitude(samples, start: 0, frequency: 1_000, from: 1.1, to: 1.9) < 0.01)
            // The take after it, from 2 s on, and nothing more of the clip.
            #expect(abs(toneAmplitude(samples, start: 0, frequency: 1_000, from: 2.1, to: 3.9) - 0.25) < 0.01)
            #expect(toneAmplitude(samples, start: 0, frequency: 440, from: 2.1, to: 3.9) < 0.005)

            let fast = edited(project, [.take(0, 1), .media(asset, 0, 2, speed: 8), .take(1, 3)])
            let silent = try await EditedMix.make(project: project, document: fast, framesPerSecond: 30)
            #expect(!silent.media.hasSound && silent.media.assets == [asset])
            let quiet = try await rendered(silent)
            #expect(quiet[48_000..<60_000].allSatisfy { $0 == 0 })
            #expect(abs(toneAmplitude(quiet, start: 0, frequency: 1_000, from: 1.35, to: 3.15) - 0.25) < 0.01)
        }
    }

    /// A clip of 2 s over output seconds [1, 5) plays once, over [1, 3), at 1× from its start, and adds nothing else:
    /// elsewhere the mix is the take's alone, bit for bit. Muted, it adds nothing at all, and the mix made for it still
    /// opened its file: unmuted in another revision, it sounds there as it does in a mix made for that (to the units in
    /// the last place two decodings of the AAC can differ by); a revision of the mix made for it sounds as it does, bit
    /// for bit.
    @Test func clipOverlaySoundsOnceAndMutes() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "overlay", seconds: 6)
            let asset = try await importedClip(dir, into: project, seconds: 2, tone: 440)
            let plain = edited(project, [.take(0, 6)])
            var over = plain
            over.annotations.items = [overlay(asset, .output(start: ns(1), end: ns(5)), seconds: 2)]
            var muted = plain
            muted.annotations.items = [overlay(asset, .output(start: ns(1), end: ns(5)), seconds: 2, muted: true)]

            let base = try await rendered(try await EditedMix.make(project: project, document: plain, framesPerSecond: 30))
            let mix = try await EditedMix.make(project: project, document: over, framesPerSecond: 30)
            #expect(mix.media.played == [MediaAudio.PlayedClip(
                asset: asset, frames: 48_000..<144_000, source: 0, heard: 0..<96_000, speed: 1, gain: 1)])
            let samples = try await rendered(mix)
            let file = try await fileFrames(asset, of: project, 0..<96_000)
            #expect(bits(samples[..<48_000]) == bits(base[..<48_000]))
            #expect(bits(samples[144_000...]) == bits(base[144_000...]))
            var worst: Float = 0
            for n in 192..<(96_000 - 192) {
                let own = (file[2 * n] + file[2 * n + 1]) * 0.5
                worst = max(worst, abs(samples[48_000 + n] - base[48_000 + n] - own))
            }
            #expect(worst <= 1e-6, "\(worst)")

            let silent = try await EditedMix.make(project: project, document: muted, framesPerSecond: 30)
            #expect(!silent.media.hasSound && silent.media.assets == [asset] && !silent.lacksMedia(for: over))
            #expect(bits(try await rendered(silent)) == bits(base))
            let unmuted = try await rendered(silent.with(document: over, framesPerSecond: 30))
            #expect(unmuted.count == samples.count && zip(unmuted, samples).allSatisfy { abs($0 - $1) <= 1e-6 })
            #expect(bits(try await rendered(mix.with(document: muted, framesPerSecond: 30))) == bits(base))
            #expect(bits(try await rendered(silent.with(document: muted, framesPerSecond: 30).with(document: over, framesPerSecond: 30)))
                == bits(unmuted))
            #expect(bits(try await rendered(mix.with(document: over, framesPerSecond: 30))) == bits(samples))
        }
    }

    /// A clip of 44.1 kHz mono in a stereo mix at 48 kHz: its tone, 660 Hz, at its level in both channels, the same in each.
    @Test func resampledAndChannelMapped() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "mono", seconds: 3, systemAudio: true)
            let asset = try await importedClip(dir, into: project, seconds: 1, tone: 660, sampleRate: 44_100, channels: 1)
            let document = edited(project, [.take(0, 1), .media(asset, 0, 1), .take(1, 2)])
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 30)
            #expect(mix.channels == 2 && mix.media.hasSound)
            let samples = try await rendered(mix)
            let left = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
            let right = stride(from: 1, to: samples.count, by: 2).map { samples[$0] }
            #expect(bits(left[48_000..<96_000]) == bits(right[48_000..<96_000]))
            for channel in [left, right] {
                let tone = toneAmplitude(channel, start: 0, frequency: 660, from: 1.1, to: 1.9)
                #expect(abs(tone - 0.25) < 0.01, "\(tone)")
                #expect(toneAmplitude(channel, start: 0, frequency: 1_000, from: 1.1, to: 1.9) < 1e-3)
            }
        }
    }

    /// A clip's sound comes in over its first 192 frames and goes out over its last 192, linearly, from 0 at its edge;
    /// between them it is its file as it is.
    @Test func fadesAtItsEdges() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "fades", seconds: 3)
            let asset = try await importedClip(dir, into: project, seconds: 1, tone: 440)
            let document = edited(project, [.take(0, 1), .media(asset, 0, 1), .take(1, 2)])
            let samples = try await rendered(try await EditedMix.make(project: project, document: document, framesPerSecond: 30))
            let file = try await fileFrames(asset, of: project, 0..<48_000)
            let own = (0..<48_000).map { (file[2 * $0] + file[2 * $0 + 1]) * 0.5 }
            let fade = Int(EditedMix.fadeFrames)
            #expect(fade == 192)
            var worst: Float = 0
            for n in 0..<48_000 {
                let into = Float(min(n, fade)) / Float(fade), out = Float(min(48_000 - 1 - n, fade)) / Float(fade)
                worst = max(worst, abs(samples[48_000 + n] - own[n] * min(into, out)))
            }
            #expect(worst <= 1e-6, "\(worst)")
            #expect(samples[48_000] == 0 && samples[48_000 + 48_000 - 1] == 0)
            #expect(own[fade..<(48_000 - fade)].contains { abs($0) > 0.2 })
        }
    }

    /// The export of a mix with clips of the sequence at 1× and at 2× and a clip over the video, with the limiter, is the
    /// same twice from 0, whole or in blocks, bit for bit; a mix made again decodes the clips again, the same to the units
    /// in the last place two decodings of the AAC can differ by. Without the limiter, a range read after a jump back is
    /// that range of the whole, bit for bit, in the stretched clip and over the video.
    @Test func exportIsDeterministic() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "again", seconds: 3, systemAudio: true)
            let asset = try await importedClip(dir, into: project, seconds: 2, tone: 440)
            let other = try await importedClip(dir, into: project, seconds: 1, tone: 660, sampleRate: 44_100, channels: 1, pattern: 1)
            var document = edited(project, [.take(0, 1), .media(asset, 0, 1), .take(1, 2), .media(asset, 0, 2, speed: 2), .take(2, 3)])
            document.annotations.items = [overlay(other, .output(start: ns(0.5), end: ns(2.5)), seconds: 1, volume: 3)]
            document.audio.limiter = true
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 30)
            #expect(mix.media.played.count == 3)
            let first = bits(try await rendered(mix))
            let twice = bits(try await rendered(mix))
            #expect(twice == first, "\(differences(twice, first))")
            let blocks = bits(try await rendered(mix, blocks: 4_800))
            #expect(blocks == first, "\(differences(blocks, first))")
            let again = try await EditedMix.make(project: project, document: document, framesPerSecond: 30)
            let remade = try await rendered(again)
            let worst = zip(remade, first).map { abs($0 - Float(bitPattern: $1)) }.max() ?? 1
            #expect(remade.count == first.count && worst <= 1e-6, "\(worst)")
            #expect(first.contains { $0 != 0 })

            var unlimited = document
            unlimited.audio.limiter = false
            let plain = mix.with(document: unlimited, framesPerSecond: 30)
            let whole = bits(try await rendered(plain))
            for range in [Int64(150_000)..<170_000, 30_000..<60_000, 0..<4_800] {
                let jumped = try await offThePool {
                    var samples: [Float] = []
                    plain.render(outputFrames: 200_000..<220_000, into: &samples)
                    plain.render(outputFrames: range, into: &samples)
                    return samples
                }
                #expect(bits(jumped) == Array(whole[(Int(range.lowerBound) * 2)..<(Int(range.upperBound) * 2)]), "\(range)")
            }
        }
    }

    /// A clip's sound decoded whole into memory gives the same bits for a range however it is read (in any order, again
    /// and again), silence outside it, and opens no file then; one longer than the most it holds, or with nothing placed,
    /// is given back as it is.
    @Test func aClipDecodedWholeReadsTheSameBits() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "whole", seconds: 1)
            let asset = try await importedClip(dir, into: project, seconds: 1, tone: 440)
            let url = try #require(project.package.mediaAsset(asset, as: .video))
            let line = try await AudioTrackTimeline.load(file: url, id: asset, channels: 2)
            let end = try #require(line.placed.last?.end)
            let whole = try await AudioTrackTimeline.decodedWhole(line)
            let frames = try #require(whole.wholeFrames)
            #expect(frames.count == Int(end) * 2 && whole.placed.count == line.placed.count && whole.track == asset)
            let reads = try await offThePool { () -> [[Float]] in
                let reader = AudioTrackTimeline.Reader(whole)
                return [Int64(30_000)..<30_480, 0..<4_800, -100..<100, (end - 50)..<(end + 50), 30_000..<30_480].map { range in
                    var samples: [Float] = []
                    reader.read(range, into: &samples)
                    return samples
                }
            }
            #expect(bits(reads[0]) == bits(frames[60_000..<60_960]) && bits(reads[4]) == bits(reads[0]))
            #expect(bits(reads[1]) == bits(frames[0..<9_600]))
            #expect(reads[2][..<200].allSatisfy { $0 == 0 } && bits(reads[2][200...]) == bits(frames[0..<200]))
            #expect(bits(reads[3][..<100]) == bits(frames[(frames.count - 100)...]) && reads[3][100...].allSatisfy { $0 == 0 })
            #expect(try await AudioTrackTimeline.decodedWhole(line, maximumFrames: end - 1).wholeFrames == nil)
            let none = try await AudioTrackTimeline.load(file: dir.appending(path: "gone.mov"), id: "gone", channels: 2)
            #expect(try await AudioTrackTimeline.decodedWhole(none).wholeFrames == nil)
        }
    }

    /// The mix lacks an imported clip when the document names a file it did not look at, in the sequence or over the video,
    /// muted or not: never one it was made with, nor one it kept from the mix of another revision.
    @Test func lacksMediaWhenTheDocumentNamesANewOne() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await voiceTake(in: dir, name: "lacks", seconds: 3)
            let asset = try await importedClip(dir, into: project, seconds: 1, tone: 440)
            let other = try await importedClip(dir, into: project, seconds: 1, tone: 660, pattern: 1)
            let plain = edited(project, [.take(0, 2)])
            let inSequence = edited(project, [.take(0, 1), .media(asset, 0, 1), .take(1, 2)])
            var overOther = plain
            overOther.annotations.items = [overlay(other, .whole, seconds: 1, muted: true)]

            let bare = try await EditedMix.make(project: project, document: plain, framesPerSecond: 30)
            #expect(!bare.lacksMedia(for: plain) && bare.lacksMedia(for: inSequence) && bare.lacksMedia(for: overOther))
            #expect(!bare.with(document: inSequence, framesPerSecond: 30).media.hasSound)

            let withAsset = try await EditedMix.make(project: project, document: inSequence, framesPerSecond: 30)
            #expect(withAsset.media.assets == [asset])
            #expect(!withAsset.lacksMedia(for: inSequence) && !withAsset.lacksMedia(for: plain))
            #expect(withAsset.lacksMedia(for: overOther))
            let kept = withAsset.with(document: plain, framesPerSecond: 30)
            #expect(!kept.lacksMedia(for: inSequence) && !kept.media.hasSound)
            #expect(kept.with(document: inSequence, framesPerSecond: 30).media.played == withAsset.media.played)
            #expect(!(await withAsset.with(analysis: .none)).lacksMedia(for: inSequence))
        }
    }
}

// MARK: - Helpers

/// A clip's path that names no file of the package.
private let gone = "assets/" + String(repeating: "f", count: 32) + ".mov"

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// `seconds` in nanoseconds.
private func ns(_ seconds: Double) -> Int64 { Int64((seconds * 1e9).rounded()) }

/// A take of `seconds` of the display and a microphone of a sine of 1 kHz at 1/4 of full scale, mono; with
/// `systemAudio`, a system audio track of the same in stereo too, which makes the mix stereo.
private func voiceTake(in dir: URL, name: String, seconds: Double, systemAudio: Bool = false) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addAudioTrack(
        id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: seconds, frequency: 1_000)])
    if systemAudio {
        try await builder.addAudioTrack(
            id: systemAudioID, kind: .systemAudio, source: systemAudioSource,
            segments: [AudioSegmentSpec(start: base, seconds: seconds, channels: 2, frequency: 1_000)])
    }
    return try builder.write()
}

/// A clip of `MediaFixtures` of `seconds` with a sine of `tone` Hz, written into `dir` and imported into `project`'s
/// package: the path the document names it by.
private func importedClip(
    _ dir: URL, into project: LoadedProject, seconds: Double, tone: Double, sampleRate: Double = 48_000, channels: Int = 2,
    pattern: Int = 0
) async throws -> String {
    let url = try MediaFixtures.clip(
        in: dir, seconds: seconds, size: SIMD2(160, 90), pattern: pattern, tone: tone, sampleRate: sampleRate, channels: channels)
    return try await MediaFixtures.imported(url, into: project, as: .video)
}

/// A clip of the sequence: a stretch of the take in seconds from its start, or an imported clip's file from `from` to
/// `to` seconds at `speed` and `volume` dB.
private enum Piece {
    case take(Double, Double)
    case media(String, Double, Double, speed: Double = 1, volume: Double = 0)
}

/// The legacy document of `project` (no limiter) with `pieces` as its sequence: each imported clip a point of the take
/// where the stretch before it ends.
private func edited(_ project: LoadedProject, _ pieces: [Piece]) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    var point = at(0)
    document.sequence = pieces.enumerated().map { k, piece in
        let id = String(format: "c-%08x", k + 1)
        switch piece {
        case let .take(from, to):
            point = at(to)
            return Clip(id: id, take: project.take.id, start: at(from), end: at(to), speed: 1)
        case let .media(asset, from, to, speed, volume):
            let media = MediaClip(asset: asset, start: ns(from), end: ns(to), speed: speed, volume: volume)
            return Clip(id: id, take: project.take.id, start: point, end: point, speed: 1, content: .media(media))
        }
    }
    document.audio.limiter = false
    return document
}

/// A clip over the video of `asset`'s first `seconds`, anchored at `anchor`.
private func overlay(
    _ asset: String, _ anchor: AnnotationAnchor, seconds: Double, volume: Double = 0, muted: Bool = false
) -> Annotation {
    Annotation(
        id: "a-00000001", anchor: anchor, layer: 0,
        kind: .clip(ClipAnnotation(asset: asset, start: 0, end: ns(seconds), volume: volume, muted: muted)),
        rect: NormalizedRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3))
}

/// Frames `frames` of `asset`'s sound as the mix reads it, in two channels: its own line, read off the pool.
private func fileFrames(_ asset: String, of project: LoadedProject, _ frames: Range<Int64>) async throws -> [Float] {
    let url = try #require(project.package.mediaAsset(asset, as: .video))
    let line = try await AudioTrackTimeline.load(file: url, id: asset, channels: 2)
    #expect(!line.placed.isEmpty)
    return try await offThePool {
        var samples: [Float] = []
        AudioTrackTimeline.Reader(line).read(frames, into: &samples)
        return samples
    }
}

/// `mix.render` of the whole mix, in one range or in `blocks` frames at a time, read off the cooperative pool.
private func rendered(_ mix: EditedMix, blocks: Int64? = nil) async throws -> [Float] {
    try await offThePool {
        var samples: [Float] = []
        guard let blocks else {
            mix.render(outputFrames: 0..<mix.totalFrames, into: &samples)
            return samples
        }
        var all: [Float] = []
        var frame: Int64 = 0
        while frame < mix.totalFrames {
            let end = min(frame + blocks, mix.totalFrames)
            mix.render(outputFrames: frame..<end, into: &samples)
            all += samples
            frame = end
        }
        return all
    }
}

private func bits(_ samples: some Collection<Float>) -> [UInt32] { samples.map(\.bitPattern) }

/// How many samples of `a` and `b` differ, and the first and last that do, for a message.
private func differences(_ a: [UInt32], _ b: [UInt32]) -> String {
    let differing = (0..<min(a.count, b.count)).filter { a[$0] != b[$0] }
    return "\(a.count) and \(b.count) samples, \(differing.count) differ, from \(differing.first ?? -1) to \(differing.last ?? -1)"
}
