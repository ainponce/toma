// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

// The clean voice of these tests is synthetic, written by the test from the dry sound as `TrackAudio` reads it (a
// negated or plain copy): none of them uses the Audio Unit. The takes are `voiceTake`'s (TrackAudioTests), their
// display from `base`, frame 0 of the mix.

/// `AudioPlan.key` of the microphone, and of system audio, of `project`'s take.
private func micKey(_ project: LoadedProject) -> String { AudioPlan.key(take: project.take.id, track: micID) }
private func systemKey(_ project: LoadedProject) -> String { AudioPlan.key(take: project.take.id, track: systemAudioID) }

/// Writes `samples` as the cleanup caches hold the clean voice: CAF, Float32 LPCM, mono, 48 kHz.
private func writeCleanFile(_ samples: [Float], to url: URL) throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

/// The clean voice of the microphone of `project`: for each segment heard, a file in `dir` of `transform` of its dry
/// frames as `TrackAudio` reads them in mono, `shortenedBy` frames shorter for the segment `shortened` names.
private func cleanVoice(
    of project: LoadedProject, in dir: URL, shortenedBy: Int = 0, shortened: Int = 0, _ transform: @escaping @Sendable (Float) -> Float
) async throws -> CleanVoice {
    let audio = try await TrackAudio.load(project, track: micID, channels: 1)
    var files: [String: URL] = [:]
    for (k, span) in audio.spans.enumerated() {
        let dry = try await voiceRead(audio, span.frames)
        let url = dir.appending(path: "clean-\(k)-soundIsolation-1.caf")
        try writeCleanFile(Array((k == shortened ? dry.dropLast(shortenedBy) : dry[...]).map(transform)), to: url)
        files[span.segment] = url
    }
    return CleanVoice(files: files)
}

/// What the mix reads of the caches: the microphone's clean voice and loudness, when given.
private func inputs(_ project: LoadedProject, clean: CleanVoice? = nil, loudness: TrackLoudness? = nil) -> AnalysisInputs {
    var inputs = AnalysisInputs()
    if let clean { inputs.cleanVoice[micKey(project)] = clean }
    if let loudness { inputs.loudness[micKey(project)] = loudness }
    return inputs
}

/// The legacy document of `project` with the microphone at gain 1 and `cleanup`, `normalize` and the limiter as given,
/// and its clips at `speed` over `clips` (seconds from the take's start) when given.
private func document(
    _ project: LoadedProject, cleanup: Double, normalize: Bool = false, limiter: Bool = false,
    clips: [(from: Double, to: Double)]? = nil, speed: Double = 1
) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.audio.tracks[micKey(project)] = TrackGain(gain: 1, muted: false, cleanup: cleanup)
    document.audio.normalize = normalize
    document.audio.limiter = limiter
    if let clips {
        document.sequence = clips.enumerated().map { i, span in
            Clip(id: String(format: "c-%08x", i + 1), take: project.take.id, start: voiceAt(span.from), end: voiceAt(span.to), speed: speed)
        }
    }
    return document
}

/// `mix.render` of `frames` (by default the whole mix), read off the cooperative pool.
private func rendered(_ mix: EditedMix, _ frames: Range<Int64>? = nil) async throws -> [Float] {
    let range = frames ?? 0..<mix.totalFrames
    return try await offThePool {
        var samples: [Float] = []
        mix.render(outputFrames: range, into: &samples)
        return samples
    }
}

private func bits(_ samples: [Float]) -> [UInt32] { samples.map { ($0 + 0).bitPattern } }

/// The largest difference between two lists of samples of the same length.
private func largestDifference(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "\(a.count) samples against \(b.count)")
    return zip(a, b).map { abs($0 - $1) }.max() ?? 0
}

/// A loudness measure of a mono track of `blocks` blocks all at `lufs` (dry), and its clean voice's at `wetLUFS`.
private func flatLoudness(_ lufs: Double, wet wetLUFS: Double? = nil, blocks: Int = 30) -> TrackLoudness {
    func energy(_ lufs: Double) -> Double { pow(10, (lufs + 0.691) / 10) }
    let wet = wetLUFS.map { Array(repeating: energy($0), count: blocks) }
    return TrackLoudness(
        channels: 1, dry: Array(repeating: energy(lufs), count: blocks), wet: wet,
        cross: wet.map { _ in Array(repeating: 0, count: blocks) })
}

