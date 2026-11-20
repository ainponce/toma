// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

// The fixture of a take is `CacheFixture` (ThumbnailCacheTests.swift).

/// A theme's file as the music library writes it (`MusicFile`, plan 3c decision 4), made here byte by byte so the test
/// needs nothing of `Export`: `caff`, its `desc` (48 kHz linear PCM, 32-bit floats, little-endian, two channels) and its
/// `data`, then the samples, interleaved.
private func ourCAF(interleaved samples: [Float]) -> Data {
    var bytes: [UInt8] = []
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }
    bytes += Array("caff".utf8)
    append(UInt16(1))
    append(UInt16(0))
    bytes += Array("desc".utf8)
    append(Int64(32))
    append(Double(48_000).bitPattern)
    bytes += Array("lpcm".utf8)
    append(UInt32(3))
    append(UInt32(8))
    append(UInt32(1))
    append(UInt32(2))
    append(UInt32(32))
    bytes += Array("data".utf8)
    append(Int64(4 + 4 * samples.count))
    append(UInt32(0))
    for sample in samples {
        withUnsafeBytes(of: sample.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }
    return Data(bytes)
}

@Test func waveformOfOurFileAndOfAnAsset() async throws {
    try await withTemporaryDirectory { dir in
        // Our file: 2 s of a 440 Hz sine at 0.5 on both channels, 100 pairs a second, each about ±0.5.
        let frames = 96_000
        var samples: [Float] = []
        samples.reserveCapacity(2 * frames)
        for frame in 0..<frames {
            let value = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame) / 48_000))
            samples += [value, value]
        }
        let theme = dir.appending(path: "calm.caf")
        try ourCAF(interleaved: samples).write(to: theme)
        let waveform = await AudioFileWaveform.waveform(of: theme)
        #expect(waveform.pairs.count == 200)
        #expect(waveform.pairs.allSatisfy { abs($0.x + 0.5) <= 0.01 && abs($0.y - 0.5) <= 0.01 })

        // A take's .m4a: the pairs the timeline's cache works out for its track (its one segment starts at its origin).
        let project = try await CacheFixture.package(in: dir)
        let segment = try #require(project.take.track("mic-1")?.segments.first)
        let m4a = project.package.fileURL(segment.file)
        let fromFile = await AudioFileWaveform.waveform(of: m4a)
        let fromCache = await WaveformCache(project: project, caches: CacheFixture.caches(project, in: dir)).waveform(track: "mic-1")
        #expect(fromFile.pairs.count == 100)
        #expect(fromFile == fromCache)

        // Rubbish, nothing there, a folder and a link are empty.
        let rubbish = dir.appending(path: "rubbish.m4a")
        try Data("not a sound".utf8).write(to: rubbish)
        #expect(await AudioFileWaveform.waveform(of: rubbish).pairs.isEmpty)
        #expect(await AudioFileWaveform.waveform(of: dir.appending(path: "missing.caf")).pairs.isEmpty)
        #expect(await AudioFileWaveform.waveform(of: dir).pairs.isEmpty)
        let link = dir.appending(path: "link.caf")
        #expect(symlink(theme.path, link.path) == 0)
        #expect(await AudioFileWaveform.waveform(of: link).pairs.isEmpty)
    }
}
