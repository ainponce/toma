// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import Foundation
import ProjectFormat

/// The loudness measure of one segment of an audio track (`loudness-1`), as its cache holds it (plan decision 15): the
/// K-weighted energy of each 400 ms block, every 100 ms from the segment's first frame, of the track as recorded (`dry`,
/// summed over its `channels`), and, when the segment's clean voice was there, of it (`wet`, mono) and of the clean voice
/// times the dry (`cross`, summed over the channels), with the identity of the clean file measured (`clean`,
/// `"<bytes>-<modification ns>"`).
public struct SegmentLoudness: Codable, Equatable, Sendable {
    /// `Loudness.algorithm` when it was measured.
    public var algorithm: String
    public var channels: Int
    public var dry: [Double]
    public var wet: [Double]?
    public var cross: [Double]?
    public var clean: String?

    public init(algorithm: String, channels: Int, dry: [Double], wet: [Double]?, cross: [Double]?, clean: String?) {
        self.algorithm = algorithm
        self.channels = channels
        self.dry = dry
        self.wet = wet
        self.cross = cross
        self.clean = clean
    }
}

/// `loudness-1`: the integrated loudness of ITU-R BS.1770-4 (phase 2 design §5.7), and the gain that normalizes a track
/// with it.
///
/// - Each channel is K-weighted at 48 kHz (`KWeighting`: the standard's high shelf, then its high-pass), every channel
///   at weight 1 (a mono or stereo track has neither surround nor LFE channels).
/// - The energy of a block is the mean square of the weighted samples over its 400 ms (`blockFrames`), summed over the
///   channels; the blocks overlap by 75 %, one every 100 ms (`hopFrames`), and only whole blocks count.
/// - The integrated loudness is −0.691 + 10·log10 of the mean of the blocks above both gates: the absolute, −70 LUFS, and
///   the relative, 10 LU under the loudness of the blocks above the absolute one (`integrated`).
///
/// A track is measured once over the whole take (design §4.4), segment by segment from each one's first frame: its
/// blocks are those of every segment, one after the other. Because the weighting is linear, the energies of the dry
/// sound, of the clean voice and of their cross give the blocks of the track at any cleanup, as the mix plays it
/// (`blocks(of:cleanup:mixChannels:)`), without measuring it again.
public enum Loudness {
    public static let algorithm = "loudness-1"
    /// 400 ms at 48 kHz.
    public static let blockFrames = 19_200
    /// 100 ms at 48 kHz: 75 % of overlap between two blocks.
    public static let hopFrames = 4_800

    /// The absolute gate, in LUFS.
    static let absoluteGate = -70.0
    /// The relative gate, in LU from the loudness of the blocks above the absolute one.
    static let relativeGate = -10.0
    /// What normalizing brings a microphone to, and the other audio tracks (system audio, a device's audio), in LUFS.
    static let microphoneTarget = -16.0
    static let otherTarget = -20.0
    /// The largest change normalizing makes, either way, in dB.
    static let maximumGain = 20.0
    /// A track measured under this, in LUFS, is left as it is: there is nothing in it to bring up.
    static let quietest = -60.0
    /// The frames `measure` reads at a time: 1 s.
    static let chunkFrames: Int64 = 48_000

    /// The K-weighting filter of BS.1770-4 at 48 kHz for one channel: the high shelf of its first stage, then the
    /// high-pass (RLB) of its second, each a biquad in direct form I, with the coefficients the standard gives.
    public struct KWeighting: Sendable {
        // The shelf's last two inputs and outputs, then the high-pass's.
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        private var u1 = 0.0, u2 = 0.0, v1 = 0.0, v2 = 0.0

        public init() {}

        /// The weighted sample for the next input sample `x`.
        public mutating func process(_ x: Double) -> Double {
            let shelf = 1.53512485958697 * x - 2.69169618940638 * x1 + 1.19839281085285 * x2
                + 1.69065929318241 * y1 - 0.73248077421585 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = shelf
            let weighted = shelf - 2 * u1 + u2 + 1.99004745483398 * v1 - 0.99007225036621 * v2
            u2 = u1
            u1 = shelf
            v2 = v1
            v1 = weighted
            return weighted
        }
    }