// MARK: - The clean voice in the mix

/// With the cleanup at 0 the clean voice is not heard: the samples of the mix without the analysis, and no track mixed
/// clean, whether the plan names the cleanup or not.
@Test func cleanupZeroIsTheLegacyMix() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "zero", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2, transform: voiceNoise)])
        let clean = try await cleanVoice(of: project, in: dir) { -$0 }
        let legacy = EditDocument.legacy(for: project)
        let plain = try await EditedMix.make(project: project, document: legacy, framesPerSecond: 60)
        let reference = try await rendered(plain)
        #expect(reference.contains { $0 != 0 })
        for document in [legacy, document(project, cleanup: 0)] {
            let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60, analysis: inputs(project, clean: clean))
            #expect(mix.cleanTracks.isEmpty)
            #expect(bits(try await rendered(mix)) == bits(reference))
        }
    }
}

/// The clean voice is read frame for frame where the dry sound is, segment by segment (two, with a pause between them):
/// a clean voice that is the dry one negated gives, at cleanup 1, the mix negated, and at 0.6, 0.4 − 0.6 = −0.2 times it,
/// in a revision made from the mix too, and a range read on its own is the range of the whole.
@Test func cleanTimelineIsAlignedFrameForFrame() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "aligned", seconds: 3.5, mic: [
            AudioSegmentSpec(start: base, seconds: 1.5, transform: voiceNoise),
            AudioSegmentSpec(start: voiceAt(2), seconds: 1.5, transform: voiceNoise),
        ])
        let clean = try await cleanVoice(of: project, in: dir) { -$0 }
        let analysis = inputs(project, clean: clean)
        let dry = try await rendered(try await EditedMix.make(project: project, document: document(project, cleanup: 0), framesPerSecond: 60))
        #expect(dry.contains { $0 != 0 })
        let full = try await EditedMix.make(project: project, document: document(project, cleanup: 1), framesPerSecond: 60, analysis: analysis)
        #expect(full.cleanTracks == [micKey(project)])
        let wet = try await rendered(full)
        #expect(largestDifference(wet, dry.map { -$0 }) < 1e-6)
        let gentle = full.with(document: document(project, cleanup: 0.6), framesPerSecond: 60)
        #expect(gentle.cleanTracks == [micKey(project)])
        #expect(largestDifference(try await rendered(gentle), dry.map { -0.2 * $0 }) < 1e-6)
        // A range of the second segment, read by a mix that read nothing before.
        let again = try await EditedMix.make(project: project, document: document(project, cleanup: 1), framesPerSecond: 60, analysis: analysis)
        let range: Range<Int64> = 130_000..<131_000
        #expect(bits(try await rendered(again, range)) == bits(Array(wet[Int(range.lowerBound)..<Int(range.upperBound)])))
    }
}

/// The clean line reads each file from anywhere, as the dry stream does: a reader asked for a frame in the middle starts
/// the file near it, not from its start, and gives the file's frames there; the line has the dry one's segments.
@Test func cleanLineReadsTheFileFromAnywhere() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "seek", seconds: 4, mic: [AudioSegmentSpec(start: base, seconds: 4, transform: voiceNoise)])
        let clean = try await cleanVoice(of: project, in: dir) { $0 * 0.5 }
        let audio = try await TrackAudio.load(project, track: micID, channels: 1)
        let line = try #require(await AudioTrackTimeline.cleaned(audio.timeline, files: clean.files, channels: 1))
        #expect(line.placed.map { $0.start..<$0.end } == audio.spans.map(\.frames))
        let frames: Range<Int64> = 150_000..<151_000
        let (read, opening) = try await offThePool {
            let reader = AudioTrackTimeline.Reader(line)
            var samples: [Float] = []
            reader.read(frames, into: &samples)
            return (samples, reader.lastOpening)
        }
        #expect(try #require(opening) > 0)
        let dry = try await voiceRead(audio, frames)
        #expect(bits(read) == bits(dry.map { $0 * 0.5 }))
        // A stereo line has the mono voice on both channels.
        let stereo = try #require(await AudioTrackTimeline.cleaned(audio.timeline, files: clean.files, channels: 2))
        let both = try await offThePool {
            let reader = AudioTrackTimeline.Reader(stereo)
            var samples: [Float] = []
            reader.read(frames, into: &samples)
            return samples
        }
        #expect(bits(both) == bits(read.flatMap { [$0, $0] }))
    }
}

