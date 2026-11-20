// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Dispatch
import Export
import Synchronization

/// A piece of what the microphone heard, in mono Float32 at 48 kHz (`TrackAudio.sampleRate`).
public struct LiveAudioChunk: Equatable, Sendable {
    public var samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }
}

/// The microphone heard live, for Follow the Voice (plan 3d, decision 15). `append` is what a capture listener calls
/// (`MeteredSource.listen`): it copies the block's bytes and returns, from any thread, so the capture's own memory is
/// never held (`AVCaptureAudioDataOutput` gives its blocks out of a pool: holding one can make it drop samples, the
/// recording's). The blocks are converted on the
/// feed's own queue to mono Float32 at 48 kHz with `AVAudioConverter`, their channels averaged, and wait in `chunks`
/// for its reader, who gets everything that came since it last read in one chunk: at most the newest `keptSeconds`,
/// the rest dropped. A reader that is behind, or none, never makes the feed hold more than two seconds of audio, and
/// nothing it does reaches the thread that appends; nor does more than `keptSeconds` and a half wait to be converted.
///
/// One reader, one run: `chunks` is made once. After `finish()` the reader gets what is left at once, the newest
/// `keptSeconds` of what came before (what the converter held back included) once it is all converted, and then the
/// chunks end; they end too when the reader is cancelled. What is appended after either is dropped.
public final class LiveMicrophoneFeed: Sendable {
    /// What a reader that is behind gets at most: the newest seconds.
    public static let keptSeconds = 2.0

    /// What was heard, as it is converted: read once, by one reader.
    public let chunks: AsyncStream<LiveAudioChunk>

    private let core: Core

    public init() {
        let core = Core()
        self.core = core
        chunks = AsyncStream(unfolding: { await core.heard.next() }, onCancel: { core.readerLeft() })
    }

    /// A feed let go without `finish()` finishes: its reader gets the rest and its chunks end, never waiting forever.
    deinit {
        core.finish()
    }

    /// Copies the audio of `sample`, a block of linear PCM in any format (another kind of block is dropped), to be
    /// converted on the feed's queue, and returns: it never keeps `sample`, nor waits for the conversion or the reader.
    public func append(_ sample: CMSampleBuffer) {
        core.append(sample)
    }

    /// Ends the feed: the blocks appended before are converted, the reader gets what is left of them in one chunk, and
    /// then its chunks end.
    public func finish() {
        core.finish()
    }
}

/// What `LiveMicrophoneFeed` shares with its stream: the blocks waiting to be converted, the conversion, and the audio
/// waiting for the reader.
private final class Core: Sendable {
    /// The newest frames kept for the reader: `keptSeconds` at 48 kHz.
    static let keptFrames = Int(LiveMicrophoneFeed.keptSeconds * TrackAudio.sampleRate)
    /// The most audio that waits to be converted, if the queue is behind.
    static let pendingSeconds = LiveMicrophoneFeed.keptSeconds + 0.5

    /// Converts the blocks, one batch after the other, off the thread that appends them.
    private let queue = DispatchQueue(label: "LiveMicrophoneFeed", qos: .userInitiated)
    private let blocks = Mutex(Blocks())
    /// Touched only on `queue`.
    private let converter = Mutex(MonoConverter())
    let heard = HeardAudio(keptFrames: keptFrames)

    /// The blocks appended and not converted yet.
    private struct Blocks {
        var pending: [HeldBlock] = []
        var pendingSeconds = 0.0
        /// A drain is scheduled on the queue, or running.
        var draining = false
        /// `finish()` was called, or the reader left: nothing more is kept.
        var closed = false
    }

    func append(_ sample: CMSampleBuffer) {
        guard let block = HeldBlock(sample: sample) else { return }
        let schedules = blocks.withLock { blocks -> Bool in
            guard !blocks.closed else { return false }
            blocks.pending.append(block)
            blocks.pendingSeconds += block.seconds
            // The queue is behind (it never is for long): only the newest seconds are worth converting, a little more
            // than the reader is kept, so what it is kept is all after the blocks dropped here.
            while blocks.pendingSeconds > Self.pendingSeconds, blocks.pending.count > 1 {
                blocks.pendingSeconds -= blocks.pending.removeFirst().seconds
            }
            guard !blocks.draining else { return false }
            blocks.draining = true
            return true
        }
        if schedules { queue.async { self.drain() } }
    }

    func finish() {
        let closes = blocks.withLock { blocks -> Bool in
            guard !blocks.closed else { return false }
            blocks.closed = true
            return true
        }
        guard closes else { return }
        heard.finishing()
        // After the drains already scheduled, on the same queue: what came before `finish` is all converted.
        queue.async {
            self.drain()
            let tail = self.converter.withLock { $0.flush() }
            if !tail.isEmpty { self.heard.push(tail) }
            self.heard.end()
        }
    }

