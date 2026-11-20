// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// The volume of a range of a track in the mix (phase 3 design §7.2 and §13, plan 3c task U5 and decision 9): over the
/// source `[start, end)` of its take a track sounds at the range's gain, from −∞ (`GainRange.silence`) to +12 dB, with
/// linear ramps in amplitude of 50 ms of source inside each edge (meeting in the middle of a shorter one), following the
/// sound through the cuts, the speeds and the cuts of the sound moved; two that overlap multiply, one that is not a
/// number does not count, and a range of one take leaves every other take alone. Without ranges and without cuts of the
/// sound moved, the mix is the base's.
///
/// The takes start their display at `base`, frame 0 of the take's timeline and the start of its legacy document; their
/// microphone is a sine of 1 kHz at 1/2 of full scale (`sineTake`).
@Suite struct RangeVolumeMixTests {
    /// Each case of golden 3 that mixes, as it is and with edits that change nothing: its sound starts where its clips
    /// do (`AudioCuts` as the base had them, with the takes' bounds now), no range changes a track, and its samples are
    /// those of the same document with a range at 0 dB over all of each track, a range where nothing of the take is
    /// heard and a cut of the sound moved at its first clip (which never moves).
    @Test func noRangesNoShiftsIsTheBase() async throws {
        let cases = GoldenDocuments.golden3Cases.filter(\.mixes).map(\.name)
        #expect(!cases.isEmpty)
        try await withTemporaryDirectory { tmp in
            try await withThrowingTaskGroup { group in
                for name in cases { group.addTask { try await Self.checkIsTheBase(name, in: tmp) } }
                try await group.waitForAll()
            }
        }
    }

    /// `noRangesNoShiftsIsTheBase` of the golden case `name`, its project written into `tmp`.
    private static func checkIsTheBase(_ name: String, in tmp: URL) async throws {
        let project = try await GoldenDocuments.makeProject(name, in: tmp)
        let document = try GoldenDocuments.makeDocument(name, for: project)
        let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
        let timeMap = TimeMap(sequence: document.sequence)
        var neutral = document
        for key in neutral.audio.tracks.keys {
            neutral.audio.tracks[key]?.ranges = [
                GainRange(id: "g-00000001", take: project.take.id, start: HostTime(nanoseconds: 0), end: HostTime(nanoseconds: .max), gain: 0),
                GainRange(id: "g-00000002", take: project.take.id, start: HostTime(nanoseconds: 1), end: HostTime(nanoseconds: 1_000_000_000), gain: -6),
            ]
        }
        neutral.sequence[0].audioShift = 300_000_000
        let edited = mix.with(document: neutral, framesPerSecond: 60)
        for each in [mix, edited] {
            #expect(each.cuts.starts == timeMap.clipOutputStarts.map(EditedMix.frames(ofNanoseconds:)), "\(name)")
            #expect(each.cuts.sourceShift == Array(repeating: 0, count: document.sequence.count), "\(name)")
            #expect(each.gainRanges.isEmpty, "\(name)")
        }
        #expect(edited.playDescription == mix.playDescription, "\(name)")
        #expect(bits(try await rendered(edited)) == bits(try await rendered(mix)), "\(name)")
    }