    /// The energy of each block of `channels` (one array of samples per channel, all as long), from their first sample.
    /// - Precondition: the channels are all as long.
    public static func blockEnergies(_ channels: [[Float]]) -> [Double] {
        guard let frames = channels.first?.count else { return [] }
        precondition(channels.allSatisfy { $0.count == frames }, "Loudness: channels of different lengths")
        var meter = Meter(channels: channels.count, measuresWet: false)
        for start in stride(from: 0, to: frames, by: Int(chunkFrames)) {
            let chunk = start..<min(start + Int(chunkFrames), frames)
            meter.add(channels.map { $0[chunk].map(Double.init) }, wet: nil)
        }
        return meter.dry.energies
    }

    /// `blockEnergies(_:)` of samples in double precision.
    static func blockEnergies(doubles channels: [[Double]]) -> [Double] {
        guard let frames = channels.first?.count else { return [] }
        precondition(channels.allSatisfy { $0.count == frames }, "Loudness: channels of different lengths")
        var meter = Meter(channels: channels.count, measuresWet: false)
        for start in stride(from: 0, to: frames, by: Int(chunkFrames)) {
            let chunk = start..<min(start + Int(chunkFrames), frames)
            meter.add(channels.map { Array($0[chunk]) }, wet: nil)
        }
        return meter.dry.energies
    }

    /// The blocks `measure` finds in a segment whose dry sound is `dry` (one array per channel) and whose clean voice is
    /// `wet`, all as long.
    static func energies(dry: [[Double]], wet: [Double]) -> (dry: [Double], wet: [Double], cross: [Double]) {
        precondition(dry.allSatisfy { $0.count == wet.count }, "Loudness: channels of different lengths")
        var meter = Meter(channels: dry.count, measuresWet: true)
        for start in stride(from: 0, to: wet.count, by: Int(chunkFrames)) {
            let chunk = start..<min(start + Int(chunkFrames), wet.count)
            meter.add(dry.map { Array($0[chunk]) }, wet: Array(wet[chunk]))
        }
        return (meter.dry.energies, meter.wet?.energies ?? [], meter.cross?.energies ?? [])
    }

    /// The integrated loudness, in LUFS, of the blocks of energy `blocks`: −0.691 + 10·log10 of the mean of those above
    /// −70 LUFS and above the loudness of those minus 10 LU. `nil` when no block is above −70 LUFS (silence).
    public static func integrated(_ blocks: [Double]) -> Double? {
        func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
        let gated = blocks.filter { $0 > 0 && $0.isFinite && loudness($0) > absoluteGate }
        guard !gated.isEmpty else { return nil }
        let threshold = loudness(gated.reduce(0, +) / Double(gated.count)) + relativeGate
        let kept = gated.filter { loudness($0) > threshold }
        guard !kept.isEmpty else { return nil }
        return loudness(kept.reduce(0, +) / Double(kept.count))
    }

    /// The blocks of a track measured as `loudness` as the mix plays it, with `mixChannels` channels and the cleanup
    /// `cleanup` (0 to 1; outside, the nearest; not a number, 0) mixing `cleanup × clean + (1 − cleanup) × dry` on each:
    /// `e = (m/n)·((1 − c)²·dry + 2c(1 − c)·cross) + m·c²·wet`, with `n` the track's channels and `m` the mix's (a mono
    /// track goes to each channel of a stereo mix, and so does the clean voice, mono). Without the clean voice (`wet` or
    /// `cross` missing, or not one block for each dry one) or at cleanup 0, the track sounds dry: `(m/n)·dry`.
    public static func blocks(of loudness: TrackLoudness, cleanup: Double, mixChannels: Int) -> [Double] {
        let scale = Double(max(mixChannels, 1)) / Double(max(loudness.channels, 1))
        let c = cleanup.isNaN ? 0 : min(max(cleanup, 0), 1)
        let dry = loudness.dry
        guard c > 0, let wet = loudness.wet, let cross = loudness.cross, wet.count == dry.count, cross.count == dry.count else {
            return dry.map { scale * $0 }
        }
        let dryWeight = (1 - c) * (1 - c), crossWeight = 2 * c * (1 - c), wetWeight = Double(max(mixChannels, 1)) * c * c
        return dry.indices.map { scale * (dryWeight * dry[$0] + crossWeight * cross[$0]) + wetWeight * wet[$0] }
    }

