// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import Testing

/// `seconds` of two full-scale tones added together (440 Hz and 1000 Hz, peaks near 2), the same on every channel, then
/// `quietSeconds` of the 440 Hz tone alone at 0.5: interleaved, at 48 kHz.
private func loudThenQuiet(seconds: Double, quietSeconds: Double = 0, channels: Int) -> [Float] {
    let loud = Int(seconds * 48_000), quiet = Int(quietSeconds * 48_000)
    var samples: [Float] = []
    samples.reserveCapacity((loud + quiet) * channels)
    for n in 0..<(loud + quiet) {
        let t = Double(n) / 48_000
        let value = n < loud ? sin(2 * .pi * 440 * t) + sin(2 * .pi * 1000 * t) : 0.5 * sin(2 * .pi * 440 * t)
        samples.append(contentsOf: repeatElement(Float(value), count: channels))
    }
    return samples
}

/// Two tones at full scale add up to nearly 2: the limiter holds every sample at −1 dBFS, and the same input gives the
/// same bits, whether it comes in one piece or in blocks of any size (its state goes on from one call to the next).
@Test func limiterCeilsAtMinusOneDBAndIsDeterministic() {
    #expect(PeakLimiter.ceiling == 0.8912509 && PeakLimiter.lookaheadFrames == 240 && PeakLimiter.releaseFrames == 2_400)
    for channels in [1, 2] {
        let input = loudThenQuiet(seconds: 1, channels: channels)
        var whole = input
        var limiter = PeakLimiter(channels: channels)
        limiter.process(&whole)
        #expect(whole.count == input.count)
        let peak = whole.map(abs).max() ?? 0
        #expect(peak <= PeakLimiter.ceiling + 1e-6, "\(channels) channel(s): peak \(peak)")
        #expect(peak > PeakLimiter.ceiling - 0.01, "\(channels) channel(s): it limits, it does not just turn the sound down")

        var again = input
        var other = PeakLimiter(channels: channels)
        other.process(&again)
        #expect(again.map(\.bitPattern) == whole.map(\.bitPattern), "\(channels) channel(s): the same bits twice")

        // In blocks of uneven sizes, one limiter for all of them.
        var blocks = PeakLimiter(channels: channels)
        var pieces: [Float] = []
        var start = 0, size = 1
        while start < input.count / channels {
            let end = min(start + size, input.count / channels)
            var block = Array(input[(start * channels)..<(end * channels)])
            blocks.process(&block)
            pieces += block
            start = end
            size = size * 7 % 4_093 + 1
        }
        #expect(pieces.map(\.bitPattern) == whole.map(\.bitPattern), "\(channels) channel(s): block by block")
    }
}

/// Below the ceiling the limiter changes nothing but the time: every sample comes out `lookaheadFrames` later, the same
/// bits; after a loud stretch the gain comes back within a few release times.
@Test func limiterIsTransparentBelowTheCeilingAndReleases() {
    let lookahead = PeakLimiter.lookaheadFrames
    for channels in [1, 2] {
        // 0.8 of full scale, under the ceiling.
        let quiet = (0..<24_000).flatMap { n in repeatElement(Float(0.8 * sin(2 * .pi * 440 * Double(n) / 48_000)), count: channels) }
        var output = quiet
        var limiter = PeakLimiter(channels: channels)
        limiter.process(&output)
        #expect(output[..<(lookahead * channels)].allSatisfy { $0 == 0 }, "\(channels) channel(s): the delay starts silent")
        #expect(
            Array(output[(lookahead * channels)...]).map(\.bitPattern) == Array(quiet[..<(quiet.count - lookahead * channels)]).map(\.bitPattern),
            "\(channels) channel(s): the input, \(lookahead) frames later")

        // Half a second loud, then 1.5 s quiet: 0.5 s (ten release times) after the loud part, the quiet tone is back
        // as it came in.
        let input = loudThenQuiet(seconds: 0.5, quietSeconds: 1.5, channels: channels)
        var limited = input
        var other = PeakLimiter(channels: channels)
        other.process(&limited)
        let from = 48_000 + lookahead, delayed = lookahead * channels
        var largest: Float = 0
        for i in (from * channels)..<limited.count { largest = max(largest, abs(limited[i] - input[i - delayed])) }
        #expect(largest < 1e-3, "\(channels) channel(s): \(largest) off the input after the release")
    }
}

/// Two limiters that saw different sounds settle on the same one: given the same frames for `settleFrames`, they give
/// the same bits from there on, whether those frames pass the ceiling all along or are under it.
@Test func limitersWithDifferentPastsSettleOnTheSameBits() {
    let settle = PeakLimiter.settleFrames
    for channels in [1, 2] {
        // Loud all along; quiet; and quiet, then loud again once the release has landed.
        let quiet = loudThenQuiet(seconds: 0, quietSeconds: 1.5, channels: channels)
        let common = [loudThenQuiet(seconds: 2, channels: channels), quiet, quiet + loudThenQuiet(seconds: 1, channels: channels)]
        for later in common {
            var a = PeakLimiter(channels: channels), b = PeakLimiter(channels: channels)
            var pastA = loudThenQuiet(seconds: 0.7, quietSeconds: 0.1, channels: channels).map { $0 * 1.7 }
            var pastB = loudThenQuiet(seconds: 0, quietSeconds: 0.4, channels: channels)
            a.process(&pastA)
            b.process(&pastB)
            var outA = later, outB = later
            a.process(&outA)
            b.process(&outB)
            let from = (settle + 1) * channels
            #expect(bits(outA[from...]) == bits(outB[from...]), "\(channels) channel(s)")
            #expect(bits(outA[..<(PeakLimiter.lookaheadFrames * channels)]) != bits(outB[..<(PeakLimiter.lookaheadFrames * channels)]), "they did start apart")
        }
    }
}

private func bits(_ samples: some Collection<Float>) -> [UInt32] { samples.map(\.bitPattern) }
