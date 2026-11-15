// SPDX-License-Identifier: GPL-3.0-or-later
import AudioToolbox
import CoreMedia
import Dispatch
import ProjectFormat
import Recording
import Synchronization

/// The loudest sample of a block of audio.
public enum AudioPeak {
    /// What a block without sound reads.
    public static let silence: Float = -160

    /// `20 · log10(max |sample|)` over every channel of `sample`, in dBFS: 0 at full scale, `silence` if
    /// every sample is 0, or if the block is not linear PCM (float, or signed integer of 8 to 32 bits).
    public static func decibels(of sample: CMSampleBuffer) -> Float {
        guard let format = sample.formatDescription?.audioStreamBasicDescription, format.mFormatID == kAudioFormatLinearPCM,
            let reader = SampleReader(format)
        else { return silence }
        var peak: Float = 0
        do {
            try sample.withAudioBufferList { buffers, _ in
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    peak = max(peak, reader.peak(UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize))))
                }
            }
        } catch {
            return silence
        }
        guard peak > 0 else { return silence }
        return max(silence, 20 * log10(peak))
    }

    /// Reads the samples of one buffer as a fraction of full scale.
    private struct SampleReader {
        enum Kind { case float32, float64, integer }

        let kind: Kind
        /// Bytes per sample in the buffer: 1 to 4 for integers.
        let width: Int
        /// The integer that is full scale.
        let fullScale: Float
        let isBigEndian: Bool

        init?(_ format: AudioStreamBasicDescription) {
            let flags = format.mFormatFlags
            let channels = max(Int(format.mChannelsPerFrame), 1)
            let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
            let frameBytes = Int(format.mBytesPerFrame)
            let width = interleaved ? frameBytes / channels : frameBytes
            let bits = Int(format.mBitsPerChannel)
            guard width > 0, bits > 0 else { return nil }
            self.width = width
            isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
            if flags & kAudioFormatFlagIsFloat != 0 {
                switch (bits, width) {
                case (32, 4): kind = .float32
                case (64, 8): kind = .float64
                default: return nil
                }
                fullScale = 1
            } else {
                guard flags & kAudioFormatFlagIsSignedInteger != 0, (1...4).contains(width), bits <= width * 8 else { return nil }
                kind = .integer
                // Samples narrower than their container sit in its high bits only when aligned high.
                let aligned = bits == width * 8 || flags & kAudioFormatFlagIsAlignedHigh != 0
                fullScale = Float(1 << ((aligned ? width * 8 : bits) - 1))
            }
        }

        func peak(_ bytes: UnsafeRawBufferPointer) -> Float {
            let count = bytes.count / width
            var peak: Float = 0
            switch kind {
            case .float32:
                for index in 0..<count {
                    let bits = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                    peak = max(peak, abs(Float(bitPattern: isBigEndian ? bits.byteSwapped : bits)))
                }
            case .float64:
                for index in 0..<count {
                    let bits = bytes.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)
                    peak = max(peak, Float(abs(Double(bitPattern: isBigEndian ? bits.byteSwapped : bits))))
                }
            case .integer:
                for index in 0..<count {
                    peak = max(peak, abs(Float(integer(at: index * width, in: bytes))) / fullScale)
                }
            }
            return min(peak, 1)
        }

        /// The signed integer of `width` bytes at `offset`.
        private func integer(at offset: Int, in bytes: UnsafeRawBufferPointer) -> Int32 {
            var value: UInt32 = 0
            for byte in 0..<width {
                let shift = isBigEndian ? (width - 1 - byte) * 8 : byte * 8
                value |= UInt32(bytes[offset + byte]) << shift
            }
            // Sign-extended from its top bit.
            let unused = UInt32(32 - width * 8)
            return Int32(bitPattern: value << unused) >> unused
        }
    }
}

/// A capture source that hears what it captures: it forwards everything to `base` and from it as it is,
/// and keeps the peak of the last block it delivered (`AudioPeak`), which any thread can read.
public final class MeteredSource: CaptureSource {
    public let base: any CaptureSource
    private let peak = PeakHolder()

    public init(_ base: any CaptureSource) {
        self.base = base
    }

    public var trackID: String { base.trackID }
    public var kind: TrackKind { base.kind }
    public var media: TrackMedia { base.media }
    public var sourceInfo: TrackSource { base.sourceInfo }
    public var activeDeviceUniqueID: String? { base.activeDeviceUniqueID }

    /// The peak of the last block delivered, in dBFS; `AudioPeak.silence` until one is, and once the
    /// source has stopped or failed.
    public var peakDecibels: Float { peak.value }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await base.start(on: queue, sink: MeteringSink(sink: sink, peak: peak))
    }

    public func stop() async {
        await base.stop()
        peak.value = AudioPeak.silence
    }
}

/// The last peak, behind a lock.
private final class PeakHolder: Sendable {
    private let peak = Mutex(AudioPeak.silence)

    var value: Float {
        get { peak.withLock { $0 } }
        set { peak.withLock { $0 = newValue } }
    }
}

/// Between a metered source and the sink it was started with, for one run: measures every block on its
/// way through. The source retains it only while the run lasts, and it retains the sink as long.
private final class MeteringSink: CaptureSink {
    private let sink: any CaptureSink
    private let peak: PeakHolder

    init(sink: any CaptureSink, peak: PeakHolder) {
        self.sink = sink
        self.peak = peak
    }

    func source(_ trackID: String, didOutput sample: CMSampleBuffer) {
        peak.value = AudioPeak.decibels(of: sample)
        sink.source(trackID, didOutput: sample)
    }

    func source(_ trackID: String, didStopWithError error: any Error) {
        peak.value = AudioPeak.silence
        sink.source(trackID, didStopWithError: error)
    }
}
