// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import Foundation
import Synchronization
import os

/// Where the preview's playback stands (design §7.7): while there is audio, the samples delivered to the output, less
/// its latency; with none after the last delivery (the buffer empty, or the output stopped), on by the host's clock from
/// there. The video picks its frame by it.
///
/// Host times are seconds of the host clock, `HostTime.nanoseconds / 10⁹` (`mach_absolute_time`'s clock).
public struct PlaybackClock: Equatable, Sendable {
    /// The output time, in seconds, of the first frame delivered.
    let startSeconds: Double
    let sampleRate: Double
    /// The frames delivered so far, the output's latency, and the host time by which they were delivered.
    private var frames = 0
    private var latency = 0.0
    private var deliveredBy: Double?

    /// A clock at `startSeconds`, with nothing delivered yet: it stays there until the first delivery.
    public init(startSeconds: Double, sampleRate: Double) {
        self.startSeconds = startSeconds
        self.sampleRate = sampleRate
    }

    /// `frames` more frames, at `sampleRate`, have been delivered to the output by host time `hostSeconds`; the output
    /// plays a frame `latency` seconds after it is delivered.
    public mutating func delivered(frames: Int, latency: Double, hostSeconds: Double) {
        self.frames += frames
        self.latency = latency
        deliveredBy = hostSeconds
    }

    /// The output time being heard at host time `host`: the frames delivered, less the latency, and the host time since
    /// the last delivery; never before `startSeconds`, where it waits until the first frame is heard.
    public func seconds(atHost host: Double) -> Double {
        guard let deliveredBy else { return startSeconds }
        return max(startSeconds, startSeconds + Double(frames) / sampleRate - latency + (host - deliveredBy))
    }
}

/// The preview's sound (design §7.7): the export's own mix, `EditedMix`, played through an `AVAudioEngine`, whose clock
/// (`clock`) leads the playback.
///
/// - An `AVAudioSourceNode` (48 kHz, the mix's channels, into the engine's main mixer) only copies from an
///   `AudioRingBuffer`; a feeder of its own, a thread off Swift's cooperative pool and off the main thread, fills it
///   ahead with `EditedMix.render` in blocks of `blockFrames`, up to `capacityFrames`. The first block of each `play`
///   (a new mix, or a jump) is rendered with a preroll of `jumpPreroll` (a stretched clip's stretch starts 0.2 s before
///   it, `EditedMix.render`); the blocks after go on from it. At 1× the samples are the export's (the limiter, after a
///   jump into the middle, settles from 1 s before it, which gives the export's samples but for a peak's inaudible
///   trace, `EditedMix`).
/// - The engine starts off the main thread (`play`; with Bluetooth it can take hundreds of milliseconds), after the
///   feeder has filled `primeFrames`. If the feeder falls behind the output, the output plays silence and its frames go
///   on counting; the feeder then skips to `skipFrames` past where the output is, so the sound keeps time with the
///   clock instead of playing late.
/// - When the output changes (`AVAudioEngineConfigurationChange`: other headphones, another device), the engine stops
///   itself; the player starts again from where the clock is. If it cannot, the clock goes on by the host's.
/// - The clock counts the frames the node gives, at 48 kHz, not the hardware's: from where `play` started, every frame,
///   the silence of a skip included, so the frame being heard is the mix's frame at that place.
///
/// `setMix` rules from the next `play`: the editor gives it the mix of each revision (`EditedMix.with`). Scrubbing makes
/// no sound (design §5.5): the editor does not play while the playhead is dragged.
///
/// Not thread-safe: one owner calls it, from one isolation (the editor's main actor). Inside, the engine is used only on
/// a serial queue of its own.
public final class PreviewAudioPlayer {
    /// The frames the feeder renders at a time.
    static let blockFrames = 4_096
    /// What the ring holds: 0.51 s ahead of the output.
    static let capacityFrames = 6 * blockFrames
    /// What the feeder fills before the engine starts.
    static let primeFrames = 2 * blockFrames
    /// How far past the output a feeder that fell behind it starts again: the time to render a block after a jump.
    static let skipFrames = blockFrames
    /// The preroll of the first block after a jump, in seconds (design §7.7).
    static let jumpPreroll = 0.2

