// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
import CoreMedia
import Darwin
import Foundation
import ProjectFormat
import Synchronization

/// Records the sound the Mac plays, mixed to stereo, with a Core Audio process tap: every app but Toma and the
/// notification and alert sounds, or only the chosen apps (`SystemAudioScope`, `SystemAudioSelection`).
///
/// Each run creates a private tap (`CATapDescription`, `AudioHardwareCreateProcessTap`) and a private aggregate
/// device that holds only that tap: no sub-device, so no input of the output device is opened (Bluetooth
/// headphones keep their quality) and the IOProc gets only the tap's stream. The aggregate has no
/// `kAudioAggregateDeviceTapAutoStartKey`, so `AudioDeviceStart` returns at once even when nothing plays (with it,
/// starting, and the permission prompt, would wait for a sound); while nothing plays, silence arrives. The IOProc
/// runs on the queue given to `start`, and its buffers are copied into samples on the host clock
/// (`TapSampleBuffers`).
///
/// The tap follows the processes while it runs: when the list of audio processes changes it takes the processes
/// again, and updates its description in place if they changed (a chosen app opened mid-take is recorded from
/// then on). While the chosen apps are not running the tap names only a placeholder, this process, and its buffers
/// are recorded as silence, so Toma's own sound is never recorded. A change of the tap's format ends the run with
/// an error, and the pipeline goes on in a new segment.
///
/// No permission can be read: if the user refused it, the tap delivers silence without an error.
public final class ProcessTapSource: CaptureSource, @unchecked Sendable {
    public let trackID = "system-audio"
    public let kind = TrackKind.systemAudio
    public let media = TrackMedia.audio
    private let scope: SystemAudioScope
    public let sourceInfo: TrackSource

    private let ownPID = getpid()
    /// The bundle IDs the tap names on macOS 26 (`CATapDescription.bundleIDs`), so a process that starts mid-take,
    /// such as `systemsoundserverd`, is left out or taken from its first buffer: the ones `sourceInfo` names.
    private let tapBundleIDs: [String]
    /// Every Core Audio call that builds, updates or destroys a run happens here, one at a time. Never on the queue
    /// the samples go to: `AudioDeviceStart` and `AudioDeviceStop` may wait for an IOProc running there, and
    /// `AudioDeviceStart` for the permission prompt.
    private let controlQueue = DispatchSerialQueue(label: "dev.toma.ProcessTapSource.control")
    private let state = Mutex(State())

    private struct State {
        /// Bumped by every `start` and `stop`, so a `start` overtaken by a later call gives up.
        var generation = 0
        var run: Run?
        /// Queue of the last run installed. Kept when the run ends, so `start` and `stop` can wait for a delivery
        /// still running there, such as the error that ended it.
        var lastQueue: DispatchSerialQueue?
    }

    /// One `start`, until it is stopped or fails.
    private struct Run: Sendable {
        let id: Int
        let tap: Tap
        let queue: DispatchSerialQueue
        let sink: any CaptureSink
        /// The processes the tap names now.
        var targets: TapTargets
        /// The tap names only its placeholder: its buffers are recorded as silence.
        var silent: Bool
        /// Set once `AudioDeviceStart` succeeded and `start` is about to return.
        var started = false
        /// An error before `started`, which `start` throws instead of delivering.
        var failure: (any Error)?
    }

    private enum StartOutcome {
        case started
        case failed(any Error)
        case overtaken
    }

    public init(scope: SystemAudioScope) {
        self.scope = scope
        sourceInfo = SystemAudioSelection.trackSource(scope: scope, ownBundleIdentifier: Bundle.main.bundleIdentifier)
        tapBundleIDs = sourceInfo.includedBundleIDs ?? sourceInfo.excludedBundleIDs ?? []
    }