    /// The reader left (cancelled): nothing more is kept, converted or given.
    func readerLeft() {
        blocks.withLock { blocks in
            blocks.closed = true
            blocks.pending = []
            blocks.pendingSeconds = 0
        }
        heard.readerLeft()
    }

    /// Converts the pending blocks, on `queue`, until none is left.
    private func drain() {
        while true {
            let batch = blocks.withLock { blocks -> [HeldBlock] in
                guard !blocks.pending.isEmpty else {
                    blocks.draining = false
                    return []
                }
                defer {
                    blocks.pending = []
                    blocks.pendingSeconds = 0
                }
                return blocks.pending
            }
            guard !batch.isEmpty else { return }
            for block in batch {
                let samples = converter.withLock { $0.convert(block) }
                if !samples.isEmpty { heard.push(samples) }
            }
        }
    }
}

/// A captured block's audio on its way to the feed's queue: its bytes, copied when it is appended, never the block.
struct HeldBlock: Sendable {
    let format: CMAudioFormatDescription
    /// The bytes of each of the block's `AudioBuffer`s: one if it is interleaved, one per channel otherwise.
    let buffers: [[UInt8]]
    let frames: Int
    /// How long it lasts.
    let seconds: Double

    /// `nil` for a block that is not linear PCM, or empty.
    init?(sample: CMSampleBuffer) {
        guard let format = sample.formatDescription, let asbd = format.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0, sample.numSamples > 0
        else { return nil }
        var buffers: [[UInt8]] = []
        do {
            try sample.withAudioBufferList { list, _ in
                for buffer in list {
                    guard let data = buffer.mData else {
                        buffers.append([])
                        continue
                    }
                    buffers.append(Array(UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize))))
                }
            }
        } catch {
            return nil
        }
        self.format = format
        self.buffers = buffers
        frames = sample.numSamples
        seconds = Double(frames) / asbd.mSampleRate
    }
}

/// The converted audio waiting for the reader, at most the newest `keptFrames`, and the reader waiting for it.
final class HeardAudio: Sendable {
    private struct State {
        /// Not read yet, oldest first: `frames` in all, never more than `keptFrames`.
        var chunks: [[Float]] = []
        var frames = 0
        /// The reader, waiting: while `chunks` is empty, or until the end once the feed is finishing.
        var waiter: CheckedContinuation<LiveAudioChunk?, Never>?
        /// `finish()` was called: the reader gets the rest at once, at the end.
        var finishing = false
        /// Nothing more comes: the reader gets what is left, then nothing.
        var ended = false
        /// The reader left: nothing is kept any more.
        var readerLeft = false

        /// Everything not read yet, in one chunk, and none is left; `nil` if there is none.
        mutating func takeAll() -> LiveAudioChunk? {
            guard !chunks.isEmpty else { return nil }
            defer {
                chunks = []
                frames = 0
            }
            return LiveAudioChunk(samples: chunks.count == 1 ? chunks[0] : Array(chunks.joined()))
        }
    }

    private let state = Mutex(State())
    private let keptFrames: Int

    init(keptFrames: Int) {
        self.keptFrames = keptFrames
    }

    /// Gives `samples` to the reader if it waits for them; keeps them otherwise, dropping the oldest beyond `keptFrames`.
    func push(_ samples: [Float]) {
        let waiter = state.withLock { state -> CheckedContinuation<LiveAudioChunk?, Never>? in
            guard !state.readerLeft, !state.ended else { return nil }
            if !state.finishing, let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.chunks.append(samples)
            state.frames += samples.count
            var excess = state.frames - keptFrames
            while excess > 0 {
                let first = state.chunks[0].count
                if first <= excess {
                    state.chunks.removeFirst()
                    state.frames -= first
                    excess -= first
                } else {
                    state.chunks[0].removeFirst(excess)
                    state.frames -= excess
                    excess = 0
                }
            }
            return nil
        }
        waiter?.resume(returning: LiveAudioChunk(samples: samples.count > keptFrames ? Array(samples.suffix(keptFrames)) : samples))
    }

