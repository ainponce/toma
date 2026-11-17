// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation

/// The sound of an export as the AAC encoder takes it: output frames `frames` of the mix of its document (`EditedMix`)
/// in blocks of 48 kHz Float32 PCM, one after the other, each presented at its time from the first of them: for the
/// whole video, from output frame 0 to the mix's `totalFrames`; for a range of it, the range's frames
/// (`EditedMix.frames(of:frameCount:framesPerSecond:)`).
///
/// Not thread-safe: one owner reads it, from one thread at a time.
final class AudioMix {
    /// Frames per block handed to the encoder.
    static let blockFrames = 4096

    let mix: EditedMix
    /// The output frames of the mix the blocks hold.
    let frames: Range<Int64>
    /// 1 or 2.
    var channels: Int { mix.channels }
    /// How many frames the blocks hold, in all.
    var totalFrames: Int64 { frames.upperBound - frames.lowerBound }
    /// Format of the blocks: interleaved Float32 at `AudioTrackTimeline.sampleRate` with `channels` channels.
    let formatDescription: CMAudioFormatDescription
    /// Frame of the next block, from the first of `frames`: its presentation time.
    private(set) var position: Int64 = 0

    /// The frames of the block being made.
    private var block: [Float] = []

    /// The blocks of output frames `frames` of `mix`: all of it by default.
    /// - Throws: `ExportError.writerFailed` if the block format cannot be made.
    init(mix: EditedMix, frames: Range<Int64>? = nil) throws {
        self.mix = mix
        self.frames = frames ?? 0..<mix.totalFrames
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

    /// The next block of at most `blockFrames` frames, presented at its time from the first of `frames`; `nil` once
    /// `totalFrames` have been read.
    func nextBlock() throws -> CMSampleBuffer? {
        guard position < totalFrames else { return nil }
        let count = Int(min(Int64(Self.blockFrames), totalFrames - position))
        let first = frames.lowerBound + position
        mix.render(outputFrames: first..<(first + Int64(count)), into: &block)
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
