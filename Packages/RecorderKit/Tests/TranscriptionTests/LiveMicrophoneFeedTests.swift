// SPDX-License-Identifier: GPL-3.0-or-later
import AudioToolbox
import CoreMedia
import Foundation
import Testing
import Transcription

/// The microphone heard live (plan 3d, decision 15): any linear PCM to mono Float32 at 48 kHz, its channels averaged,
/// and at most the newest two seconds kept for a reader that is behind or absent.
@Suite(.timeLimit(.minutes(1))) struct LiveMicrophoneFeedTests {
    @Test func feedConvertsAnyPCMToMono48k() async throws {
        // 1 s of interleaved Int16 stereo at 44.1 kHz in 10 ms blocks: the left channel at 0.5, the right one at 0.1.
        let resampled = LiveMicrophoneFeed()
        for block in 0..<100 {
            resampled.append(pcmSample(frames: 441, channels: [0.5, 0.1], sampleRate: 44_100, int16: true, firstFrame: block * 441))
        }
        resampled.finish()
        let heard = await allSamples(of: resampled)
        // About a second at 48 kHz: what the resampler holds back is given at the end.
        #expect(abs(heard.count - 48_000) <= 48, "\(heard.count) samples")
        // The mean of the channels (0.1 in Int16 is 3277 / 32768), past the resampler's first and last milliseconds.
        let mean = (0.5 + Float(3_277) / 32_768) / 2
        let middle = heard[2_400..<(heard.count - 2_400)]
        #expect(middle.allSatisfy { abs($0 - mean) < 0.002 }, "\(middle.min() ?? 0) to \(middle.max() ?? 0)")

        // Interleaved Float32 stereo at 48 kHz: no resampling, every sample the mean of its two.
        let averaged = LiveMicrophoneFeed()
        for block in 0..<10 {
            averaged.append(pcmSample(frames: 480, channels: [0.8, -0.2], sampleRate: 48_000, int16: false, firstFrame: block * 480))
        }
        averaged.finish()
        let mono = await allSamples(of: averaged)
        #expect(mono.count == 4_800 && mono.allSatisfy { abs($0 - 0.3) < 0.000_01 })
    }

    @Test func feedKeepsOnlyTheNewestTwoSeconds() async throws {
        #expect(LiveMicrophoneFeed.keptSeconds == 2)
        let feed = LiveMicrophoneFeed()
        // 10 s of mono Float32 at 48 kHz in 10 ms blocks, nobody reading: every sample of a block is its number.
        for block in 0..<1_000 {
            feed.append(pcmSample(frames: 480, channels: [Float(block) / 1_000], sampleRate: 48_000, int16: false, firstFrame: block * 480))
        }
        feed.finish()
        let heard = await allSamples(of: feed)
        // The last two seconds, in order, and nothing else: blocks 800 to 999.
        #expect(heard.count == 96_000)
        #expect(heard == (800..<1_000).flatMap { Array(repeating: Float($0) / 1_000, count: 480) })
    }

    @Test func finishEndsTheChunks() async throws {
        // A reader that keeps up hears everything, then its loop ends at `finish`.
        let feed = LiveMicrophoneFeed()
        let reader = Task {
            var count = 0
            for await chunk in feed.chunks { count += chunk.samples.count }
            return count
        }
        for block in 0..<50 {
            feed.append(pcmSample(frames: 480, channels: [0.25], sampleRate: 48_000, int16: false, firstFrame: block * 480))
            if block % 10 == 9 { try await Task.sleep(for: .milliseconds(5)) }
        }
        feed.finish()
        #expect(await reader.value == 24_000)

        // Finished before anything came: the chunks end at once, and what comes after `finish` is not heard.
        let empty = LiveMicrophoneFeed()
        empty.finish()
        empty.append(pcmSample(frames: 480, channels: [0.25], sampleRate: 48_000, int16: false, firstFrame: 0))
        empty.finish()
        #expect(await allSamples(of: empty).isEmpty)

        // A reader that is cancelled ends its loop while it waits, and the feed drops what comes after.
        let waiting = LiveMicrophoneFeed()
        let (started, start) = AsyncStream<Void>.makeStream()
        let cancelled = Task {
            start.yield()
            var count = 0
            for await chunk in waiting.chunks { count += chunk.samples.count }
            return count
        }
        for await _ in started { break }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        #expect(await cancelled.value == 0)
        waiting.append(pcmSample(frames: 480, channels: [0.25], sampleRate: 48_000, int16: false, firstFrame: 0))
        waiting.finish()
    }
}

/// Everything `feed` gives until its chunks end.
private func allSamples(of feed: LiveMicrophoneFeed) async -> [Float] {
    var samples: [Float] = []
    for await chunk in feed.chunks { samples += chunk.samples }
    return samples
}

/// A block of `frames` frames of interleaved linear PCM, every frame `channels` (one value per channel, as a fraction of
/// full scale), in signed 16-bit integers or in Float32, starting `firstFrame` frames into the take.
private func pcmSample(frames: Int, channels: [Float], sampleRate: Double, int16: Bool, firstFrame: Int) -> CMSampleBuffer {
    let count = channels.count
    let width = int16 ? 2 : 4
    var bytes = [UInt8]()
    bytes.reserveCapacity(frames * count * width)
    for _ in 0..<frames {
        for value in channels {
            if int16 {
                withUnsafeBytes(of: Int16((value * 32_768).rounded()).littleEndian) { bytes += $0 }
            } else {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes += $0 }
            }
        }
    }
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: int16 ? kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked : kAudioFormatFlagsNativeFloatPacked,
        mBytesPerPacket: UInt32(count * width), mFramesPerPacket: 1, mBytesPerFrame: UInt32(count * width),
        mChannelsPerFrame: UInt32(count), mBitsPerChannel: UInt32(width * 8), mReserved: 0)
    var format: CMAudioFormatDescription?
    var status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format)
    precondition(status == noErr && format != nil, "pcmSample: format \(status)")
    var block: CMBlockBuffer?
    status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block)
    precondition(status == noErr && block != nil, "pcmSample: block \(status)")
    status = bytes.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count)
    }
    precondition(status == noErr, "pcmSample: copy \(status)")
    var sample: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
        presentationTimeStamp: CMTime(value: CMTimeValue(firstFrame), timescale: CMTimeScale(sampleRate)),
        packetDescriptions: nil, sampleBufferOut: &sample)
    precondition(status == noErr && sample != nil, "pcmSample: sample \(status)")
    return sample!
}