    /// Everything not read yet, in one chunk; waits for the next samples if there are none. Once the feed is finishing,
    /// waits for the end and gives what is left at once. `nil` once the feed ended and everything was read, or the
    /// reader was cancelled.
    func next() async -> LiveAudioChunk? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LiveAudioChunk?, Never>) in
                let ready = state.withLock { state -> LiveAudioChunk?? in
                    if state.readerLeft { return .some(nil) }
                    if state.ended { return .some(state.takeAll()) }
                    if !state.finishing, let chunk = state.takeAll() { return .some(chunk) }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            readerLeft()
        }
    }

    /// `finish()` was called: what is converted from now on waits for the end, then the reader gets it all at once.
    func finishing() {
        state.withLock { $0.finishing = true }
    }

    /// Nothing more comes: a waiting reader gets what is left, or `nil` if nothing is.
    func end() {
        let (waiter, rest) = state.withLock { state -> (CheckedContinuation<LiveAudioChunk?, Never>?, LiveAudioChunk?) in
            state.ended = true
            guard let waiter = state.waiter else { return (nil, nil) }
            state.waiter = nil
            return (waiter, state.takeAll())
        }
        waiter?.resume(returning: rest)
    }

    /// The reader was cancelled: it gets `nil` if it waits, and nothing is kept any more.
    func readerLeft() {
        let waiter = state.withLock { state -> CheckedContinuation<LiveAudioChunk?, Never>? in
            state.readerLeft = true
            state.chunks = []
            state.frames = 0
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }
}

/// Turns blocks of any linear PCM into mono Float32 at 48 kHz: an `AVAudioConverter` to Float32 at 48 kHz with the
/// block's channels, kept while the format stays (its resampler carries from one block to the next), then the mean of
/// the channels. Mono Float32 at 48 kHz is taken as it is.
struct MonoConverter {
    private enum Path {
        case none
        /// Mono Float32 at 48 kHz already.
        case asItIs
        case converting(AVAudioConverter, output: AVAudioFormat)
        /// The converter could not be made for this format: its blocks are dropped.
        case unusable
    }

    private var input: AVAudioFormat?
    private var path = Path.none

    /// The mono samples of `block` at 48 kHz, after what the converter held back of the format before if it changed.
    mutating func convert(_ block: HeldBlock) -> [Float] {
        let format = AVAudioFormat(cmAudioFormatDescription: block.format)
        var samples: [Float] = []
        if input.map({ !$0.isEqual(format) }) ?? true {
            samples = flush()
            begin(format)
        }
        let frames = AVAudioFrameCount(block.frames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return samples }
        buffer.frameLength = frames
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard list.count == block.buffers.count else { return samples }
        for (index, bytes) in block.buffers.enumerated() {
            guard let data = list[index].mData else { return samples }
            let count = min(bytes.count, Int(list[index].mDataByteSize))
            guard count > 0 else { continue }
            bytes.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: count) }
        }
        return samples + convert(buffer)
    }

    /// What the converter still holds of the format so far (the resampler's last frames), and it is done with it.
    mutating func flush() -> [Float] {
        defer {
            input = nil
            path = .none
        }
        return convert(nil)
    }

    private mutating func begin(_ format: AVAudioFormat) {
        input = format
        if format.commonFormat == .pcmFormatFloat32, format.channelCount == 1, format.sampleRate == TrackAudio.sampleRate {
            path = .asItIs
        } else if let output = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32, sampleRate: TrackAudio.sampleRate, channels: format.channelCount,
                      interleaved: false),
                  let converter = AVAudioConverter(from: format, to: output) {
            path = .converting(converter, output: output)
        } else {
            path = .unusable
        }
    }

    /// `buffer` (in the input format) in mono at 48 kHz; `nil`: the end, what the converter holds back.
    private func convert(_ buffer: AVAudioPCMBuffer?) -> [Float] {
        switch path {
        case .none, .unusable:
            return []
        case .asItIs:
            guard let buffer, let data = buffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        case .converting(let converter, let output):
            let ratio = output.sampleRate / converter.inputFormat.sampleRate
            // Room for the block and what the resampler gives back of the one before; more is taken in another round.
            let capacity = AVAudioFrameCount((Double(buffer?.frameLength ?? 0) * ratio).rounded(.up)) + 1_024
            var given = false
            var mono: [Float] = []
            while let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) {
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, status in
                    if let buffer, !given {
                        given = true
                        status.pointee = .haveData
                        return buffer
                    }
                    status.pointee = buffer == nil ? .endOfStream : .noDataNow
                    return nil
                }
                if status == .error { return mono }
                mono += Self.mean(of: converted)
                guard status == .haveData, converted.frameLength == converted.frameCapacity else { return mono }
            }
            return mono
        }
    }

    /// The mean of the channels of `buffer`, Float32 non-interleaved, frame by frame.
    private static func mean(of buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard count > 0, channels > 0, let data = buffer.floatChannelData else { return [] }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: count)) }
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channels {
            let samples = data[channel]
            for frame in 0..<count { mono[frame] += samples[frame] }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<count { mono[frame] *= scale }
        return mono
    }
}
