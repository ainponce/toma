// SPDX-License-Identifier: GPL-3.0-or-later
import Export
import Testing

/// Each click sound is a function of its id: the same samples on every call, short, quiet enough to sit under speech,
/// and clean at its edges (it starts and ends at 0 and has no DC), so it never clicks by itself.
@Test func clickSoundsAreDeterministicAndClean() throws {
    #expect(ClickSounds.ids == ["soft-1", "mechanical-1"])
    var sounds: [[Float]] = []
    for id in ClickSounds.ids {
        let samples = try #require(ClickSounds.samples(id), "\(id)")
        #expect(ClickSounds.samples(id).map { $0.map(\.bitPattern) } == samples.map(\.bitPattern), "\(id): the same bits twice")
        #expect(!samples.isEmpty && samples.count <= 2_880, "\(id): \(samples.count) samples, at most 60 ms")
        let peak = samples.map(abs).max() ?? 0
        #expect(peak <= 0.5 && peak >= 0.1, "\(id): peak \(peak)")
        #expect(samples.first?.bitPattern == 0 && samples.last?.bitPattern == 0, "\(id): starts and ends at +0")
        let mean = samples.reduce(0) { $0 + Double($1) } / Double(samples.count)
        #expect(abs(mean) < 1e-3, "\(id): mean \(mean)")
        #expect(samples.allSatisfy { $0.isFinite }, "\(id)")
        sounds.append(samples)
    }
    #expect(sounds.count == 2 && sounds[0] != sounds[1], "two different sounds")
    // Two clicks the mix plays as one: 40 ms of output.
    #expect(ClickSounds.minimumSpacing == 40_000_000)
    for id in ["none", "soft-2", "", "ripple-1"] {
        #expect(ClickSounds.samples(id) == nil, "\(id)")
    }
}
