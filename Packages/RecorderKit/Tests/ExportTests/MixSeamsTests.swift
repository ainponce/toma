// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// The seams of the mix that phase 3 fills (base plan task B9, design §13 and §14): the cut of the sound (`AudioCuts`),
/// the volume of a range (`GainRangePlan`), the sound of the imported clips (`MediaAudio`) and the music (`MusicMix`),
/// empty in the base and wired into `EditedMix`, so a document of phase 1 or 2 sounds as it did; and a file of audio as a
/// line of its own (`AudioTrackTimeline.load(file:id:channels:)`), for the imported clips and the music.
@Suite struct MixSeamsTests {
    /// Each case of golden 3 that mixes has nothing of phase 3 in its mix: its sound starts where its clips do, from the
    /// source frame of each clip's start, no range changes a track's volume, and there is no imported clip nor music to
    /// hear; so it has sound as phase 2's mix did, its tracks and its clicks. Also in the mixes of another revision and of
    /// another analysis. The samples are `make golden-3`'s. The cases are written and mixed at once, each on its own.
    @Test func legacyMixHasNoPhase3Part() async throws {
        let cases = GoldenDocuments.golden3Cases.filter(\.mixes).map(\.name)
        #expect(!cases.isEmpty)
        try await withTemporaryDirectory { tmp in
            try await withThrowingTaskGroup { group in
                for name in cases { group.addTask { try await Self.checkHasNoPhase3Part(name, in: tmp) } }
                try await group.waitForAll()
            }
        }
    }

    /// `legacyMixHasNoPhase3Part` of the golden case `name`, its project written into `tmp`.
    private static func checkHasNoPhase3Part(_ name: String, in tmp: URL) async throws {
        let project = try await GoldenDocuments.makeProject(name, in: tmp)
        let document = try GoldenDocuments.makeDocument(name, for: project)
        let made = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let timeMap = TimeMap(sequence: document.sequence)
        let hasTracks = project.take.tracks.contains { !$0.kind.isVideo }
        for mix in [made, made.with(document: document, framesPerSecond: 60), await made.with(analysis: .none)] {
            #expect(mix.cuts.starts == timeMap.clipOutputStarts.map(EditedMix.frames(ofNanoseconds:)), "\(name)")
            #expect(mix.cuts.sourceShift == Array(repeating: 0, count: document.sequence.count), "\(name)")
            #expect(mix.gainRanges.isEmpty, "\(name)")
            #expect(!mix.media.hasSound && !mix.music.hasSound, "\(name)")
            // As phase 2 had it: its tracks or its clicks.
            #expect(mix.hasSound == (hasTracks || !mix.clickFrames.isEmpty) && mix.hasSound, "\(name)")
            #expect(mix.playDescription == made.playDescription, "\(name)")
        }
    }