/// A microphone at 44.1 kHz and one at 16 kHz (a Bluetooth one), the second after a gap of 10 ms that the mix closes:
/// the clean voice stays on the dry sound frame for frame, resampled as it is.
@Test func resampledAndClosedGapSegmentsStayAligned() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "rates", seconds: 3, mic: [
            AudioSegmentSpec(start: base, seconds: 1.5, sampleRate: 44_100, transform: voiceNoise),
            AudioSegmentSpec(start: voiceAt(1.51), seconds: 1.49, sampleRate: 16_000, transform: voiceNoise),
        ])
        let audio = try await TrackAudio.load(project, track: micID, channels: 1)
        #expect(audio.spans.count == 2 && audio.spans[1].frames.lowerBound == audio.spans[0].frames.upperBound)
        let clean = try await cleanVoice(of: project, in: dir) { -$0 }
        let dry = try await rendered(try await EditedMix.make(project: project, document: document(project, cleanup: 0), framesPerSecond: 60))
        let mix = try await EditedMix.make(
            project: project, document: document(project, cleanup: 1), framesPerSecond: 60, analysis: inputs(project, clean: clean))
        #expect(mix.cleanTracks == [micKey(project)])
        let wet = try await rendered(mix)
        #expect(dry.contains { $0 != 0 })
        #expect(largestDifference(wet, dry.map { -$0 }) < 1e-6)
    }
}

/// A clip at 2× stretches the clean voice with a stretch of its own, as it stretches the dry sound: with a clean voice
/// that is the dry one, cleanup 1 gives the samples of cleanup 0, bit for bit.
@Test func stretchedClipsMixWetAndDryAlike() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "stretch", seconds: 4, mic: [AudioSegmentSpec(start: base, seconds: 4, transform: voiceNoise)])
        let clean = try await cleanVoice(of: project, in: dir) { $0 }
        let clips = [(from: 0.5, to: 3.5)]
        let dry = try await rendered(try await EditedMix.make(
            project: project, document: document(project, cleanup: 0, clips: clips, speed: 2), framesPerSecond: 60))
        let mix = try await EditedMix.make(
            project: project, document: document(project, cleanup: 1, clips: clips, speed: 2), framesPerSecond: 60,
            analysis: inputs(project, clean: clean))
        #expect(mix.cleanTracks == [micKey(project)])
        let wet = try await rendered(mix)
        #expect(dry.contains { $0 != 0 })
        #expect(bits(wet) == bits(dry))
        // Half and half of the same sound is the same sound, within rounding.
        let half = try await rendered(mix.with(document: document(project, cleanup: 0.5, clips: clips, speed: 2), framesPerSecond: 60))
        #expect(largestDifference(half, dry) < 1e-6)
    }
}

