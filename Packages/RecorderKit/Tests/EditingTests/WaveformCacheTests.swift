// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// @testable only for `WaveformCache.decodedSegments`, which counts the segments decoded: the rest is the public API the
// timeline uses.
@testable import Editing
import ProjectFormat

// The fixture is `CacheFixture` (ThumbnailCacheTests.swift).

/// Whether every pair of `pairs` is the sine of the fixture: a minimum of −0.25 and a maximum of 0.25, ± 0.01.
private func isTheSine(_ pairs: some Collection<SIMD2<Float>>) -> Bool {
    !pairs.isEmpty && pairs.allSatisfy { abs($0.x + 0.25) <= 0.01 && abs($0.y - 0.25) <= 0.01 }
}

@Test func waveformIsMinMaxPer10ms() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await CacheFixture.package(in: dir)
        let caches = CacheFixture.caches(project, in: dir)
        let cache = WaveformCache(project: project, caches: caches)

        let waveform = await cache.waveform(track: "mic-1")
        #expect(waveform.pairs.count == 100)
        #expect(isTheSine(waveform.pairs))
        #expect(CacheFixture.files(in: caches.waveforms) == ["take-001-mic-1-seg-0001.bin"])

        // Once per segment: asked again, by this cache or another one of the project, it is read from the file.
        #expect(await cache.waveform(track: "mic-1") == waveform)
        let reopened = WaveformCache(project: project, caches: caches)
        #expect(await reopened.waveform(track: "mic-1") == waveform)
        #expect(await cache.decodedSegments == 1)
        #expect(await reopened.decodedSegments == 0)

        // A video track has no waveform.
        #expect(await cache.waveform(track: "display-1").pairs.isEmpty)
        #expect(await cache.waveform(track: "mic-9").pairs.isEmpty)
    }
}

@Test func segmentsArePlacedByTheirHostTime() async throws {
    try await withTemporaryDirectory { dir in
        // 0.5 s, a pause of 0.5 s and 0.5 s more.
        let project = try await CacheFixture.package(in: dir, videoSeconds: 1.5, audio: [
            AudioSegmentSpec(start: CacheFixture.base, seconds: 0.5),
            AudioSegmentSpec(start: CacheFixture.base.adding(seconds: 1), seconds: 0.5),
        ])
        let caches = CacheFixture.caches(project, in: dir)
        let waveform = await WaveformCache(project: project, caches: caches).waveform(track: "mic-1")

        #expect(waveform.pairs.count == 150)
        #expect(isTheSine(waveform.pairs[0..<50]))
        #expect(waveform.pairs[50..<100].allSatisfy { $0 == .zero })
        #expect(isTheSine(waveform.pairs[100..<150]))
        #expect(CacheFixture.files(in: caches.waveforms) == ["take-001-mic-1-seg-0001.bin", "take-001-mic-1-seg-0002.bin"])
    }
}

@Test func aDamagedWaveformFileIsDecodedAgain() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await CacheFixture.package(in: dir)
        let caches = CacheFixture.caches(project, in: dir)
        let waveform = await WaveformCache(project: project, caches: caches).waveform(track: "mic-1")
        let file = caches.waveforms.appending(path: "take-001-mic-1-seg-0001.bin")
        let bytes = try Data(contentsOf: file)

        for damaged in [bytes.prefix(bytes.count - 3), Data("not a waveform".utf8), bytes.prefix(8)] {
            try damaged.write(to: file)
            let cache = WaveformCache(project: project, caches: caches)
            #expect(await cache.waveform(track: "mic-1") == waveform)
            #expect(await cache.decodedSegments == 1)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
}