    /// −6 dB over the source [1, 2) s: the sine at 0.501 of its level over [1.05, 1.95] s, linear ramps in amplitude of
    /// 50 ms inside each edge, and the samples of the mix without the range outside it, bit for bit.
    @Test func aRangeScalesItsSpanWithFiftyMillisecondRamps() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sineTake(in: dir, name: "range")
            let plain = try await EditedMix.make(project: project, document: edited(project, [(0, 3)]), framesPerSecond: 60)
            let mix = plain.with(document: edited(project, [(0, 3)], ranges: [(1, 2, -6)]), framesPerSecond: 60)
            #expect(!mix.gainRanges.isEmpty)
            let (reference, ranged) = (try await rendered(plain), try await rendered(mix))
            try #require(reference.count == 144_000 && ranged.count == 144_000)
            let amplitude = Float(pow(10, -6.0 / 20))
            var worst: Float = 0, worstFlat: Float = 0
            for frame in 0..<144_000 {
                let gain = expectedGain(Double(frame) / 48_000, [(1, 2, -6)])
                worst = max(worst, abs(ranged[frame] - reference[frame] * Float(gain)))
                if (50_400...93_600).contains(frame) { worstFlat = max(worstFlat, abs(ranged[frame] - reference[frame] * amplitude)) }
            }
            #expect(worst <= 1e-6 && worstFlat <= 1e-6, "\(worst), \(worstFlat) in [1.05, 1.95] s")
            // Halfway through each ramp, halfway in amplitude.
            #expect(abs(expectedGain(1.025, [(1, 2, -6)]) - (1 + pow(10, -6.0 / 20)) / 2) < 1e-9)
            #expect(bits(ranged[..<48_000]) == bits(reference[..<48_000]) && bits(ranged[96_000...]) == bits(reference[96_000...]))
        }
    }

    /// A range at −∞ dB (`GainRange.silence`, and lower or −∞ in a document edited by hand) is silence over its flat part;
    /// one whose gain is not a number does not count.
    @Test func minusInfinityIsSilence() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sineTake(in: dir, name: "silence")
            let plain = try await EditedMix.make(project: project, document: edited(project, [(0, 3)]), framesPerSecond: 60)
            let reference = try await rendered(plain)
            for gain: Double in [GainRange.silence, -300, -Double.infinity] {
                let silent = try await rendered(plain.with(document: edited(project, [(0, 3)], ranges: [(1, 2, gain)]), framesPerSecond: 60))
                #expect(silent[50_400...93_600].allSatisfy { abs($0) <= 1e-6 }, "\(gain)")
                #expect(bits(silent[..<48_000]) == bits(reference[..<48_000]), "\(gain)")
            }
            let notANumber = plain.with(document: edited(project, [(0, 3)], ranges: [(1, 2, .nan)]), framesPerSecond: 60)
            #expect(notANumber.gainRanges.isEmpty)
            #expect(bits(try await rendered(notANumber)) == bits(reference))
        }
    }

    /// A range follows the sound: over a cut only what is kept of it is heard lower, with no ramp at the cut; at 2× its
    /// ramps of 50 ms of source are 25 ms of output; and with an L cut the source the clip before is heard on with is
    /// lower where a range is.
    @Test func aRangeFollowsTheCutsAndTheSpeed() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sineTake(in: dir, name: "follow")
            // [0, 1) s and [2, 3) s, −6 dB over [0.5, 2.5) s of the source: output [0.5, 1.5) s.
            let cut = try await EditedMix.make(project: project, document: edited(project, [(0, 1), (2, 3)]), framesPerSecond: 60)
            let overTheCut = cut.with(document: edited(project, [(0, 1), (2, 3)], ranges: [(0.5, 2.5, -6)]), framesPerSecond: 60)
            #expect(try await worstOff(overTheCut, from: cut, ranges: [(0.5, 2.5, -6)]) { $0 < 1 ? $0 : $0 + 1 } <= 1e-6)

            // [0, 3) s at 2×, −6 dB over [1, 2) s of the source: output [0.5, 1) s, with ramps of 25 ms.
            var fast = edited(project, [(0, 3)])
            fast.sequence[0].speed = 2
            let stretched = try await EditedMix.make(project: project, document: fast, framesPerSecond: 60)
            var fastRanged = edited(project, [(0, 3)], ranges: [(1, 2, -6)])
            fastRanged.sequence[0].speed = 2
            #expect(try await worstOff(stretched.with(document: fastRanged, framesPerSecond: 60), from: stretched, ranges: [(1, 2, -6)]) {
                $0 * 2
            } <= 1e-6)
            #expect(abs(expectedGain(2 * 0.5125, [(1, 2, -6)]) - (1 + pow(10, -6.0 / 20)) / 2) < 1e-9, "halfway at 12.5 ms")

            // An L cut of 0.2 s at clip 1: the source [1.0, 1.2) s, cut without it, is heard and its range with it.
            let lCut = edited(project, [(0, 1), (2, 3)], shifts: [1: 200_000_000])
            let heard = cut.with(document: lCut, framesPerSecond: 60)
            var lCutRanged = edited(project, [(0, 1), (2, 3)], ranges: [(1.0, 1.2, GainRange.silence)])
            lCutRanged.sequence[1].audioShift = 200_000_000
            let lowered = try await rendered(cut.with(document: lCutRanged, framesPerSecond: 60))
            #expect(lowered[50_400...55_200].allSatisfy { abs($0) <= 1e-6 }, "[1.05, 1.15] s")
            #expect(try await worstOff(cut.with(document: lCutRanged, framesPerSecond: 60), from: heard, ranges: [(1.0, 1.2, GainRange.silence)]) {
                $0 < 1.2 ? $0 : $0 + 1
            } <= 1e-6)
            // Without the L cut that source is cut, and so is its range.
            let unheard = cut.with(document: edited(project, [(0, 1), (2, 3)], ranges: [(1.0, 1.2, GainRange.silence)]), framesPerSecond: 60)
            #expect(unheard.gainRanges.isEmpty)
        }
    }

    /// A range is of its take: in a sequence of `take-001` and `take-002`, one in `take-002/mic` (the key whose gain
    /// `take-001`'s microphone also takes) silences only `take-002`, one in `take-001/mic` only `take-001`, and a range
    /// of `take-001` put by hand in `take-002/mic` none of them.
    @Test func rangesOfOneTakeLeaveTheOther() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            let plain = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            let reference = try await rendered(plain)
            try #require(reference.count == 192_000)
            func ranged(key take: String, range rangeTake: String) -> EditDocument {
                var ranged = document
                let start = (rangeTake == "take-001" ? document.sequence[0] : document.sequence[1]).start
                let key = AudioPlan.key(take: take, track: micID)
                let own = ranged.audio.tracks[key] ?? TrackGain(gain: 1, muted: false)
                ranged.audio.tracks[key] = TrackGain(
                    gain: own.gain, muted: own.muted, cleanup: own.cleanup,
                    ranges: [GainRange(id: "g-00000001", take: rangeTake, start: start.adding(seconds: -1), end: start.adding(seconds: 3), gain: GainRange.silence)])
                return ranged
            }
            let second = try await rendered(plain.with(document: ranged(key: "take-002", range: "take-002"), framesPerSecond: 60))
            #expect(bits(second[..<96_000]) == bits(reference[..<96_000]) && second[96_000...].allSatisfy { $0 == 0 })
            let first = try await rendered(plain.with(document: ranged(key: "take-001", range: "take-001"), framesPerSecond: 60))
            #expect(first[..<96_000].allSatisfy { $0 == 0 } && bits(first[96_000...]) == bits(reference[96_000...]))
            let mismatched = try await rendered(plain.with(document: ranged(key: "take-002", range: "take-001"), framesPerSecond: 60))
            #expect(bits(mismatched) == bits(reference))
        }
    }

    /// A range over all of a take's source, `0 ..< UInt64.max` as the solo puts it, is flat wherever the take is heard,
    /// in every clip and at every speed, without trapping: silence at −∞, and the sound at 0.501 at −6 dB.
    @Test func aRangeOverTheWholeTakeIsFlat() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sineTake(in: dir, name: "whole")
            var document = edited(project, [(0, 1), (1.5, 3)], shifts: [1: 200_000_000])
            document.sequence[1].speed = 2
            let plain = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            let reference = try await rendered(plain)
            for (gain, amplitude) in [(GainRange.silence, Float(0)), (-6, Float(pow(10, -6.0 / 20)))] {
                var whole = document
                whole.audio.tracks[AudioPlan.key(take: takeID, track: micID)]?.ranges = [
                    GainRange(id: "g-00000001", take: takeID, start: HostTime(nanoseconds: 0), end: HostTime(nanoseconds: .max), gain: gain)
                ]
                let mix = plain.with(document: whole, framesPerSecond: 60)
                #expect(!mix.gainRanges.isEmpty)
                let flat = try await rendered(mix)
                #expect(flat.count == reference.count)
                let worst = zip(flat, reference).map { abs($0 - $1 * amplitude) }.max() ?? .infinity
                #expect(worst <= 1e-6, "\(gain) dB: \(worst)")
            }
        }
    }

    /// The preview hears the ranges as the export does: the mix of another revision (`with(document:)`) and the samples
    /// the export's encoder gets are the mix made for the document, bit for bit, with ranges over a cut, at 2×, with an L
    /// cut and the limiter.
    @Test func previewEqualsExportWithRanges() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sineTake(in: dir, name: "parity")
            var document = edited(project, [(0, 1), (1.5, 3)], ranges: [(0.5, 2, -9), (2.2, 2.6, 6)], shifts: [1: 250_000_000])
            document.sequence[1].speed = 2
            document.audio.limiter = true
            let made = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
            let reference = try await rendered(made)
            let preview = try await EditedMix.make(project: project, document: edited(project, [(0, 3)]), framesPerSecond: 60)
                .with(document: document, framesPerSecond: 60)
            #expect(bits(try await rendered(preview)) == bits(reference))
            let exported = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 60)
            #expect(bits(exported) == bits(reference))
        }
    }
}