/// A clean file one frame shorter than its segment's span is stale: the track sounds dry and is not mixed clean.
@Test func staleCleanFileIsIgnored() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "stale", seconds: 3, mic: [
            AudioSegmentSpec(start: base, seconds: 1.5, transform: voiceNoise),
            AudioSegmentSpec(start: voiceAt(2), seconds: 1, transform: voiceNoise),
        ])
        let stale = try await cleanVoice(of: project, in: dir, shortenedBy: 1, shortened: 1) { -$0 }
        let dry = try await rendered(try await EditedMix.make(project: project, document: document(project, cleanup: 0), framesPerSecond: 60))
        let mix = try await EditedMix.make(
            project: project, document: document(project, cleanup: 1), framesPerSecond: 60, analysis: inputs(project, clean: stale))
        #expect(mix.cleanTracks.isEmpty)
        #expect(bits(try await rendered(mix)) == bits(dry))
        // A segment without its file: the same.
        let first = try #require(project.take.tracks.first { $0.id == micID }?.segments.first?.file)
        let partial = CleanVoice(files: stale.files.filter { $0.key == first })
        let without = try await EditedMix.make(
            project: project, document: document(project, cleanup: 1), framesPerSecond: 60, analysis: inputs(project, clean: partial))
        #expect(without.cleanTracks.isEmpty)
        #expect(bits(try await rendered(without)) == bits(dry))
        // A link is never followed, even to a file that would do.
        let good = try await cleanVoice(of: project, in: dir.appending(path: "good", directoryHint: .isDirectory).creatingDirectory()) { -$0 }
        let direct = try await EditedMix.make(
            project: project, document: document(project, cleanup: 1), framesPerSecond: 60, analysis: inputs(project, clean: good))
        #expect(direct.cleanTracks == [micKey(project)])
        let link = dir.appending(path: "link.caf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try #require(good.files[first]))
        var linked = good.files
        linked[first] = link
        let throughLink = try await EditedMix.make(
            project: project, document: document(project, cleanup: 1), framesPerSecond: 60,
            analysis: inputs(project, clean: CleanVoice(files: linked)))
        #expect(throughLink.cleanTracks.isEmpty)
    }
}

/// `with(analysis:)` reads the same dry source, without decoding it again, and mixes what `make` with that analysis
/// mixes.
@Test func withAnalysisDoesNotDecodeAgain() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "with", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2, transform: voiceNoise)])
        let clean = try await cleanVoice(of: project, in: dir) { -$0 }
        let analysis = inputs(project, clean: clean, loudness: flatLoudness(-30, wet: -24))
        let made = try await EditedMix.make(project: project, document: document(project, cleanup: 0.6, normalize: true), framesPerSecond: 60, analysis: analysis)
        let dry = try await EditedMix.make(project: project, document: document(project, cleanup: 0.6, normalize: true), framesPerSecond: 60)
        #expect(dry.prereadSegments == 1 && dry.cleanTracks.isEmpty)
        let with = await dry.with(analysis: analysis)
        #expect(with.prereadSegments == 0 && with.analysis == analysis && with.cleanTracks == [micKey(project)])
        #expect(bits(try await rendered(with)) == bits(try await rendered(made)))
        // The loudness alone changes: the mix follows the new measure.
        var louder = analysis
        louder.loudness[micKey(project)] = flatLoudness(-20, wet: -14)
        let relevelled = await with.with(analysis: louder)
        #expect(relevelled.cleanTracks == [micKey(project)])
        let remade = try await EditedMix.make(
            project: project, document: document(project, cleanup: 0.6, normalize: true), framesPerSecond: 60, analysis: louder)
        #expect(bits(try await rendered(relevelled)) == bits(try await rendered(remade)))
        // And back to nothing.
        let none = await with.with(analysis: .none)
        #expect(none.cleanTracks.isEmpty)
        #expect(bits(try await rendered(none)) == bits(try await rendered(dry)))
    }
}

/// The clean files gone while the mix plays (macOS emptied the caches): from the next range on the track sounds dry, at
/// the gain that normalizes it dry, never silent.
@Test func purgedCacheSoundsDry() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "purged", seconds: 3, mic: [AudioSegmentSpec(start: base, seconds: 3, transform: voiceNoise)])
        let clean = try await cleanVoice(of: project, in: dir) { -$0 }
        let dry = try await rendered(try await EditedMix.make(project: project, document: document(project, cleanup: 0), framesPerSecond: 60))
        let mix = try await EditedMix.make(
            project: project, document: document(project, cleanup: 1), framesPerSecond: 60, analysis: inputs(project, clean: clean))
        let first: Range<Int64> = 0..<48_000
        let before = try await rendered(mix, first)
        #expect(bits(before) == bits(dry[0..<48_000].map { -$0 }))
        for url in clean.files.values { try FileManager.default.removeItem(at: url) }
        let rest: Range<Int64> = 48_000..<mix.totalFrames
        #expect(bits(try await rendered(mix, rest)) == bits(Array(dry[48_000...])))
        // Normalized, the dry gain: from the measure of the dry sound, +2 dB from −18 (not the clean voice's −4 dB).
        let normalized = try await EditedMix.make(
            project: project, document: document(project, cleanup: 1, normalize: true), framesPerSecond: 60,
            analysis: inputs(project, clean: try await cleanVoice(of: project, in: dir) { -$0 }, loudness: flatLoudness(-18, wet: -12)))
        #expect(largestDifference(try await rendered(normalized, first), dry[0..<48_000].map { -$0 * Float(pow(10, -4.0 / 20)) }) < 1e-6)
        for url in clean.files.values { try FileManager.default.removeItem(at: url) }
        let level = try await rendered(normalized, 60_000..<61_000)
        #expect(largestDifference(level, dry[60_000..<61_000].map { $0 * Float(pow(10, 2.0 / 20)) }) < 1e-6)
    }
}