    private let core: Core

    /// A player of `mix` through `engine`, stopped. The engine is not touched until `play`.
    public init(mix: EditedMix, engine: AVAudioEngine = AVAudioEngine()) {
        core = Core(mix: mix, engine: engine)
    }

    deinit {
        core.shutDown()
    }

    /// The mix the next `play` plays; what is playing goes on with the one it started with.
    public func setMix(_ mix: EditedMix) {
        core.setMix(mix)
    }

    /// Plays the mix from output time `fromSeconds`, stopping what was playing: fills the first blocks and starts the
    /// engine, off the main thread, and returns once the output is running. The clock waits at `fromSeconds` until the
    /// first frame is heard.
    /// - Throws: what `AVAudioEngine.start` throws; the player is then stopped.
    public nonisolated(nonsending) func play(fromSeconds: Double) async throws {
        try await core.play(fromSeconds: fromSeconds)
    }

    /// Stops playing: the clock stays where it is now, and the engine pauses off the main thread.
    public func stop() {
        core.stop()
    }

    /// The clock of what is playing; stopped, one that stays where playing stopped (or where `play` was asked to start,
    /// until it has).
    public var clock: PlaybackClock { core.clock }

    /// The frames the node has to read, for the tests.
    var bufferedFrames: Int { core.ring?.availableFrames ?? 0 }
    /// The node's ring, for the tests.
    var ring: AudioRingBuffer? { core.ring }
    /// The number of what is playing (each `play` and each start after the output changed has its own), for the tests.
    var runGeneration: Int? { core.runGeneration }

    /// The node's render block: it only copies the frames from `ring` into the node's buffers (silence for any not
    /// filled) and notes the host time of the reading. It captures nothing else, and neither allocates, locks nor
    /// touches anything of the main actor: it runs on the audio thread. Made here, outside any actor's isolation, so
    /// the block does not inherit one (Swift 6 would check it on the audio thread and stop the app).
    nonisolated static func renderBlock(reading ring: AudioRingBuffer) -> AVAudioSourceNodeRenderBlock {
        { @Sendable _, timestamp, frameCount, list in
            let time = timestamp.pointee
            let host = time.mFlags.contains(.hostTimeValid) && time.mHostTime != 0 ? time.mHostTime : mach_absolute_time()
            ring.read(into: UnsafeMutableAudioBufferListPointer(list), frames: Int(frameCount), hostTime: host)
            return noErr
        }
    }

    /// The mix's frame at output time `seconds`, as the time map rounds it (`EditedMix.frames(ofNanoseconds:)`).
    static func frame(ofSeconds seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return EditedMix.frames(ofNanoseconds: Int64((min(max(seconds, -1e9), 1e9) * 1e9).rounded()))
    }

    /// Host time `ticks` (`mach_absolute_time`) in seconds.
    static func seconds(ofHostTime ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// The host clock now, in seconds.
    static func hostSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}

/// What the player does, off its owner's isolation: the engine and the node, used only on `queue`, and the state the
/// clock and `stop` read from anywhere, behind a lock.
///
/// Unchecked `Sendable`: `engine`, `node`, `nodeRing`, `feeder` and `observer` are only touched on `queue`.
private final class Core: @unchecked Sendable {
    private struct Run {
        var generation: Int
        var mix: EditedMix
        /// The node's ring, or none when the engine could not start again after the output changed (the clock then goes
        /// on by the host's from `startHost`).
        var ring: AudioRingBuffer?
        var start: Double
        var startHost: Double
        var latency: Double
    }

    private struct State {
        /// Moves on with every `play`, `stop` and restart: work queued for an older one is not done.
        var generation = 0
        /// The mix the next `play` plays.
        var mix: EditedMix
        var run: Run?
        /// Where the clock stands while nothing runs.
        var position = 0.0
        /// The node's ring, once there is a node.
        var ring: AudioRingBuffer?
        /// The feeder of the last `play`, to stop it at once.
        var feeder: Feeder?

