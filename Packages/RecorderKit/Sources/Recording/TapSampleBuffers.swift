// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
import CoreMedia
import Foundation
import ProjectFormat

/// Turns what a tap's IOProc receives into samples on the host clock. Every failure is
/// `CaptureSourceError.systemAudioUnavailable` with Core Media's status.
enum TapSampleBuffers {
    /// The description of LPCM in `format`, made once per run and shared by its samples.
    static func formatDescription(for format: AudioStreamBasicDescription) throws -> CMAudioFormatDescription {
        var asbd = format
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        return description
    }

    /// A copy of `buffers` (they are only valid during the callback), `frameCount` frames of LPCM described by
    /// `format`, interleaved or planar as it says, presenting at `hostTime` (`AudioTimeStamp.mHostTime`, in
    /// `mach_absolute_time` ticks) converted to nanoseconds.
    static func make(
        from buffers: UnsafePointer<AudioBufferList>, frameCount: UInt32, format: CMAudioFormatDescription, hostTime: UInt64
    ) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        var status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: CMItemCount(frameCount), presentationTimeStamp: presentationTime(hostTime),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffers)
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        return sample
    }

    /// `frameCount` frames of silence described by `format`, presenting at `hostTime` as `make` would: what a tap
    /// that names only its placeholder records. One zero-filled block, its planes one after another when planar.
    static func silence(frameCount: UInt32, format: CMAudioFormatDescription, hostTime: UInt64) throws -> CMSampleBuffer {
        guard let asbd = format.audioStreamBasicDescription else {
            throw CaptureSourceError.systemAudioUnavailable(status: kCMFormatDescriptionError_InvalidParameter)
        }
        let planes = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(asbd.mChannelsPerFrame) : 1
        let length = planes * Int(frameCount) * Int(asbd.mBytesPerFrame)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        status = CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: presentationTime(hostTime), packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        return sample
    }

    private static func presentationTime(_ hostTime: UInt64) -> CMTime {
        HostTime(nanoseconds: AudioConvertHostTimeToNanos(hostTime)).cmTime
    }
}
