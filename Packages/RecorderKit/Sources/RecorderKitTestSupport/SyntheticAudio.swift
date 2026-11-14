// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import ProjectFormat

/// Channel `channel` of `multichannelAudio` at frame `frame`: a sine of 110·(c + 1) Hz at level
/// 0.05·(c + 1), so every channel differs from every other in both pitch and level.
public func channelSignal(_ channel: Int, frame: Int, sampleRate: Double) -> Float {
    let c = Double(channel + 1)
    return Float(0.05 * c * sin(2 * Double.pi * 110 * c * Double(frame) / sampleRate))
}

/// Float32 LPCM, frames `startFrame ..< startFrame + frames`, where each channel carries its own
/// `channelSignal`, with the channel layout `layout`: interleaved, or `planar` (one plane per channel).
public func multichannelAudio(
    pts: HostTime, startFrame: Int, frames: Int, sampleRate: Double, channels: Int, layout: AudioChannelLayoutTag,
    planar: Bool = false
) throws -> CMSampleBuffer {
    var samples = [Float](repeating: 0, count: frames * channels)
    for n in 0..<frames {
        for c in 0..<channels {
            samples[planar ? c * frames + n : n * channels + c] = channelSignal(c, frame: startFrame + n, sampleRate: sampleRate)
        }
    }
    let bytesPerFrame = UInt32(MemoryLayout<Float>.size * (planar ? 1 : channels))
    let flags = kAudioFormatFlagsNativeFloatPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
        mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
    )
    var channelLayout = AudioChannelLayout()
    channelLayout.mChannelLayoutTag = layout
    var format: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size,
        layout: &channelLayout, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
    )
    guard formatStatus == noErr else { throw TestSupportError.failed("CMAudioFormatDescriptionCreate: \(formatStatus)") }
    let byteCount = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block
    )
    guard blockStatus == noErr else { throw TestSupportError.failed("CMBlockBufferCreateWithMemoryBlock: \(blockStatus)") }
    let data = try unwrap(block, "the block buffer")
    try samples.withUnsafeBytes { bytes in
        let status = CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: byteCount
        )
        guard status == noErr else { throw TestSupportError.failed("CMBlockBufferReplaceDataBytes: \(status)") }
    }
    var sample: CMSampleBuffer?
    let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: try unwrap(format, "the audio format"),
        sampleCount: frames, presentationTimeStamp: pts.cmTime, packetDescriptions: nil, sampleBufferOut: &sample
    )
    guard sampleStatus == noErr else { throw TestSupportError.failed("CMAudioSampleBufferCreateReadyWithPacketDescriptions: \(sampleStatus)") }
    return try unwrap(sample, "the sample buffer")
}
