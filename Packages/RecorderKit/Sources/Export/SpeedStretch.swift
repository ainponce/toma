// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import os

/// One audio track of a run of clips at a speed other than 1, up to 4×, stretched with its pitch kept (design §7.7): the
/// track's stream (`AudioTrackTimeline`) through an `AVAudioUnitTimePitch` at the run's speed, in an `AVAudioEngine`
/// rendering offline by hand, from the run's start, for exactly the output frames the time map gives the run.
///
/// - A run is the clips of one take at one speed that go on one from the other in the source (a clip split without a
///   cut): it is stretched as one stream, so the split is not heard. Its output frame `o` plays the source from about
///   `source + (o − output.lowerBound) × speed`.
/// - The effect is fed only the source heard in one go with the run (`heard`: the run's own, and that of the clips
///   before and after it that go on with it, at any speed), silence outside it, so it never takes in what was cut, not
///   even after a clip after the run shorter than its window. When the clip before goes on into the run, a stream from
///   the run's start starts `warmUpInput` frames of that source before it, the output of which is dropped: the stretch
///   is under way at the seam instead of rising from silence over its first 10 to 20 ms. (After a cut there is nothing
///   heard to start on, and the rise follows the fade in.)
/// - The effect's latency (`AVAudioUnit.latency` or its audio unit's, the larger) is made up for: the first
///   `round(latency × 48 000)` frames it gives are dropped, and it is fed on past the run's end as far as it asks, so the
///   stretched sound keeps time with the picture and the clicks and keeps the run's tail. (Both read 0 on macOS 26, and
///   the effect is in time as it is: a burst of tone at source frame `x` comes out centred at output `x / speed`.)
/// - The effect moves on in its input by whole frames, `round(hopFrames × rate)` per hop of `hopFrames` output frames, so
///   at a speed whose `hopFrames × speed` is not whole it would drift from the picture (0.11 % at 0.7×, 94 ms after a
///   minute of source). Each block of `blockFrames` is rendered at the rate of the whole step, of the two around
///   `hopFrames × speed`, that brings the input taken closest to `speed` times the output given: the sound stays within
///   8 frames of input of where the time map puts it, however long the run.
/// - The effect renders `blockFrames` at a time from the start of a stream, whatever range is asked for, and is
///   deterministic: a stream from the run's start gives the same bits every time.
///
/// A stream from the run's start is the reference, the export's. A range that does not follow on from the frames given
/// last starts a new stream when it has to: with no preroll, from the run's start (rolling on when the stream under way
/// is one from the start and the range is ahead of it); with a preroll, `preroll` frames before the range (rolling on
/// when the range is that close ahead), which is faster and can give other samples at first (the preview after a jump,
/// §7.7). A range that follows on goes on with the stream under way, whatever the preroll.
///
/// Not thread-safe: one owner reads it, from one thread at a time.
struct SpeedStretch {
    /// The clips of one take at one speed, one after the other in the output, each going on with the source of the one
    /// before: what is stretched as one stream.
    struct Run: Equatable, Sendable {
        /// The run's output frames.
        var output: Range<Int64>
        /// The timeline frame of the source at the run's first output frame.
        var source: Int64
        /// The timeline frames of the source heard in one go with the run, which contain its own: the effect is fed
        /// silence outside them.
        var heard: Range<Int64>
        /// The speed as `TimeMap` reads it (`ClipSpeed.clamped(_:)`): not 1, at most `maximumSpeed`.
        var speed: Double
    }

    /// The fastest a clip is heard at: faster, it is silent.
    static let maximumSpeed = 4.0
    /// The output frames the effect renders at a time, counted from the start of a stream.
    static let blockFrames = 4_096
    /// The output frames of each of the effect's hops at `overlap`: per hop it moves on `round(hopFrames × rate)` input
    /// frames.
    static let hopFrames = 256
    /// `AVAudioUnitTimePitch.overlap`, its default, set so the hop stays `hopFrames`.
    static let overlap: Float = 8
    /// The frames of the source heard before a run that a stream from its start takes in first, about twice what the
    /// effect takes to come up to level from silence (up to 2 700 frames of input, at 4×).
    static let warmUpInput = 6_144

    fileprivate static let logger = Logger(subsystem: "dev.toma.Toma", category: "MP4Exporter")