// MARK: - Normalizing

/// A track measured under −60 LUFS is left as it is: the samples of the mix without normalizing (whose limiter
/// Normalize turns on, and which is under its ceiling here).
@Test func silentTrackIsLeftAlone() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "silent", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2, amplitude: 0.001)])
        let plain = try await rendered(try await EditedMix.make(project: project, document: document(project, cleanup: 0), framesPerSecond: 60))
        let limited = try await rendered(try await EditedMix.make(
            project: project, document: document(project, cleanup: 0, limiter: true), framesPerSecond: 60))
        let normalized = try await rendered(try await EditedMix.make(
            project: project, document: document(project, cleanup: 0, normalize: true), framesPerSecond: 60,
            analysis: inputs(project, loudness: flatLoudness(-65))))
        #expect(plain.contains { $0 != 0 })
        #expect(bits(normalized) == bits(limited))
        #expect(bits(normalized) == bits(plain))
    }
}

/// A microphone measured at −50 LUFS would need +34 dB to reach −16: it gets 20, ×10.
@Test func gainIsCappedAt20dB() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "cap", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2, amplitude: 0.01)])
        let plain = try await rendered(try await EditedMix.make(project: project, document: document(project, cleanup: 0), framesPerSecond: 60))
        let mix = try await EditedMix.make(
            project: project, document: document(project, cleanup: 0, normalize: true), framesPerSecond: 60,
            analysis: inputs(project, loudness: flatLoudness(-50)))
        let normalized = try await rendered(mix)
        #expect(plain.contains { $0 != 0 })
        #expect(largestDifference(normalized, plain.map { $0 * 10 }) < 1e-6)
        // From −30, +14 dB.
        let revision = mix.with(document: document(project, cleanup: 0, normalize: true), framesPerSecond: 60)
        let fourteen = try await rendered(await revision.with(analysis: inputs(project, loudness: flatLoudness(-30))))
        #expect(largestDifference(fourteen, plain.map { $0 * Float(pow(10, 14.0 / 20)) }) < 1e-6)
    }
}

/// With Normalize on, the limiter works though `audio.limiter` is off: a track that peaks at 0 dBFS, with no measure
/// yet and brought up 14 dB, never goes past the ceiling, where without Normalize it does.
@Test func normalizeTurnsTheLimiterOn() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "limit", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2, amplitude: 1)])
        let plain = try await rendered(try await EditedMix.make(project: project, document: document(project, cleanup: 0), framesPerSecond: 60))
        #expect((plain.map(abs).max() ?? 0) > PeakLimiter.ceiling + 0.05)
        for loudness in [nil, flatLoudness(-30)] {
            let mix = try await EditedMix.make(
                project: project, document: document(project, cleanup: 0, normalize: true, limiter: false), framesPerSecond: 60,
                analysis: inputs(project, loudness: loudness))
            let samples = try await rendered(mix)
            #expect((samples.map(abs).max() ?? 1) <= PeakLimiter.ceiling)
            #expect((samples.map(abs).max() ?? 0) > PeakLimiter.ceiling - 0.01)
        }
    }
}

