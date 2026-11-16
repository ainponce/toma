// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation

/// The sound of an export as the AAC encoder takes it: the mix of its document (`EditedMix`) in blocks of 48 kHz Float32
/// PCM, one after the other from output frame 0 to `totalFrames`, each presented at its output time.
///
/// Not thread-safe: one owner reads it, from one thread at a time.
final class AudioMix {
    /// Frames per block handed to the encoder.
    static let blockFrames = 4096

    let mix: EditedMix
    /// 1 or 2.
    var channels: Int { mix.channels }
    /// Length of the mix, in frames.
    var totalFrames: Int64 { mix.totalFrames }
    /// Format of the blocks: interleaved Float32 at `AudioTrackTimeline.sampleRate` with `channels` channels.
    let formatDescription: CMAudioFormatDescription
    /// Output frame of the next block.
    private(set) var position: Int64 = 0

    /// The frames of the block being made.
    private var block: [Float] = []

    /// The blocks of `mix`.
    /// - Throws: `ExportError.writerFailed` if the block format cannot be made.
    init(mix: EditedMix) throws {
        self.mix = mix
        let channels = mix.channels
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

    /// The spans left silent, track by track (`EditedMix.missingAudio`).
    var missingAudio: [MissingAudio] { mix.missingAudio }

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
        mix.render(outputFrames: position..<(position + Int64(count)), into: &block)
        let sample = try makeSampleBuffer(block, frames: count, at: position)
        position += Int64(count)
        return sample
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
