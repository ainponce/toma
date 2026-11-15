// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation

/// The sound of an export: the streams of its audio tracks (`AudioTrackTimeline`, each placed by its own clock) added
/// together at unity gain, in blocks of 48 kHz Float32 PCM ready for the AAC encoder.
///
/// A sum past full scale is clipped to [−1, 1], never wrapped around: two loud sources at once distort, but keep
/// their shape. The mix is mono if every track is, stereo otherwise: `channels` is `min(2, the most any track
/// needs)` (`AudioTrackTimeline.channelCount(of:in:)`), and every timeline is loaded with it.
///
/// Not thread-safe: one owner reads it, from one thread at a time.
final class AudioMix {
    /// Frames per block handed to the encoder.
    static let blockFrames = 4096

    /// 1 or 2.
    let channels: Int
    /// Length of the mix, in frames.
    let totalFrames: Int64
    /// Format of the blocks: interleaved Float32 at `AudioTrackTimeline.sampleRate` with `channels` channels.
    let formatDescription: CMAudioFormatDescription
    /// Output frame of the next block.
    private(set) var position: Int64 = 0

    private let timelines: [AudioTrackTimeline]
    /// One track's frames of the block being mixed.
    private var trackBlock: [Float] = []

    /// The mix of `timelines`, `totalFrames` long.
    /// - Precondition: `channels` is 1 or 2, and every timeline was loaded with it.
    /// - Throws: `ExportError.writerFailed` if the block format cannot be made.
    init(timelines: [AudioTrackTimeline], channels: Int, totalFrames: Int64) throws {
        precondition(channels == 1 || channels == 2, "AudioMix: \(channels) channels")
        precondition(timelines.allSatisfy { $0.channels == channels }, "AudioMix: a track was loaded with other channels than the mix")
        self.timelines = timelines
        self.channels = channels
        self.totalFrames = max(0, totalFrames)
        var description = AudioStreamBasicDescription(
            mSampleRate: AudioTrackTimeline.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = Self.layoutTag(channels: channels)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else {
            throw ExportError.writerFailed("cannot describe the audio blocks (OSStatus \(status))")
        }
        formatDescription = format
    }

    /// The spans left silent, track by track, each in the order its timeline found them.
    var missingAudio: [MissingAudio] { timelines.flatMap(\.missingAudio) }

    static func layoutTag(channels: Int) -> AudioChannelLayoutTag {
        channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
    }

    /// `AVChannelLayoutKey` data for `channels` (1 or 2).
    static func channelLayoutData(channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = layoutTag(channels: channels)
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// The next block of at most `blockFrames` frames, presented at its output time; `nil` once `totalFrames` have
    /// been read.
    func nextBlock() throws -> CMSampleBuffer? {
        guard position < totalFrames else { return nil }
        let count = Int(min(Int64(Self.blockFrames), totalFrames - position))
        var samples = [Float](repeating: 0, count: count * channels)
        for timeline in timelines {
            timeline.read(into: &trackBlock, frames: count)
            for i in samples.indices { samples[i] += trackBlock[i] }
        }
        for i in samples.indices { samples[i] = min(max(samples[i], -1), 1) }
        let block = try makeSampleBuffer(samples, frames: count, at: position)
        position += Int64(count)
        return block
    }

    private func makeSampleBuffer(_ samples: [Float], frames: Int, at position: Int64) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw ExportError.writerFailed("no audio block buffer (OSStatus \(status))") }
        status = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == noErr else { throw ExportError.writerFailed("cannot fill an audio block (OSStatus \(status))") }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription, sampleCount: frames,
            presentationTimeStamp: CMTime(value: position, timescale: CMTimeScale(AudioTrackTimeline.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw ExportError.writerFailed("no audio sample buffer (OSStatus \(status))") }
        return sample
    }
}