/// A mono microphone in a stereo mix (with system audio, muted) plays on both channels: its measure counts it as it
/// plays (`m` = 2, `n` = 1), so the mix it normalizes measures −16 LUFS, not the 3 dB less a mono count would give.
@Test func monoInStereoIsMeasuredAsItPlays() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(
            in: dir, name: "stereo", seconds: 6, mic: [AudioSegmentSpec(start: base, seconds: 6, amplitude: 0.05)],
            systemAudio: [AudioSegmentSpec(start: base, seconds: 6, channels: 2, frequency: 660)])
        let audio = try await TrackAudio.load(project, track: micID)
        #expect(audio.channels == 1 && audio.spans.count == 1)
        let segment = try await Loudness.measure(audio, span: audio.spans[0], clean: nil)
        let loudness = TrackLoudness(channels: segment.channels, dry: segment.dry, wet: nil, cross: nil)
        var normalized = document(project, cleanup: 0, normalize: true)
        normalized.audio.tracks[systemKey(project)] = TrackGain(gain: 1, muted: true)
        let mix = try await EditedMix.make(
            project: project, document: normalized, framesPerSecond: 60, analysis: inputs(project, loudness: loudness))
        #expect(mix.channels == 2)
        let samples = try await rendered(mix)
        let channels = (0..<2).map { c in stride(from: c, to: samples.count, by: 2).map { samples[$0] } }
        let measured = try #require(Loudness.integrated(Loudness.blockEnergies(channels)))
        #expect(abs(measured - -16) < 0.05)
    }
}

/// Normalizing waits for the whole measure: without the track's loudness, or with only its dry blocks while it is
/// mixed clean, the track gets no gain of its own (and the limiter is on).
@Test func normalizeWaitsForTheWholeMeasure() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "wait", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2, amplitude: 0.05)])
        let clean = try await cleanVoice(of: project, in: dir) { $0 }
        let limited = try await rendered(try await EditedMix.make(
            project: project, document: document(project, cleanup: 0, limiter: true), framesPerSecond: 60))
        let missing = try await EditedMix.make(
            project: project, document: document(project, cleanup: 0, normalize: true), framesPerSecond: 60, analysis: inputs(project))
        #expect(bits(try await rendered(missing)) == bits(limited))
        // Mixed clean, with a measure of the dry sound only: no gain either.
        let dryOnly = try await EditedMix.make(
            project: project, document: document(project, cleanup: 1, normalize: true), framesPerSecond: 60,
            analysis: inputs(project, clean: clean, loudness: flatLoudness(-30)))
        #expect(dryOnly.cleanTracks == [micKey(project)])
        #expect(bits(try await rendered(dryOnly)) == bits(limited))
    }
}

/// The measure is that of what plays: mixed clean (cleanup 1), the clean voice's blocks (−20 LUFS, +4 dB); with its clean
/// file stale, the track sounds dry and the dry blocks count (−30 LUFS, +14 dB).
@Test func normalizeMeasuresWhatPlays() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await voiceTake(in: dir, name: "plays", seconds: 2, mic: [AudioSegmentSpec(start: base, seconds: 2, amplitude: 0.02)])
        let plain = try await rendered(try await EditedMix.make(project: project, document: document(project, cleanup: 0), framesPerSecond: 60))
        let clean = try await cleanVoice(of: project, in: dir) { $0 }
        let cleaned = try await rendered(try await EditedMix.make(
            project: project, document: document(project, cleanup: 1, normalize: true), framesPerSecond: 60,
            analysis: inputs(project, clean: clean, loudness: flatLoudness(-30, wet: -20))))
        #expect(largestDifference(cleaned, plain.map { $0 * Float(pow(10, 4.0 / 20)) }) < 1e-6)
        let stale = try await cleanVoice(of: project, in: dir.appending(path: "stale", directoryHint: .isDirectory).creatingDirectory(), shortenedBy: 1) { $0 }
        let dry = try await rendered(try await EditedMix.make(
            project: project, document: document(project, cleanup: 1, normalize: true), framesPerSecond: 60,
            analysis: inputs(project, clean: stale, loudness: flatLoudness(-30, wet: -20))))
        #expect(largestDifference(dry, plain.map { $0 * Float(pow(10, 14.0 / 20)) }) < 1e-6)
    }
}

private extension URL {
    /// The directory at this URL, made now.
    func creatingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