// MARK: - Helpers

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// A take of 3 s of the display and a microphone of a sine of 1 kHz at 1/2 of full scale.
private func sineTake(in dir: URL, name: String) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 3, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addAudioTrack(
        id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3, frequency: 1_000, amplitude: 0.5)])
    return try builder.write()
}

/// The legacy document of `project` with its clips over `spans` (seconds from the take's start) at 1×, the ranges
/// `ranges` (from, to in seconds of the source, gain in dB) on its microphone, and the cut of the sound of clip `k` moved
/// by `shifts[k]` ns.
private func edited(
    _ project: LoadedProject, _ spans: [(Double, Double)], ranges: [(Double, Double, Double)] = [], shifts: [Int: Int64] = [:]
) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.sequence = spans.enumerated().map { k, span in
        Clip(id: String(format: "c-%08x", k + 1), take: project.take.id, start: at(span.0), end: at(span.1), speed: 1,
             audioShift: shifts[k] ?? 0)
    }
    let key = AudioPlan.key(take: project.take.id, track: micID)
    document.audio.tracks[key, default: TrackGain(gain: 1, muted: false)].ranges = ranges.enumerated().map { i, range in
        GainRange(id: String(format: "g-%08x", i + 1), take: project.take.id, start: at(range.0), end: at(range.1), gain: range.2)
    }
    return document
}