    /// What the stream reads the track with.
    private let reader: AudioTrackTimeline.Reader
    private let channels: Int
    private var stream: Stream?
    /// A run whose effect could not be started: silent, without trying again.
    private var failed: Run?
    /// The streams started, and the output frame the last one started at, for the tests.
    private(set) var streamsStarted = 0
    private(set) var lastStart: Int64?

    init(_ timeline: AudioTrackTimeline) {
        reader = AudioTrackTimeline.Reader(timeline)
        channels = timeline.channels
    }

    /// Writes output frames `frames` of `run`, stretched, into `samples`, which then holds exactly
    /// `frames.count × channels` values, interleaved. A new stream starts `preroll` frames before `frames` (0: at the
    /// run's start) when the range does not follow on from the frames given last (see the type).
    /// - Precondition: `frames` is within `run.output`.
    mutating func read(_ run: Run, frames: Range<Int64>, preroll: Int64, into samples: inout [Float]) {
        precondition(frames.isEmpty || frames.clamped(to: run.output) == frames, "SpeedStretch: \(frames) outside \(run.output)")
        samples.removeAll(keepingCapacity: true)
        guard !frames.isEmpty else { return }
        let first = frames.lowerBound
        let goesOn: Bool
        if let stream, stream.run == run, stream.next <= first {
            let ahead = first - stream.next
            goesOn = ahead == 0 || (preroll > 0 ? ahead <= preroll : stream.first == run.output.lowerBound)
        } else {
            goesOn = false
        }
        if !goesOn, failed != run {
            let start = preroll > 0 ? max(run.output.lowerBound, first - preroll) : run.output.lowerBound
            stream = nil
            streamsStarted += 1
            lastStart = start
            do {
                stream = try Stream(run: run, first: start, reader: reader, channels: channels)
            } catch {
                Self.logger.error("Speed stretch: cannot start the effect (\(String(describing: error), privacy: .public)); silence")
                failed = run
            }
        }
        guard let stream, stream.run == run else {
            samples.append(contentsOf: repeatElement(0, count: frames.count * channels))
            return
        }
        stream.give(frames, into: &samples)
    }
}

private enum StretchError: Error {
    case noFormat, noBuffer
    case rendering(AVAudioEngineManualRenderingStatus, frames: AVAudioFrameCount)
}

/// One stretched stream of a run: the effect in its engine, from output frame `first` on.
private final class Stream {
    let run: SpeedStretch.Run
    /// The output frame the stream started at.
    let first: Int64
    /// The output frame of the next frame it gives.
    private(set) var next: Int64

    private let channels: Int
    private let engine: AVAudioEngine
    private let effect: AVAudioUnitTimePitch
    private let buffer: AVAudioPCMBuffer
    /// What the effect gave and was not handed out yet, interleaved, from `pending[handedOut]` (output frame `next`).
    private var pending: [Float] = []
    private var handedOut = 0
    /// The blocks rendered, and the input frames the effect's hops took over them.
    private var blocks: Int64 = 0
    private var taken: Int64 = 0
    /// The frames still to drop of what the effect gives first: its latency, and the warm-up before the run.
    private var dropping: Int
    /// Rendering failed: silence from there.
    private var stopped = false