        func clock() -> PlaybackClock {
            let sampleRate = AudioTrackTimeline.sampleRate
            guard let run else { return PlaybackClock(startSeconds: position, sampleRate: sampleRate) }
            var clock = PlaybackClock(startSeconds: run.start, sampleRate: sampleRate)
            guard let ring = run.ring else {
                clock.delivered(frames: 0, latency: 0, hostSeconds: run.startHost)
                return clock
            }
            let reading = ring.lastRead
            if reading.hostTime != 0 {
                clock.delivered(
                    frames: reading.framesBefore, latency: run.latency, hostSeconds: PreviewAudioPlayer.seconds(ofHostTime: reading.hostTime))
            }
            return clock
        }
    }

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "PreviewAudio")

    private let queue = DispatchQueue(label: "dev.toma.PreviewAudio", qos: .userInitiated)
    private let state: Mutex<State>
    private let engine: AVAudioEngine
    private var node: AVAudioSourceNode?
    private var nodeRing: AudioRingBuffer?
    private var feeder: Feeder?
    private var observer: (any NSObjectProtocol)?

    init(mix: EditedMix, engine: AVAudioEngine) {
        state = Mutex(State(mix: mix))
        self.engine = engine
    }

    var clock: PlaybackClock { state.withLock { $0.clock() } }
    var ring: AudioRingBuffer? { state.withLock { $0.ring } }
    var runGeneration: Int? { state.withLock { $0.run?.generation } }

    func setMix(_ mix: EditedMix) {
        state.withLock { $0.mix = mix }
    }

    func play(fromSeconds seconds: Double) async throws {
        let (generation, mix) = state.withLock { state in
            state.generation += 1
            state.feeder?.cancel()
            state.run = nil
            state.position = seconds
            return (state.generation, state.mix)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                continuation.resume(with: Result { try self.start(generation, mix: mix, from: seconds) })
            }
        }
    }

    func stop() {
        let now = PreviewAudioPlayer.hostSeconds()
        state.withLock { state in
            state.position = state.clock().seconds(atHost: now)
            state.generation += 1
            state.run = nil
            state.feeder?.cancel()
        }
        queue.async { self.halt() }
    }

    /// Stops for good, for the player's `deinit`: the engine stops and lets the node go, off the caller's thread.
    func shutDown() {
        state.withLock { state in
            state.generation += 1
            state.run = nil
            state.feeder?.cancel()
        }
        queue.async {
            self.halt()
            self.engine.stop()
            if let node = self.node { self.engine.detach(node) }
            if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    // MARK: - On the queue

    /// Plays `mix` from `seconds` for `play` number `generation`, unless another came after it.
    private func start(_ generation: Int, mix: EditedMix, from seconds: Double) throws {
        halt()
        let ring = prepareNode(channels: mix.channels)
        ring.reset()
        let feeder = Feeder(mix: mix, ring: ring, first: PreviewAudioPlayer.frame(ofSeconds: seconds))
        let current = state.withLock { state in
            guard state.generation == generation else { return false }
            state.feeder = feeder
            return true
        }
        guard current else { return }
        self.feeder = feeder
        feeder.start()
        feeder.waitUntilPrimed()
        guard isCurrent(generation) else { return halt() }
        if !engine.isRunning {
            do {
                engine.prepare()
                try engine.start()
            } catch {
                halt()
                throw error
            }
        }
        let latency = engine.outputNode.presentationLatency
        let host = PreviewAudioPlayer.hostSeconds()
        state.withLock { state in
            guard state.generation == generation else { return }
            state.run = Run(generation: generation, mix: mix, ring: ring, start: seconds, startHost: host, latency: latency)
        }
    }

    /// Stops the feeder, waiting for it to finish its block, and pauses the engine.
    private func halt() {
        if let feeder {
            feeder.cancel()
            feeder.join()
            self.feeder = nil
        }
        if engine.isRunning { engine.pause() }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.generation == generation }
    }

    /// The node for a mix of `channels` channels, attached and connected to the main mixer, and its ring: the one there
    /// is if it has those channels, a new one otherwise. Only while the engine is not running.
    private func prepareNode(channels: Int) -> AudioRingBuffer {
        if let nodeRing, nodeRing.channels == channels { return nodeRing }
        if let node { engine.detach(node) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: AudioTrackTimeline.sampleRate, channels: AVAudioChannelCount(channels))
        else { preconditionFailure("PreviewAudioPlayer: no format of \(channels) channels") }
        let ring = AudioRingBuffer(capacityFrames: PreviewAudioPlayer.capacityFrames, channels: channels)
        let node = AVAudioSourceNode(format: format, renderBlock: PreviewAudioPlayer.renderBlock(reading: ring))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.node = node
        nodeRing = ring
        state.withLock { $0.ring = ring }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                queue.async { self.restart() }
            }
        }
        return ring
    }

    /// After the output changed, plays on from where the clock is, with the mix that was playing; nothing if nothing
    /// was. If the engine cannot start again, the clock goes on by the host's.
    private func restart() {
        let now = PreviewAudioPlayer.hostSeconds()
        let restarting = state.withLock { state -> (generation: Int, mix: EditedMix, position: Double)? in
            guard let run = state.run else { return nil }
            let position = state.clock().seconds(atHost: now)
            state.generation += 1
            state.run = nil
            state.position = position
            return (state.generation, run.mix, position)
        }
        guard let restarting else { return }
        Self.logger.info("The output changed: the preview's audio starts again at \(restarting.position, privacy: .public) s")
        halt()
        engine.stop()
        do {
            try start(restarting.generation, mix: restarting.mix, from: restarting.position)
        } catch {
            Self.logger.error("The preview's audio cannot start again (\(String(describing: error), privacy: .public)); the clock goes on by the host's")
            state.withLock { state in
                guard state.generation == restarting.generation else { return }
                state.run = Run(
                    generation: restarting.generation, mix: restarting.mix, ring: nil, start: restarting.position,
                    startHost: PreviewAudioPlayer.hostSeconds(), latency: 0)
            }
        }
    }
}

