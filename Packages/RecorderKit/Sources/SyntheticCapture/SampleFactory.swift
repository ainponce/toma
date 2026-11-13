// SPDX-License-Identifier: GPL-3.0-or-later
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat

/// Deterministic synthetic samples for tests and the development CLI.
///
/// Video frames are filled with a colour from a 64-colour palette chosen by frame index, so a
/// decoded frame tells which frame it was (`frameIndex(nearestTo:)`), even after lossy encoding.
public enum SampleFactory {
    private static let paletteSize = 64
    private static let squareSize = 16

    /// Palette colour (R, G, B) of frame `i`: R = 32·(i % 8), G = 32·((i / 8) % 8), B = 200.
    public static func color(forFrame i: Int) -> SIMD3<UInt8> {
        let k = ((i % paletteSize) + paletteSize) % paletteSize
        return SIMD3(UInt8(32 * (k % 8)), UInt8(32 * ((k / 8) % 8)), 200)
    }

    /// The palette index (0..<64) whose colour is nearest to a BGRA pixel.
    public static func frameIndex(nearestTo bgra: SIMD4<UInt8>) -> Int {
        let pixel = SIMD3<Int>(Int(bgra.z), Int(bgra.y), Int(bgra.x))
        var best = 0
        var bestDistance = Int.max
        for i in 0..<paletteSize {
            let c = color(forFrame: i)
            let d = pixel &- SIMD3<Int>(Int(c.x), Int(c.y), Int(c.z))
            let distance = (d &* d).wrappedSum()
            if distance < bestDistance {
                best = i
                bestDistance = distance
            }
        }
        return best
    }

    /// A BGRA frame backed by an IOSurface: background `color(forFrame:)`, plus a white 16 px square
    /// that moves along the top row (16 px per frame) so consecutive frames always differ.
    public static func videoSample(width: Int, height: Int, pts: HostTime, frameIndex: Int) -> CMSampleBuffer {
        precondition(width > 0 && height > 0, "SampleFactory: empty frame \(width)×\(height)")
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created
        )
        guard status == kCVReturnSuccess, let pixelBuffer = created else {
            preconditionFailure("SampleFactory: CVPixelBufferCreate failed (\(status))")
        }
        fill(pixelBuffer, frameIndex: frameIndex)
        do {
            let format = try CMVideoFormatDescription(imageBuffer: pixelBuffer)
            let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts.cmTime, decodeTimeStamp: .invalid)
            return try CMSampleBuffer(imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: timing)
        } catch {
            preconditionFailure("SampleFactory: video sample buffer failed (\(error))")
        }
    }

    /// Interleaved Float32 LPCM: a 440 Hz sine at 1/4 full scale on every channel. The phase comes
    /// from the absolute time, so consecutive blocks join without clicks.
    public static func audioSample(pts: HostTime, frames: Int, sampleRate: Double, channels: Int) -> CMSampleBuffer {
        precondition(frames > 0 && channels > 0 && sampleRate > 0, "SampleFactory: empty audio block")
        let start = Double(pts.nanoseconds) / 1_000_000_000
        var samples = [Float](repeating: 0, count: frames * channels)
        for n in 0..<frames {
            let cycles = 440 * (start + Double(n) / sampleRate)
            let value = Float(0.25 * sin(2 * Double.pi * (cycles - cycles.rounded(.down))))
            for c in 0..<channels { samples[n * channels + c] = value }
        }

        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * channels)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = switch channels {
        case 1: kAudioChannelLayoutTag_Mono
        case 2: kAudioChannelLayoutTag_Stereo
        default: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        }

        var format: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            preconditionFailure("SampleFactory: audio format description failed (\(status))")
        }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else {
            preconditionFailure("SampleFactory: audio block buffer failed (\(status))")
        }
        status = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        guard status == noErr else {
            preconditionFailure("SampleFactory: audio block copy failed (\(status))")
        }

        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: pts.cmTime,
            packetDescriptions: nil,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            preconditionFailure("SampleFactory: audio sample buffer failed (\(status))")
        }
        return sample
    }

    private static func fill(_ pixelBuffer: CVPixelBuffer, frameIndex: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!

        // One BGRA pixel as a little-endian word: B | G << 8 | R << 16 | A << 24.
        let c = color(forFrame: frameIndex)
        let background = UInt32(c.z) | UInt32(c.y) << 8 | UInt32(c.x) << 16 | 0xFF00_0000
        let firstRow = base.assumingMemoryBound(to: UInt32.self)
        firstRow.update(repeating: background, count: width)
        for y in 1..<height {
            base.advanced(by: y * bytesPerRow).copyMemory(from: firstRow, byteCount: width * 4)
        }

        let travel = max(width - squareSize, 1)
        let squareX = (((frameIndex * squareSize) % travel) + travel) % travel
        let squareWidth = min(squareSize, width - squareX)
        for y in 0..<min(squareSize, height) {
            base.advanced(by: y * bytesPerRow + squareX * 4)
                .assumingMemoryBound(to: UInt32.self)
                .update(repeating: 0xFFFF_FFFF, count: squareWidth)
        }
    }
}