    init(run: SpeedStretch.Run, first: Int64, reader: AudioTrackTimeline.Reader, channels: Int) throws {
        self.run = run
        self.first = first
        next = first
        self.channels = channels
        let channelCount = AVAudioChannelCount(channels)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: AudioTrackTimeline.sampleRate, channels: channelCount) else {
            throw StretchError.noFormat
        }
        let blockFrames = AVAudioFrameCount(SpeedStretch.blockFrames)
        engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: blockFrames)
        // From the run's start, with what is heard before it, the stream starts on that source: its output is dropped.
        let warmUp = first == run.output.lowerBound && run.heard.lowerBound < run.source
            ? Int((Double(SpeedStretch.warmUpInput) / run.speed).rounded(.up)) : 0
        let input = run.source + Int64((Double(first - run.output.lowerBound) * run.speed).rounded())
            - Int64((Double(warmUp) * run.speed).rounded())
        let feed = Feed(reader: reader, channels: channels, from: input, heard: run.heard)
        let node = AVAudioSourceNode(format: format) { _, _, count, list in
            feed.fill(Int(count), into: list)
            return noErr
        }
        effect = AVAudioUnitTimePitch()
        effect.overlap = SpeedStretch.overlap
        effect.rate = Float(run.speed)
        engine.attach(node)
        engine.attach(effect)
        engine.connect(node, to: effect, format: format)
        engine.connect(effect, to: engine.outputNode, format: format)
        try engine.start()
        dropping = Int((max(effect.latency, effect.auAudioUnit.latency) * AudioTrackTimeline.sampleRate).rounded()) + warmUp
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: blockFrames) else {
            throw StretchError.noBuffer
        }
        self.buffer = buffer
    }

    deinit {
        engine.stop()
    }

    /// Writes output frames `frames`, at or after `next`, into `samples` (empty), interleaved: the effect renders on
    /// through what comes before them.
    func give(_ frames: Range<Int64>, into samples: inout [Float]) {
        while next < frames.lowerBound {
            if available == 0 { render() }
            let dropped = min(available, Int(frames.lowerBound - next))
            handedOut += dropped * channels
            next += Int64(dropped)
        }
        let count = frames.count * channels
        samples.reserveCapacity(count)
        while samples.count < count {
            if available == 0 { render() }
            let given = min(available * channels, count - samples.count)
            samples.append(contentsOf: pending[handedOut..<(handedOut + given)])
            handedOut += given
            next += Int64(given / channels)
        }
    }

    /// The frames in `pending` not handed out yet.
    private var available: Int { (pending.count - handedOut) / channels }

    /// Renders the next block, at the rate that keeps the input taken on `speed` times the output (see `SpeedStretch`),
    /// into `pending`, less what is left to drop.
    private func render() {
        pending.removeSubrange(0..<handedOut)
        handedOut = 0
        let blockFrames = SpeedStretch.blockFrames
        guard !stopped else {
            pending.append(contentsOf: repeatElement(0, count: blockFrames * channels))
            return
        }
        let hops = Int64(blockFrames / SpeedStretch.hopFrames)
        let target = Int64((Double((blocks + 1) * Int64(blockFrames)) * run.speed).rounded())
        let step = Int64((Double(target - taken) / Double(hops)).rounded())
        effect.rate = Float(step) / Float(SpeedStretch.hopFrames)
        taken += step * hops
        blocks += 1
        do {
            let status = try engine.renderOffline(AVAudioFrameCount(blockFrames), to: buffer)
            guard status == .success, Int(buffer.frameLength) == blockFrames, let data = buffer.floatChannelData else {
                throw StretchError.rendering(status, frames: buffer.frameLength)
            }
            let kept = blockFrames - min(dropping, blockFrames)
            dropping -= blockFrames - kept
            pending.reserveCapacity(pending.count + kept * channels)
            for frame in (blockFrames - kept)..<blockFrames {
                for channel in 0..<channels { pending.append(data[channel][frame]) }
            }
        } catch {
            SpeedStretch.logger.error("Speed stretch: rendering failed (\(String(describing: error), privacy: .public)); silence from here")
            stopped = true
            pending.append(contentsOf: repeatElement(0, count: blockFrames * channels))
        }
    }
}

/// What the effect takes in: the track's stream from a frame on, read as it asks for it, silence outside `heard`.
private final class Feed {
    private let reader: AudioTrackTimeline.Reader
    private let channels: Int
    /// The timeline frame of the next frame the effect takes.
    private var position: Int64
    private let heard: Range<Int64>
    private var frames: [Float] = []

    init(reader: AudioTrackTimeline.Reader, channels: Int, from position: Int64, heard: Range<Int64>) {
        self.reader = reader
        self.channels = channels
        self.position = position
        self.heard = heard
    }

    /// Writes the next `count` frames into the effect's buffers, one per channel.
    func fill(_ count: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let read = (position..<(position + Int64(count))).clamped(to: heard)
        if !read.isEmpty { reader.read(read, into: &frames) }
        // The frames of the buffers that are read.
        let first = Int(read.lowerBound - position), last = first + read.count
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for c in 0..<buffers.count {
            buffers[c].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
            guard let data = buffers[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channel = min(c, channels - 1)
            for i in 0..<count { data[i] = i >= first && i < last ? frames[(i - first) * channels + channel] : 0 }
        }
        position += Int64(count)
    }
}