    /// Without a cut of the sound moved, the sound of each clip starts where `TimeMap` puts the clip, in frames at
    /// 48 kHz, and reads its source from the clip's own start: 50 random sequences of two takes, with speeds from 0.25×
    /// to 16× and clips with content among them.
    @Test func cutsFollowTimeMapWithoutShifts() {
        var generator = SplitMix64(seed: 0x6D69_7853_6561_6D73)
        var document = EditDocument.legacy(
            take: TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: []), events: [])
        for round in 0..<50 {
            document.sequence = randomSequence(using: &generator)
            let timeMap = TimeMap(sequence: document.sequence)
            let cuts = AudioCuts(document: document, timeMap: timeMap)
            #expect(cuts.starts == timeMap.clipOutputStarts.map(EditedMix.frames(ofNanoseconds:)), "round \(round)")
            #expect(cuts.sourceShift == Array(repeating: 0, count: document.sequence.count), "round \(round)")
            #expect(GainRangePlan(document: document, timeMap: timeMap, keys: [["take-001/mic"], ["take-002/mic"]]).isEmpty)
        }
    }

    /// A file of audio is a line of one segment from frame 0 on, read as it is at 48 kHz: the CAF of a theme of the
    /// library (`MusicFile`), stereo, gives its own samples bit for bit, from its start or from its middle, and silence
    /// before and after it.
    @Test func aFileIsOneSegmentFromZero() async throws {
        try await withTemporaryDirectory { dir in
            var interleaved: [Float] = []
            for i in 0..<48_000 {
                let value = Float(i % 1_000 + 1) / 2_000
                interleaved += [value, -value]
            }
            let url = dir.appendingPathComponent("theme.caf")
            try MusicFile.write(interleaved: interleaved, to: url)
            let line = try await AudioTrackTimeline.load(file: url, id: "mu-00000001", channels: 2)
            #expect(line.track == "mu-00000001" && line.channels == 2 && line.missing.isEmpty)
            #expect(line.placed.count == 1 && line.placed.first?.start == 0 && line.placed.first?.end == 48_000)
            let whole = try await read(line, -100..<48_100)
            #expect(whole[..<200].allSatisfy { $0 == 0 } && whole[(200 + 96_000)...].allSatisfy { $0 == 0 })
            #expect(bitsOf(whole[200..<(200 + 96_000)]) == bitsOf(interleaved))
            let middle = try await read(line, 30_000..<30_480)
            #expect(bitsOf(middle) == bitsOf(interleaved[60_000..<60_960]))
        }
    }

    /// A mono file goes to both channels of a stereo mix, and stays mono in a mono one.
    @Test func aMonoFileFillsTheMixChannels() async throws {
        try await withTemporaryDirectory { dir in
            let samples = (0..<24_000).map { (i: Int) -> Float in
                let phase = Double(i) * 2 * Double.pi * 440 / 48_000
                return Float(sin(phase) * 0.25)
            }
            let url = dir.appendingPathComponent("voice.wav")
            try writeMonoWAV(samples, to: url)
            let stereo = try await read(try await AudioTrackTimeline.load(file: url, id: "a", channels: 2), 0..<24_000)
            #expect(bitsOf(stride(from: 0, to: stereo.count, by: 2).map { stereo[$0] }) == bitsOf(samples))
            #expect(bitsOf(stride(from: 1, to: stereo.count, by: 2).map { stereo[$0] }) == bitsOf(samples))
            let mono = try await read(try await AudioTrackTimeline.load(file: url, id: "a", channels: 1), 0..<24_000)
            #expect(bitsOf(mono) == bitsOf(samples))
        }
    }

    /// A file that cannot be heard is silence, and says why: a link (never followed), a file that is not there, one of 0
    /// bytes and one that is not audio. Nothing of it is placed.
    @Test func aFileThatCannotBeHeardIsSilence() async throws {
        try await withTemporaryDirectory { dir in
            let audio = dir.appendingPathComponent("voice.wav")
            try writeMonoWAV([Float](repeating: 0.1, count: 4_800), to: audio)
            let link = dir.appendingPathComponent("link.wav")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: audio)
            let empty = dir.appendingPathComponent("empty.wav")
            try Data().write(to: empty)
            let text = dir.appendingPathComponent("text.wav")
            try Data("not audio".utf8).write(to: text)
            let cases: [(URL, MissingAudio.Reason?)] = [
                (link, nil), (dir.appendingPathComponent("gone.wav"), .fileMissing), (empty, .empty), (text, nil),
            ]
            for (url, reason) in cases {
                let line = try await AudioTrackTimeline.load(file: url, id: "a", channels: 1)
                #expect(line.placed.isEmpty, "\(url.lastPathComponent)")
                #expect(line.missing.count == 1 && line.missing.first?.file == url.lastPathComponent, "\(url.lastPathComponent)")
                let found = try #require(line.missing.first?.reason)
                if let reason {
                    #expect(found == reason, "\(url.lastPathComponent)")
                } else if case .cannotOpen = found {
                } else {
                    Issue.record("\(url.lastPathComponent): \(found)")
                }
                #expect(try await read(line, 0..<4_800).allSatisfy { $0 == 0 })
            }
        }
    }
}

// MARK: - Helpers

/// Frames `frames` of `line`, read off the cooperative pool by a reader of its own.
private func read(_ line: AudioTrackTimeline, _ frames: Range<Int64>) async throws -> [Float] {
    try await offThePool {
        var samples: [Float] = []
        AudioTrackTimeline.Reader(line).read(frames, into: &samples)
        return samples
    }
}

private func bitsOf(_ samples: some Collection<Float>) -> [UInt32] { samples.map(\.bitPattern) }

/// Writes `samples` as a mono WAV of Float32 at 48 kHz, closed once it returns.
private func writeMonoWAV(_ samples: [Float], to url: URL) throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample }
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

/// A sequence of up to 12 clips of `take-001` and `take-002`, each in its take's source order, at speeds from 0.25× to
/// 16× (some read clamped from out of the range), with a frozen frame, a title card or an imported clip now and then,
/// and every cut of the sound where the picture cuts.
private func randomSequence(using generator: inout SplitMix64) -> [Clip] {
    let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 4, 8, 16, 0.1, 40]
    var next: [String: UInt64] = ["take-001": 5_000_000_000_000, "take-002": 5_060_000_000_000]
    return (0..<Int.random(in: 1...12, using: &generator)).map { k in
        let take = Bool.random(using: &generator) ? "take-001" : "take-002"
        let start = next[take]! + UInt64.random(in: 0...2_000_000_000, using: &generator)
        let end = start + UInt64.random(in: 1...6_000_000_000, using: &generator)
        let speed = speeds[Int.random(in: 0..<speeds.count, using: &generator)]
        let id = "c-" + String(format: "%08x", k + 1)
        let content: ClipContent?
        switch Int.random(in: 0..<8, using: &generator) {
        case 0: content = .freeze(duration: Int64.random(in: 1...70_000_000_000, using: &generator))
        case 1:
            let duration = Int64.random(in: 1...5_000_000_000, using: &generator)
            content = .card(TitleCard(title: "Title", style: .centered, background: .stage), duration: duration)
        case 2:
            content = .media(MediaClip(
                asset: "assets/" + String(repeating: "a", count: 32) + ".mov", start: 0,
                end: Int64.random(in: -1...4_000_000_000, using: &generator), speed: speed))
        default: content = nil
        }
        next[take] = content == nil ? end : start
        return Clip(id: id, take: take, start: HostTime(nanoseconds: start), end: HostTime(nanoseconds: content == nil ? end : start),
                    speed: speed, content: content)
    }
}

/// The SplitMix64 generator (Steele, Lea and Flood), for a fixed seed's sequence of numbers on every run.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