/// The gain at source second `x` of the ranges `ranges` (from, to, dB), as the design gives it: each one's amplitude
/// (0 at −120 dB and below), reached linearly over 50 ms inside each edge, the ramps meeting in the middle of a shorter
/// one; their product.
private func expectedGain(_ x: Double, _ ranges: [(Double, Double, Double)]) -> Double {
    ranges.reduce(1) { product, range in
        let amplitude = range.2 <= GainRange.silence ? 0 : pow(10, range.2 / 20)
        let into = min(x - range.0, range.1 - x)
        guard into > 0 else { return product }
        return product * (1 + (amplitude - 1) * min(into / 0.05, 1))
    }
}

/// The largest difference between the samples of `mix` and those of `plain` (the same document without `ranges`)
/// times `ranges`' gain at the source second `source(o)` that each output second `o` plays.
private func worstOff(
    _ mix: EditedMix, from plain: EditedMix, ranges: [(Double, Double, Double)], source: (Double) -> Double
) async throws -> Float {
    let (ranged, reference) = (try await rendered(mix), try await rendered(plain))
    guard ranged.count == reference.count else { return .infinity }
    var worst: Float = 0
    for frame in reference.indices {
        let gain = expectedGain(source(Double(frame) / 48_000), ranges)
        worst = max(worst, abs(ranged[frame] - reference[frame] * Float(gain)))
    }
    return worst
}

/// `mix.render` of the whole mix, read off the cooperative pool.
private func rendered(_ mix: EditedMix) async throws -> [Float] {
    try await offThePool {
        var samples: [Float] = []
        mix.render(outputFrames: 0..<mix.totalFrames, into: &samples)
        return samples
    }
}

private func bits(_ samples: some Collection<Float>) -> [UInt32] { samples.map(\.bitPattern) }
