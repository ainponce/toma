// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
import Recording
import SyntheticCapture
import Testing

/// An arbitrary host time well after boot, so "relative to the first sample" is visible in the file.
private let base = HostTime(nanoseconds: 1_234_000_000_000)

private func frame(_ i: Int, at seconds: Double) -> CMSampleBuffer {
    SampleFactory.videoSample(width: 640, height: 360, pts: base.adding(seconds: seconds), frameIndex: i)
}

/// Like `frame`, optionally carrying an explicit duration of 1/30 s, as ScreenCaptureKit frames may.
private func frame(_ i: Int, at seconds: Double, carryingDuration: Bool) throws -> CMSampleBuffer {
    let sample = frame(i, at: seconds)
    guard carryingDuration else { return sample }
    let timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: sample.presentationTimeStamp, decodeTimeStamp: .invalid
    )
    return try CMSampleBuffer(copying: sample, withNewTiming: [timing])
}

@Test func bitrateFormula() {
    #expect(VideoBitrate.averageBitRate(width: 3024, height: 1964, framesPerSecond: 60) == 17_817_408)
}

@Test func writesReadableHEVCRelativeToFirstSample() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("seg-0001.mov")
        let w = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: 30), realTime: false)
        var started: [HostTime] = []
        w.onStart = { started.append($0) }
        for i in 0..<90 { try w.append(frame(i, at: Double(i) / 30)) }
        let r = try await w.finish(at: base.adding(seconds: 3))
        #expect(r.startHostTime == base && r.sampleCount == 90 && r.droppedSampleCount == 0)
        #expect(r.endHostTime == base.adding(seconds: 3) && r.heartbeatSampleCount == 0)
        #expect(started == [base])
        #expect(w.failure == nil)
        let source = try #require(w.formatDescription)
        #expect(CMVideoFormatDescriptionGetDimensions(source).width == 640)

        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.05)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.timeRange).start == .zero)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(try await decodedFrameIndices(of: url) == (0..<90).map { $0 % 64 })
    }
}

@Test(arguments: [false, true]) func finishHoldsLastFrameUntilStopTime(framesCarryDuration: Bool) async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("seg-0001.mov")
        let w = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: 30), realTime: false)
        for i in 0..<10 { try w.append(frame(i, at: Double(i) / 10, carryingDuration: framesCarryDuration)) }
        let r = try await w.finish(at: base.adding(seconds: 5))
        #expect(r.startHostTime == base && r.endHostTime == base.adding(seconds: 5))
        #expect(r.sampleCount == 10 && r.droppedSampleCount == 0 && r.heartbeatSampleCount == 0)
        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 5) < 0.05)
        // The last frame itself lasts until the stop time, not just the edit list.
        #expect(abs(try await videoMediaEnd(of: url) - 5) < 0.05)
        let indices = try await decodedFrameIndices(of: url)
        #expect(Array(indices.prefix(10)) == Array(0..<10))
        #expect(indices.last == 9)
    }
}

@Test(arguments: [false, true]) func heartbeatExtendsReadableDurationWithoutFinish(framesCarryDuration: Bool) async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("seg-0001.mov")
        let w = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: 30), realTime: false)
        for i in 0..<10 { try w.append(frame(i, at: Double(i) / 30, carryingDuration: framesCarryDuration)) }
        for k in 1...6 { try w.appendHeartbeat(at: base.adding(seconds: 0.5 * Double(k))) }

        // Not finished: what a crash at this point would leave on disk.
        #expect(await readableDuration(of: url, reaching: 2.4) >= 2.4)

        let r = try await w.finish(at: base.adding(seconds: 3))
        #expect(r.sampleCount == 10 && r.heartbeatSampleCount == 6 && r.droppedSampleCount == 0)
        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 3) < 0.05)
        // Each heartbeat holds the frame until the next one, so the media itself reaches 3 s.
        #expect(abs(try await videoMediaEnd(of: url) - 3) < 0.05)
    }
}