/// Fills a player's ring with its mix from frame `first` (ring position 0), on a thread of its own, until cancelled:
/// a block of `blockFrames` whenever the ring has room for it, the first and each after a skip with `jumpPreroll`.
private final class Feeder: Sendable {
    private let mix: EditedMix
    private let ring: AudioRingBuffer
    private let first: Int64
    private let cancelled = Atomic(false)
    /// Signalled to wake the thread from waiting for room; once it has filled `primeFrames` (or stopped); once it ends.
    private let wake = DispatchSemaphore(value: 0)
    private let primed = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    init(mix: EditedMix, ring: AudioRingBuffer, first: Int64) {
        self.mix = mix
        self.ring = ring
        self.first = first
    }

    func start() {
        let thread = Thread { self.run() }
        thread.name = "dev.toma.PreviewAudio.feeder"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        wake.signal()
    }

    /// Waits until the thread has ended. Once.
    func join() {
        finished.wait()
    }

    /// Waits until the ring holds `primeFrames`, or the thread ended, for at most 2 s.
    func waitUntilPrimed() {
        _ = primed.wait(timeout: .now() + .seconds(2))
    }

    private func run() {
        var isPrimed = false
        defer {
            if !isPrimed { primed.signal() }
            finished.signal()
        }
        let block = PreviewAudioPlayer.blockFrames
        var samples: [Float] = []
        // The ring position of the next frame written, and whether it does not follow on from the last block.
        var next = 0
        var jumped = true
        while !cancelled.load(ordering: .relaxed) {
            let read = ring.readPosition
            if read > next {
                // The output went past what was filled: on from a little after where it is, in time with the clock.
                next = read + PreviewAudioPlayer.skipFrames
                ring.skip(to: next)
                jumped = true
            }
            guard next + block - read <= ring.capacityFrames else {
                _ = wake.wait(timeout: .now() + .milliseconds(5))
                continue
            }
            let from = first + Int64(next)
            mix.render(outputFrames: from..<(from + Int64(block)), into: &samples, preroll: jumped ? PreviewAudioPlayer.jumpPreroll : 0)
            jumped = false
            next += samples.withUnsafeBufferPointer { ring.write($0) }
            if !isPrimed, next >= PreviewAudioPlayer.primeFrames {
                isPrimed = true
                primed.signal()
            }
        }
    }
}