    /// The gain that normalizes a track of `kind` measured at `measured` LUFS: from there to −16 LUFS for a microphone
    /// and −20 for the rest, by at most 20 dB either way. 1 for a track with no measure (silence) or one under −60 LUFS.
    public static func gain(measured: Double?, kind: TrackKind) -> Float {
        guard let measured, measured.isFinite, measured >= quietest else { return 1 }
        let target = kind == .microphone ? microphoneTarget : otherTarget
        let decibels = min(max(target - measured, -maximumGain), maximumGain)
        return Float(pow(10, decibels / 20))
    }

    /// The measure of segment `span` of `audio`, and of its clean voice in the CAF file at `clean` when there is one of
    /// its kind (a regular file, never a link, of mono Float32 LPCM at 48 kHz) with exactly the span's frames: a file
    /// of another length is stale and is not used, as none. Reads 1 s at a time on a thread of its own, never on
    /// Swift's cooperative pool, and never more of the track than that.
    /// - Throws: `CancellationError` if the task is cancelled (seen between two reads); what reading the clean file
    ///   throws.
    public static func measure(_ audio: TrackAudio, span: TrackAudioSpan, clean: URL?) async throws -> SegmentLoudness {
        try Task.checkCancellation()
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await offTheCooperativePool { try measure(audio, span: span, clean: clean, cancelled: cancelled) }
        } onCancel: {
            cancelled.cancel()
        }
    }

    private static func measure(
        _ audio: TrackAudio, span: TrackAudioSpan, clean: URL?, cancelled: CancellationFlag
    ) throws -> SegmentLoudness {
        let file = clean.flatMap { CleanFile($0, frames: Int64(span.frames.count)) }
        let channels = audio.channels
        let reader = audio.makeReader()
        var meter = Meter(channels: channels, measuresWet: file != nil)
        var samples: [Float] = [], wet: [Float] = []
        var frame = span.frames.lowerBound
        while frame < span.frames.upperBound {
            if cancelled.isCancelled { throw CancellationError() }
            let end = min(frame + chunkFrames, span.frames.upperBound)
            reader.read(frame..<end, into: &samples)
            let dry = (0..<channels).map { c in stride(from: c, to: samples.count, by: channels).map { Double(samples[$0]) } }
            if let file { try file.read(Int(end - frame), into: &wet) }
            meter.add(dry, wet: file == nil ? nil : wet.map(Double.init))
            frame = end
        }
        return SegmentLoudness(
            algorithm: algorithm, channels: channels, dry: meter.dry.energies, wet: meter.wet?.energies,
            cross: meter.cross?.energies, clean: file?.identity)
    }

    /// The energies of the blocks of a stream fed one frame at a time: the sum of each frame's energy over each 100 ms,
    /// and of four of those for each block.
    struct Blocks {
        private(set) var energies: [Double] = []
        /// The last three sums of 100 ms, the oldest first, and how many there have been.
        private var hops = (0.0, 0.0, 0.0)
        private var hopCount = 0
        /// The sum of the 100 ms under way, and its frames.
        private var hop = 0.0
        private var frames = 0

        mutating func add(_ energy: Double) {
            hop += energy
            frames += 1
            guard frames == Loudness.hopFrames else { return }
            if hopCount >= 3 { energies.append((hops.0 + hops.1 + hops.2 + hop) / Double(Loudness.blockFrames)) }
            hops = (hops.1, hops.2, hop)
            hopCount += 1
            hop = 0
            frames = 0
        }
    }

    /// The K-weighted block energies of the dry sound of a segment, summed over its channels, and, when it measures it, of
    /// its clean voice and of their cross, fed the segment in order, a few frames at a time. However the frames are fed,
    /// the energies are the same: each frame's sum over the channels, in their order, then the blocks of those.
    struct Meter {
        private var filters: [KWeighting]
        private var wetFilter = KWeighting()
        private(set) var dry = Blocks()
        private(set) var wet: Blocks?
        private(set) var cross: Blocks?
        /// Each frame's energy, its product with the clean voice and the clean voice weighted, of the frames being fed.
        private var energy: [Double] = []
        private var product: [Double] = []
        private var weighted: [Double] = []

        init(channels: Int, measuresWet: Bool) {
            filters = Array(repeating: KWeighting(), count: channels)
            if measuresWet {
                wet = Blocks()
                cross = Blocks()
            }
        }

        /// Takes the next frames: `samples[c]` those of channel `c` of the dry sound, and `clean` the clean voice's,
        /// when it measures it; all as long.
        /// - Precondition: one array for each channel, and the clean voice exactly when it measures it.
        mutating func add(_ samples: [[Double]], wet clean: [Double]?) {
            precondition(samples.count == filters.count && (clean != nil) == (wet != nil), "Loudness: frames of another kind")
            let frames = clean?.count ?? samples.first?.count ?? 0
            precondition(samples.allSatisfy { $0.count == frames }, "Loudness: channels of different lengths")
            energy = Array(repeating: 0, count: frames)
            if let clean {
                weighted = clean.map { wetFilter.process($0) }
                product = Array(repeating: 0, count: frames)
            }
            for c in filters.indices {
                var filter = filters[c]
                samples[c].withUnsafeBufferPointer { x in
                    energy.withUnsafeMutableBufferPointer { e in
                        if clean == nil {
                            for i in 0..<frames {
                                let y = filter.process(x[i])
                                e[i] += y * y
                            }
                        } else {
                            weighted.withUnsafeBufferPointer { w in
                                product.withUnsafeMutableBufferPointer { p in
                                    for i in 0..<frames {
                                        let y = filter.process(x[i])
                                        e[i] += y * y
                                        p[i] += w[i] * y
                                    }
                                }
                            }
                        }
                    }
                }
                filters[c] = filter
            }
            for i in 0..<frames { dry.add(energy[i]) }
            if clean != nil {
                for i in 0..<frames {
                    wet?.add(weighted[i] * weighted[i])
                    cross?.add(product[i])
                }
            }
        }
    }
}