    /// System audio has no device.
    public var activeDeviceUniqueID: String? { nil }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        let (id, previous, lastQueue) = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return (state.generation, state.run, state.lastQueue)
        }
        if let previous {
            let tap = previous.tap
            controlQueue.async { tap.tearDown() }
        }
        await lastQueue?.drain()
        // Runs after any teardown already queued, so two taps of this source never overlap.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            controlQueue.async { [self] in
                continuation.resume(with: Result { try begin(id: id, queue: queue, sink: sink) })
            }
        }
    }

    public func stop() async {
        let (run, lastQueue) = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return (state.run, state.lastQueue)
        }
        if let run {
            let tap = run.tap
            controlQueue.async { tap.tearDown() }
        }
        // The tap is torn down (a `start` in progress included, which then throws `CancellationError`), and
        // deliveries already queued, an error included, have finished.
        await controlQueue.drain()
        await lastQueue?.drain()
    }

    // MARK: - Control queue

    /// Builds the tap, its aggregate device and its IOProc, and starts it. Runs on `controlQueue`.
    private func begin(id: Int, queue: DispatchSerialQueue, sink: any CaptureSink) throws {
        let processes = try AudioProcessCatalog.processes()
        let ownObjectID = try AudioProcessCatalog.objectID(forPID: ownPID)
        let targets = SystemAudioSelection.targets(scope: scope, processes: processes, ownPID: ownPID, ownObjectID: ownObjectID)
        let tap = Tap(controlQueue: controlQueue)
        do {
            try tap.build(description: description(for: targets), queue: queue) { [weak self] input, time, format in
                self?.deliver(runID: id, input: input, time: time, format: format)
            }
        } catch {
            tap.tearDown()
            throw error
        }
        let installed = state.withLock { state in
            guard state.generation == id else { return false }
            state.run = Run(
                id: id, tap: tap, queue: queue, sink: sink, targets: targets,
                silent: SystemAudioSelection.isPlaceholder(targets, ownObjectID: ownObjectID))
            state.lastQueue = queue
            return true
        }
        guard installed else {
            tap.tearDown()
            throw CancellationError()
        }
        do {
            try tap.listen(on: AudioObjectID(kAudioObjectSystemObject), to: kAudioHardwarePropertyProcessObjectList) { [weak self] in
                self?.refreshTargets(runID: id)
            }
            try tap.listen(on: tap.tapID, to: kAudioTapPropertyFormat) { [weak self] in
                self?.checkFormat(runID: id)
            }
        } catch {
            state.withLock { state in
                if state.run?.id == id { state.run = nil }
            }
            tap.tearDown()
            throw error
        }

        let status = AudioDeviceStart(tap.aggregateID, tap.procID)
        let outcome = state.withLock { state -> StartOutcome in
            guard var run = state.run, run.id == id else { return .overtaken }
            if let failure = run.failure {
                state.run = nil
                return .failed(failure)
            }
            guard status == noErr else {
                state.run = nil
                return .failed(CaptureSourceError.systemAudioUnavailable(status: status))
            }
            run.started = true
            state.run = run
            return .started
        }
        switch outcome {
        case .started:
            // A process that came or went between reading the list and listening to it.
            controlQueue.async { [self] in refreshTargets(runID: id) }
        case .failed(let error):
            tap.tearDown()
            throw error
        case .overtaken:
            // The `stop` or `start` that took this run queued its teardown after this call.
            throw CancellationError()
        }
    }

    /// The processes changed: takes them again and, if the tap's changed, updates the tap in place. Runs on
    /// `controlQueue`. Silence goes on before the tap may take only this process, and comes off once it takes others.
    private func refreshTargets(runID: Int) {
        let current = state.withLock { state in
            state.run.flatMap { $0.id == runID && $0.failure == nil ? ($0.tap, $0.targets) : nil }
        }
        guard let (tap, targets) = current else { return }
        let next: TapTargets
        let silent: Bool
        do {
            let ownObjectID = try AudioProcessCatalog.objectID(forPID: ownPID)
            next = SystemAudioSelection.targets(
                scope: scope, processes: try AudioProcessCatalog.processes(), ownPID: ownPID, ownObjectID: ownObjectID)
            silent = SystemAudioSelection.isPlaceholder(next, ownObjectID: ownObjectID)
        } catch {
            fail(runID: runID, error: error)
            return
        }
        guard next != targets else { return }
        if silent { setSilent(true, runID: runID) }
        do {
            try tap.update(description(for: next))
        } catch {
            fail(runID: runID, error: error)
            return
        }
        state.withLock { state in
            guard var run = state.run, run.id == runID else { return }
            run.targets = next
            run.silent = silent
            state.run = run
        }
    }

    /// The tap said its format changed: ends the run if it did. Runs on `controlQueue`.
    private func checkFormat(runID: Int) {
        guard let tap = state.withLock({ state in state.run.flatMap { $0.id == runID ? $0.tap : nil } }) else { return }
        guard let initial = tap.initialTapFormat, let now = try? tap.readTapFormat(), Tap.same(initial, now) else {
            fail(runID: runID, error: CaptureSourceError.systemAudioUnavailable(status: Int32(kAudioDeviceUnsupportedFormatError)))
            return
        }
    }

    private func setSilent(_ silent: Bool, runID: Int) {
        state.withLock { state in
            guard var run = state.run, run.id == runID else { return }
            run.silent = silent
            state.run = run
        }
    }

    private func description(for targets: TapTargets) -> CATapDescription {
        let description = switch targets {
        case .allExcept(let processes): CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        case .only(let processes): CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.name = "Toma System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        if #available(macOS 26, *) {
            description.bundleIDs = tapBundleIDs
        }
        return description
    }

    // MARK: - Failures

    /// From any thread: handled on the run's queue, after the samples already queued there.
    private func fail(runID: Int, error: any Error) {
        let queue = state.withLock { $0.run?.id == runID ? $0.run?.queue : nil }
        queue?.async { [self] in failOnQueue(runID: runID, error: error) }
    }

    /// Runs on the run's queue. Before `start` has succeeded the error is kept for `start` to throw; afterwards the
    /// run ends: its teardown is queued first, so a restart from inside the sink cannot overlap the old tap, then the
    /// error is the run's last delivery.
    private func failOnQueue(runID: Int, error: any Error) {
        let ended = state.withLock { state -> Run? in
            guard var run = state.run, run.id == runID, run.failure == nil else { return nil }
            guard run.started else {
                run.failure = error
                state.run = run
                return nil
            }
            state.run = nil
            return run
        }
        guard let ended else { return }
        let tap = ended.tap
        controlQueue.async { tap.tearDown() }
        ended.sink.source(trackID, didStopWithError: error)
    }

    // MARK: - IOProc

    /// Called by the IOProc, on the run's queue (the IOProc is dispatched there synchronously).
    private func deliver(
        runID: Int, input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>, format: AudioStreamBasicDescription
    ) {
        let current = state.withLock { state in
            state.run.flatMap { $0.id == runID && $0.failure == nil ? ($0.sink, $0.silent) : nil }
        }
        guard let (sink, silent) = current, time.pointee.mFlags.contains(.hostTimeValid) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, format.mBytesPerFrame > 0 else { return }
        let frames = first.mDataByteSize / format.mBytesPerFrame
        guard frames > 0 else { return }
        let hostTime = time.pointee.mHostTime
        do {
            // A disabled stream has no data; its buffers still say how much there would have been.
            let sample = silent || buffers.contains { $0.mData == nil }
                ? try TapSampleBuffers.silence(frameCount: frames, format: format, hostTime: hostTime)
                : try TapSampleBuffers.make(from: input, frameCount: frames, format: format, hostTime: hostTime)
            sink.source(trackID, didOutput: sample)
        } catch {
            // Already on the run's queue: end the run now, so no later sample goes out before the error.
            failOnQueue(runID: runID, error: error)
        }
    }
}