@Test(arguments: [1, 2, 4, 8, 10]) func audioChannelCounts(channels: Int) async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("seg-0001.mov")
        let w = try FragmentedTrackWriter(url: url, media: .audio, realTime: false)
        for k in 0..<300 {
            try w.append(SampleFactory.audioSample(
                pts: base.adding(seconds: Double(k) / 100), frames: 480, sampleRate: 48_000, channels: channels
            ))
        }
        let r = try await w.finish(at: base.adding(seconds: 3))
        #expect(r.startHostTime == base && r.sampleCount == 300 && r.droppedSampleCount == 0)
        #expect(w.failure == nil)

        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.05)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await track.load(.timeRange).duration.seconds - 3) < 0.05)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let expected = channels <= 8 ? kAudioFormatAppleLossless : kAudioFormatLinearPCM
        #expect(CMFormatDescriptionGetMediaSubType(format) == expected)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(Int(asbd.mChannelsPerFrame) == channels && asbd.mSampleRate == 48_000)
        let expectedLayout: AudioChannelLayoutTag? = switch channels {
        case 4: kAudioChannelLayoutTag_MPEG_4_0_B
        case 8: kAudioChannelLayoutTag_MPEG_7_1_B
        case 10: kAudioChannelLayoutTag_DiscreteInOrder | 10
        default: nil  // 1–2 channels: no layout is requested
        }
        if let expectedLayout {
            var layoutSize = 0
            let layout = try #require(CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutSize))
            #expect(layout.pointee.mChannelLayoutTag == expectedLayout)
        }
    }
}

@Test func finishWithoutSamplesDoesNotThrowOrCrash() async throws {
    try await withTemporaryDirectory { dir in
        for (n, media) in [TrackMedia.video(framesPerSecond: 60), .audio].enumerated() {
            let url = dir.appendingPathComponent("seg-000\(n + 1).mov")
            let w = try FragmentedTrackWriter(url: url, media: media)
            var started = false
            w.onStart = { _ in started = true }
            let r = try await w.finish(at: base)
            #expect(r == SegmentResult(
                startHostTime: nil, endHostTime: base, sampleCount: 0, droppedSampleCount: 0, heartbeatSampleCount: 0
            ))
            #expect(!started && w.formatDescription == nil && w.failure == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}

@Test func writerRefusesExistingSegmentFile() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("seg-0001.mov")
        let original = Data("previous take, keep me".utf8)
        try original.write(to: url)
        #expect(throws: WriterError.fileExists) {
            _ = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: 60))
        }
        #expect(throws: WriterError.fileExists) {
            _ = try FragmentedTrackWriter(url: url, media: .audio, realTime: false)
        }
        #expect(try Data(contentsOf: url) == original)
    }
}

@Test func appendAfterFinishThrows() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("seg-0001.mov")
        let w = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: 30), realTime: false)
        for i in 0..<30 { try w.append(frame(i, at: Double(i) / 30)) }
        let r = try await w.finish(at: base.adding(seconds: 1))
        #expect(r.sampleCount == 30)

        #expect(throws: WriterError.alreadyFinished) { try w.append(frame(30, at: 1)) }
        #expect(throws: WriterError.alreadyFinished) { try w.appendHeartbeat(at: base.adding(seconds: 1.5)) }
        var secondFinish: (any Error)?
        do { _ = try await w.finish(at: base.adding(seconds: 2)) } catch { secondFinish = error }
        #expect(secondFinish as? WriterError == .alreadyFinished)
        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 1) < 0.05)
    }
}

@Test func writerFailureIsKeptAndEveryLaterAppendThrows() async throws {
    try await withTemporaryDirectory { dir in
        // AVAssetWriter cannot create a file in a missing folder: a real writer failure, on demand.
        let url = dir.appendingPathComponent("missing/seg-0001.mov")
        let w = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: 30), realTime: false)
        var started = false
        w.onStart = { _ in started = true }
        #expect(throws: WriterError.self) { try w.append(frame(0, at: 0)) }
        let failure = try #require(w.failure)
        #expect(throws: WriterError.appendFailed(failure.localizedDescription)) { try w.append(frame(1, at: 0.1)) }
        #expect(throws: WriterError.appendFailed(failure.localizedDescription)) { try w.appendHeartbeat(at: base.adding(seconds: 0.5)) }
        let r = try await w.finish(at: base.adding(seconds: 1))
        #expect(r.startHostTime == nil && r.sampleCount == 0 && !started)
    }
}