/// A segment's clean voice as `Loudness.measure` reads it, in order.
private final class CleanFile {
    /// `"<bytes>-<modification ns>"`, by `lstat`.
    let identity: String
    private let url: URL
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    /// The file at `url` if it is a regular file (by `lstat`: a link is never followed) of mono Float32 LPCM at 48 kHz,
    /// `frames` frames long; `nil` otherwise.
    init?(_ url: URL, frames: Int64) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.fileFormat.commonFormat == .pcmFormatFloat32, file.fileFormat.sampleRate == TrackAudio.sampleRate,
              file.fileFormat.channelCount == 1, file.length == frames,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Loudness.chunkFrames))
        else { return nil }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        identity = "\(info.st_size)-\(modified)"
        self.url = url
        self.file = file
        self.buffer = buffer
    }

    /// The next `count` frames (at most `Loudness.chunkFrames`) into `samples`.
    /// - Throws: what reading throws, or `CocoaError.fileReadCorruptFile` if the file ends before them.
    func read(_ count: Int, into samples: inout [Float]) throws {
        samples.removeAll(keepingCapacity: true)
        while samples.count < count {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count - samples.count))
            let read = Int(buffer.frameLength)
            guard read > 0, let channel = buffer.floatChannelData?[0] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: read))
        }
    }
}
