// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat
@testable import Recording
import SyntheticCapture
import Testing

private let base = HostTime(nanoseconds: 1_234_000_000_000)

private func audioBlock(_ k: Int, frames: Int = 480) -> CMSampleBuffer {
    SampleFactory.audioSample(pts: base.adding(seconds: Double(k) / 100), frames: frames, sampleRate: 48_000, channels: 1)
}

@Test func alacLayoutTagsAreTheEncoderPreference() {
    let expected: [Int: AudioChannelLayoutTag] = [
        3: kAudioChannelLayoutTag_MPEG_3_0_B,
        4: kAudioChannelLayoutTag_MPEG_4_0_B,
        5: kAudioChannelLayoutTag_MPEG_5_0_D,
        6: kAudioChannelLayoutTag_MPEG_5_1_D,
        7: kAudioChannelLayoutTag_AAC_6_1,
        8: kAudioChannelLayoutTag_MPEG_7_1_B,
    ]
    for channels in 3...8 {
        #expect(FragmentedTrackWriter.alacLayoutTag(channels: channels, sampleRate: 48_000) == expected[channels])
    }
}

@Test func pendingAudioQueueCapsAtTwoSecondsDroppingOldestFirst() {
    var queue = PendingAudioQueue(capacitySeconds: 2, sampleRate: 48_000)
    var dropped: [CMSampleBuffer] = []
    for k in 0..<250 { dropped += queue.push(audioBlock(k)) }  // 10 ms each: 2.5 s
    #expect(dropped.count == 50)
    #expect(dropped.map { HostTime($0.presentationTimeStamp) } == (0..<50).map { base.adding(seconds: Double($0) / 100) })
    #expect(queue.count == 200 && queue.frames == 96_000)
    #expect(queue.first.map { HostTime($0.presentationTimeStamp) } == base.adding(seconds: 0.5))
    #expect(queue.popFirst().map { HostTime($0.presentationTimeStamp) } == base.adding(seconds: 0.5))
    #expect(queue.count == 199 && queue.frames == 95_520)
    #expect(queue.removeAll().count == 199 && queue.isEmpty && queue.frames == 0)
}

@Test func pendingAudioQueueAlwaysKeepsTheNewestBuffer() {
    var queue = PendingAudioQueue(capacitySeconds: 2, sampleRate: 48_000)
    #expect(queue.push(audioBlock(0, frames: 144_000)).isEmpty)  // 3 s alone: kept
    #expect(queue.count == 1)
    for k in 300..<310 { _ = queue.push(audioBlock(k)) }  // over the cap: the 3 s block goes first
    #expect(queue.count == 10 && queue.frames == 4_800)
    let dropped = queue.push(audioBlock(400, frames: 144_000))  // drops all ten older blocks
    #expect(dropped.count == 10 && queue.count == 1 && queue.frames == 144_000)
    #expect(queue.first.map { HostTime($0.presentationTimeStamp) } == base.adding(seconds: 4))
}

@Test func holdThatCannotBeWrittenStillFinishesTheFile() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("seg-0001.mov")
        let w = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: 30), realTime: false)
        for i in 0..<10 {
            try w.append(SampleFactory.videoSample(width: 640, height: 360, pts: base.adding(seconds: Double(i) / 10), frameIndex: i))
        }
        // From here the encoder never has room, so the hold frame at the stop time times out.
        w.readinessTimeoutSeconds = 0.05
        w.inputHasRoom = { _ in false }
        let r = try await w.finish(at: base.adding(seconds: 5))
        #expect(r.startHostTime == base && r.endHostTime == base.adding(seconds: 5))
        #expect(r.sampleCount == 10 && r.droppedSampleCount == 0 && w.failure == nil)
        // Finished anyway: the session ends at the stop time; only the cosmetic hold is missing.
        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 5) < 0.05)
        #expect(try await decodedFrameIndices(of: url).prefix(10) == ArraySlice(0..<10))
    }
}

@Test func audioThatCannotDrainIsCountedAndTheFileStillFinishes() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("seg-0001.mov")
        let w = try FragmentedTrackWriter(url: url, media: .audio, realTime: true)
        for k in 0..<50 { try w.append(audioBlock(k)) }
        // From here the encoder never has room: 2.5 s more fills the 2 s queue, and finish times out on it.
        w.readinessTimeoutSeconds = 0.05
        w.inputHasRoom = { _ in false }
        for k in 50..<300 { try w.append(audioBlock(k)) }
        let r = try await w.finish(at: base.adding(seconds: 3))
        #expect(r.sampleCount + r.droppedSampleCount == 300)
        #expect(r.sampleCount >= 1 && r.droppedSampleCount >= 250)
        #expect(r.endHostTime == base.adding(seconds: 3) && w.failure == nil)
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        #expect(try await track.load(.timeRange).duration.seconds > 0)
    }
}

@Test func lastWrittenAudioCountsOnlyFramesInTheFile() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("seg-0001.mov")
        let w = try FragmentedTrackWriter(url: url, media: .audio, realTime: true)
        #expect(w.lastWrittenAudio == nil)
        for k in 0..<50 { try w.append(audioBlock(k)) }
        #expect(w.lastWrittenAudio == AudioFilePosition(frame: 49 * 480, hostTime: base.adding(seconds: 0.49)))
        // The encoder has no room while 2.5 s more arrive: the 2 s queue drops the oldest half second.
        w.inputHasRoom = { _ in false }
        for k in 50..<300 { try w.append(audioBlock(k)) }
        #expect(w.lastWrittenAudio == AudioFilePosition(frame: 49 * 480, hostTime: base.adding(seconds: 0.49)))
        w.inputHasRoom = { $0.isReadyForMoreMediaData }
        try w.append(audioBlock(300))
        let r = try await w.finish(at: base.adding(seconds: 3.01))
        #expect(r.droppedSampleCount >= 40 && r.sampleCount + r.droppedSampleCount == 301)
        // Block 300 starts after every block written before it, the dropped ones not counted.
        #expect(w.lastWrittenAudio == AudioFilePosition(frame: (r.sampleCount - 1) * 480, hostTime: base.adding(seconds: 3)))
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        #expect(try await track.load(.timeRange).duration == CMTime(value: CMTimeValue(r.sampleCount * 480), timescale: 48_000))
    }
}

@Test func appendThatTimesOutIsNotTakenAndCanBeRetried() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("seg-0001.mov")
        let w = try FragmentedTrackWriter(url: url, media: .video(framesPerSecond: 30), realTime: false)
        func frame(_ i: Int) -> CMSampleBuffer {
            SampleFactory.videoSample(width: 640, height: 360, pts: base.adding(seconds: Double(i) / 30), frameIndex: i)
        }
        try w.append(frame(0))
        w.readinessTimeoutSeconds = 0.05
        w.inputHasRoom = { _ in false }
        #expect(throws: WriterError.appendFailed("timeout")) { try w.append(frame(1)) }
        #expect(w.failure == nil)
        w.inputHasRoom = { $0.isReadyForMoreMediaData }
        try w.append(frame(1))  // the same sample again: it was never taken
        let r = try await w.finish(at: base.adding(seconds: 2.0 / 30))
        #expect(r.sampleCount == 2 && w.failure == nil)
        #expect(try await decodedFrameIndices(of: url) == [0, 1])
    }
}
