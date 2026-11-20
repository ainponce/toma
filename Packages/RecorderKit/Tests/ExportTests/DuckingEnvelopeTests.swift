// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import Testing

private func seconds(_ s: Double) -> Int64 { Int64((s * 48_000).rounded()) }
private let voice: Range<Int64> = 96_000..<144_000

@Test func disabledOrNoVoiceIsUnity() {
    let off = DuckingEnvelope(voiced: [voice], ducking: Ducking(enabled: false))
    let none = DuckingEnvelope(voiced: [], ducking: .default)
    let zero = DuckingEnvelope(voiced: [voice], ducking: Ducking(amount: 0))
    for envelope in [off, none, zero] {
        #expect(envelope.isUnity)
        #expect(envelope.runs.isEmpty)
        for f: Int64 in [-5, 0, 100_000, 120_000, 1_000_000] { #expect(envelope.gain(atFrame: f) == 1) }
    }
    #expect(!DuckingEnvelope(voiced: [voice], ducking: .default).isUnity)
}

@Test func reachesTheAmountAtTheVoice() {
    let envelope = DuckingEnvelope(voiced: [voice], ducking: .default)
    #expect(envelope.runs == [voice])
    for f in stride(from: voice.lowerBound, to: voice.upperBound, by: 997) { #expect(envelope.decibels(atFrame: f) == -12) }
    #expect(envelope.decibels(atFrame: voice.upperBound - 1) == -12)
    // The attack: 0.3 s before the voice is 0 dB, half way is −6 dB.
    #expect(envelope.decibels(atFrame: voice.lowerBound - seconds(0.3)) == 0)
    #expect(envelope.decibels(atFrame: voice.lowerBound - seconds(0.15)) == -6)
    #expect(envelope.decibels(atFrame: voice.lowerBound - seconds(0.3) - 1) == 0)
    // The release: 0.8 s after the voice is 0 dB again.
    #expect(envelope.decibels(atFrame: voice.upperBound) == -12)
    #expect(envelope.decibels(atFrame: voice.upperBound + seconds(0.4)) == -6)
    #expect(envelope.decibels(atFrame: voice.upperBound + seconds(0.8)) == 0)
    #expect(envelope.decibels(atFrame: voice.upperBound + seconds(5)) == 0)
    // Straight in dB between.
    #expect(abs(envelope.decibels(atFrame: voice.lowerBound - seconds(0.075)) + 9) < 1e-9)
    #expect(abs(Double(envelope.gain(atFrame: voice.lowerBound)) - pow(10, -12.0 / 20)) < 1e-6)
    #expect(envelope.gain(atFrame: 0) == 1)
}

@Test func gapsUnderPointFourSecondsClose() {
    let a = 0..<seconds(1)
    let close = DuckingEnvelope(voiced: [a, (a.upperBound + seconds(0.39))..<seconds(3)], ducking: .default)
    #expect(close.runs == [0..<seconds(3)])
    let apart = DuckingEnvelope(voiced: [a, (a.upperBound + seconds(0.41))..<seconds(3)], ducking: .default)
    #expect(apart.runs.count == 2)
    // Out of order and overlapping inputs are the same.
    let mixed = DuckingEnvelope(voiced: [seconds(2)..<seconds(3), 0..<seconds(2.5), 0..<seconds(1)], ducking: .default)
    #expect(mixed.runs == [0..<seconds(3)])
}

@Test func shortBlipsDoNotDuck() {
    #expect(DuckingEnvelope(voiced: [96_000..<(96_000 + seconds(0.14))], ducking: .default).isUnity)
    #expect(!DuckingEnvelope(voiced: [96_000..<(96_000 + seconds(0.16))], ducking: .default).isUnity)
    // A blip near a voice joins it; a blip far from one is still ignored.
    let joined = DuckingEnvelope(voiced: [0..<seconds(1), seconds(1.2)..<(seconds(1.2) + seconds(0.1))], ducking: .default)
    #expect(joined.runs == [0..<(seconds(1.3))])
    let far = DuckingEnvelope(voiced: [0..<seconds(1), seconds(3)..<(seconds(3) + seconds(0.1))], ducking: .default)
    #expect(far.runs == [0..<seconds(1)])
}

@Test func rampsTakeTheDeepest() {
    // Two runs 0.9 s apart: the release of the first (0.8 s) and the attack of the second (0.3 s) overlap.
    let first = 0..<seconds(1), second = seconds(1.9)..<seconds(3)
    let envelope = DuckingEnvelope(voiced: [first, second], ducking: .default)
    #expect(envelope.runs.count == 2)
    for f in stride(from: first.upperBound, to: second.lowerBound, by: 313) {
        let release = -12 * Double(seconds(0.8) - (f - first.upperBound)) / Double(seconds(0.8))
        let attack = -12 * Double(seconds(0.3) - (second.lowerBound - f)) / Double(seconds(0.3))
        let expected = min(release > 0 ? 0 : release, attack > 0 ? 0 : attack)
        #expect(envelope.decibels(atFrame: f) == expected)
        #expect(envelope.decibels(atFrame: f) < 0)
    }
}

@Test func settingsAreHeld() {
    let deep = DuckingEnvelope(voiced: [voice], ducking: Ducking(amount: -90))
    #expect(deep.decibels(atFrame: 100_000) == -40)
    let nan = DuckingEnvelope(voiced: [voice], ducking: Ducking(amount: .nan, attack: .nan, release: .nan))
    #expect(nan.decibels(atFrame: 100_000) == -12)
    #expect(nan.decibels(atFrame: voice.lowerBound - seconds(0.15)) == -6)
    #expect(nan.decibels(atFrame: voice.upperBound + seconds(0.4)) == -6)
    let slow = DuckingEnvelope(voiced: [voice], ducking: Ducking(release: 10))
    #expect(slow.decibels(atFrame: voice.upperBound + seconds(2)) == -6)
    #expect(slow.decibels(atFrame: voice.upperBound + seconds(4)) == 0)
    let quick = DuckingEnvelope(voiced: [voice], ducking: Ducking(attack: 0))
    #expect(quick.decibels(atFrame: voice.lowerBound - seconds(0.05)) == 0)
    #expect(quick.decibels(atFrame: voice.lowerBound - seconds(0.025)) == -6)
    #expect(DuckingEnvelope(voiced: [voice], ducking: Ducking(amount: 5)).isUnity)
}

@Test func gainsAreGainAtFrame() {
    let envelope = DuckingEnvelope(voiced: [voice, 200_000..<260_000, 400_000..<420_000], ducking: .default)
    var generator = SplitMix(seed: 0x70_6D61)
    var gains: [Float] = []
    for _ in 0..<10_000 {
        let start = Int64(generator.next() % 600_000) - 20_000
        let count = Int(generator.next() % 40) + 1
        envelope.gains(start..<(start + Int64(count)), into: &gains)
        #expect(gains.count == count)
        for (i, g) in gains.enumerated() { #expect(g.bitPattern == envelope.gain(atFrame: start + Int64(i)).bitPattern) }
    }
    let quiet = DuckingEnvelope(voiced: [], ducking: .default)
    quiet.gains(5..<9, into: &gains)
    #expect(gains == [1, 1, 1, 1])
}

@Test func theSameInputGivesTheSameBytes() {
    func bits() -> [UInt32] {
        let envelope = DuckingEnvelope(voiced: [voice, seconds(4)..<seconds(6), seconds(6.2)..<seconds(7)], ducking: .default)
        var gains: [Float] = []
        envelope.gains(0..<seconds(9), into: &gains)
        return gains.map(\.bitPattern)
    }
    #expect(bits() == bits())
}

/// A tiny generator with a fixed seed, so the "random" frames are the same every run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