@Test func rejectsWhatItCannotWriteWithoutRaising() async throws {
    try await withTemporaryDirectory { dir in
        // AVAssetWriter raises an Objective-C exception (fatal in Swift) for a negative fragment interval.
        #expect(throws: WriterError.unsupportedFormat) {
            _ = try FragmentedTrackWriter(
                url: dir.appendingPathComponent("a.mov"), media: .audio, fragmentInterval: CMTime(value: -1, timescale: 1)
            )
        }
        #expect(throws: WriterError.unsupportedFormat) {
            _ = try FragmentedTrackWriter(url: dir.appendingPathComponent("b.mov"), media: .video(framesPerSecond: 0))
        }
        // AVAssetWriter raises NSInvalidArgumentException for a URL that is not a file URL.
        #expect(throws: WriterError.unsupportedFormat) {
            _ = try FragmentedTrackWriter(url: try #require(URL(string: "https://example.invalid/seg.mov")), media: .audio)
        }

        let audioURL = dir.appendingPathComponent("audio.mov")
        let audio = try FragmentedTrackWriter(url: audioURL, media: .audio, realTime: false)
        #expect(throws: WriterError.unsupportedFormat) { try audio.append(frame(0, at: 0)) }
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
        try audio.append(SampleFactory.audioSample(pts: base, frames: 480, sampleRate: 48_000, channels: 1))

        let videoURL = dir.appendingPathComponent("video.mov")
        let video = try FragmentedTrackWriter(url: videoURL, media: .video(framesPerSecond: 30), realTime: false)
        #expect(throws: WriterError.unsupportedFormat) {
            try video.append(SampleFactory.audioSample(pts: base, frames: 480, sampleRate: 48_000, channels: 1))
        }
        try video.appendHeartbeat(at: base)  // nothing to repeat yet: no-op
        try video.append(frame(0, at: 0))
        #expect(throws: WriterError.self) { try video.append(frame(1, at: 0)) }  // same time again
        #expect(throws: WriterError.self) { try video.appendHeartbeat(at: base) }
        #expect(throws: WriterError.unsupportedFormat) {
            try video.append(SampleFactory.videoSample(width: 320, height: 180, pts: base.adding(seconds: 0.5), frameIndex: 2))
        }
        try video.append(frame(1, at: 1.0 / 30))
        #expect(video.failure == nil && audio.failure == nil)

        let v = try await video.finish(at: base.adding(seconds: 1))
        #expect(v.sampleCount == 2 && v.heartbeatSampleCount == 0)
        #expect(abs(try await AVURLAsset(url: videoURL).load(.duration).seconds - 1) < 0.05)
        let a = try await audio.finish(at: base.adding(seconds: 0.01))
        #expect(a.sampleCount == 1)
    }
}

@Test func realTimeWriterAccountsForEverySample() async throws {
    // Appending far faster than real time: video the encoder has no room for is dropped and counted;
    // audio waits in the queue (under its 2 s cap) and is all written by `finish`.
    try await withTemporaryDirectory { dir in
        let videoURL = dir.appendingPathComponent("video.mov")
        let video = try FragmentedTrackWriter(url: videoURL, media: .video(framesPerSecond: 60))
        for i in 0..<120 {
            try video.append(SampleFactory.videoSample(
                width: 1280, height: 720, pts: base.adding(seconds: Double(i) / 60), frameIndex: i
            ))
        }
        let v = try await video.finish(at: base.adding(seconds: 2))
        #expect(v.sampleCount >= 1 && v.sampleCount + v.droppedSampleCount == 120)
        #expect(abs(try await AVURLAsset(url: videoURL).load(.duration).seconds - 2) < 0.05)

        let audioURL = dir.appendingPathComponent("audio.mov")
        let audio = try FragmentedTrackWriter(url: audioURL, media: .audio)
        for k in 0..<150 {
            try audio.append(SampleFactory.audioSample(
                pts: base.adding(seconds: Double(k) / 100), frames: 480, sampleRate: 48_000, channels: 2
            ))
        }
        let a = try await audio.finish(at: base.adding(seconds: 1.5))
        #expect(a.sampleCount == 150 && a.droppedSampleCount == 0)
        #expect(abs(try await AVURLAsset(url: audioURL).load(.duration).seconds - 1.5) < 0.05)
    }
}