/// The Core Audio objects of one run: the tap, its aggregate device, the IOProc and the property listeners.
/// `@unchecked Sendable` because they are built, updated and destroyed only on the source's control queue; the
/// IOProc gets the stream's format as a value.
private final class Tap: @unchecked Sendable {
    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let controlQueue: DispatchSerialQueue
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private(set) var procID: AudioDeviceIOProcID?
    /// The tap's format when it was built, to tell a real change from a notification that changes nothing.
    private(set) var initialTapFormat: AudioStreamBasicDescription?
    private var tapUUID: UUID?
    private var listeners: [Listener] = []

    init(controlQueue: DispatchSerialQueue) {
        self.controlQueue = controlQueue
    }

    /// Creates the tap, a private aggregate device holding only it, and an IOProc on `queue` that calls `deliver`
    /// with the input buffers, their time and the format of the aggregate's input stream.
    func build(
        description: CATapDescription, queue: DispatchSerialQueue,
        deliver: @escaping (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>, AudioStreamBasicDescription) -> Void
    ) throws {
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        tapID = tap
        tapUUID = description.uuid
        initialTapFormat = try? readTapFormat()

        // Private, with no sub-device and without kAudioAggregateDeviceTapAutoStartKey. The flags are CFNumbers,
        // as the header documents them (a Swift `Bool` would bridge to a CFBoolean).
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Toma System Audio",
            kAudioAggregateDeviceUIDKey: "dev.toma.ProcessTapSource.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        aggregateID = aggregate

        let format = try inputFormat()
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, inputTime, _, _ in
            deliver(input, inputTime, format)
        }
        guard status == noErr, let proc else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        procID = proc
    }

    /// Calls `handler` on the control queue whenever `selector` of `object` changes, until `tearDown`.
    func listen(on object: AudioObjectID, to selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) throws {
        var address = Self.globalAddress(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, controlQueue, block)
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        // Removing takes the same block object, which this value is.
        listeners.append(Listener(object: object, address: address, block: block))
    }

    /// Gives the tap `description` in place, under the UID the aggregate device knows it by.
    func update(_ description: CATapDescription) throws {
        if let tapUUID { description.uuid = tapUUID }
        do {
            try AudioHardwareTap(id: tapID).setDescription(description)
        } catch let error as AudioHardwareError {
            throw CaptureSourceError.systemAudioUnavailable(status: error.error)
        }
    }

    func readTapFormat() throws -> AudioStreamBasicDescription {
        var address = Self.globalAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        return format
    }

    /// Stops and destroys what was built, in reverse order: listeners, IOProc, aggregate device, tap. Safe to call
    /// again.
    func tearDown() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, controlQueue, listener.block)
        }
        listeners = []
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Whether two formats are the same, field by field.
    static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    /// The format of the aggregate device's input stream, the tap's: what the IOProc receives. LPCM only.
    private func inputFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size)
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        status = streams.withUnsafeMutableBytes { bytes in
            size = UInt32(bytes.count)
            return bytes.count == 0 ? noErr : AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        guard let stream = streams.prefix(Int(size) / MemoryLayout<AudioStreamID>.size).first else {
            throw CaptureSourceError.systemAudioUnavailable(status: Int32(kAudioHardwareBadStreamError))
        }
        address = Self.globalAddress(kAudioStreamPropertyVirtualFormat)
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format)
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBytesPerFrame > 0, format.mChannelsPerFrame > 0 else {
            throw CaptureSourceError.systemAudioUnavailable(status: Int32(kAudioDeviceUnsupportedFormatError))
        }
        return format
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
