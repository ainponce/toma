// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
import CoreMedia
import Foundation
import ProjectFormat

/// Turns what a tap's IOProc receives into samples on the host clock.
enum TapSampleBuffers {
    /// A copy of `buffers` (they are only valid during the callback), `frameCount` frames of LPCM in `format`,
    /// interleaved or planar as `format` says, presenting at `hostTime` (`AudioTimeStamp.mHostTime`, in
    /// `mach_absolute_time` ticks) converted to nanoseconds.
    static func make(
        from buffers: UnsafePointer<AudioBufferList>, frameCount: UInt32, format: AudioStreamBasicDescription, hostTime: UInt64
    ) throws -> CMSampleBuffer {
        let sample = try emptySample(frameCount: frameCount, format: format, hostTime: hostTime)
        let status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffers)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return sample
    }

    /// `frameCount` frames of silence in `format`, presenting at `hostTime` as `make` would: what a tap that
    /// names only its placeholder records.
    static func silence(frameCount: UInt32, format: AudioStreamBasicDescription, hostTime: UInt64) throws -> CMSampleBuffer {
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let buffers = planar ? Int(format.mChannelsPerFrame) : 1
        let bytesPerBuffer = Int(frameCount) * Int(format.mBytesPerFrame)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: max(1, buffers * bytesPerBuffer), alignment: 16)
        defer { memory.deallocate() }
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: max(1, buffers * bytesPerBuffer))
        let list = AudioBufferList.allocate(maximumBuffers: buffers)
        defer { free(list.unsafeMutablePointer) }
        for index in 0..<buffers {
            list[index] = AudioBuffer(
                mNumberChannels: planar ? 1 : format.mChannelsPerFrame, mDataByteSize: UInt32(bytesPerBuffer),
                mData: memory + index * bytesPerBuffer)
        }
        return try make(from: list.unsafePointer, frameCount: frameCount, format: format, hostTime: hostTime)
    }

    private static func emptySample(frameCount: UInt32, format: AudioStreamBasicDescription, hostTime: UInt64) throws -> CMSampleBuffer {
        var asbd = format
        var description: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let pts = HostTime(nanoseconds: AudioConvertHostTimeToNanos(hostTime)).cmTime
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: CMItemCount(frameCount), presentationTimeStamp: pts,
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return sample
    }
}
