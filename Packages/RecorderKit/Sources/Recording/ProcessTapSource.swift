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
/// starting, and the permission prompt, would wait for a sound); while nothing plays, silence arrives.
///
/// The IOProc runs on a queue of its own, never behind the pipeline's work (a sync to disk, a new segment) that
/// would make the audio thread miss its deadline and leave gaps: there its buffers are copied into samples on the
/// host clock (`TapSampleBuffers`), and each sample is then handed to the queue given to `start`.
///
/// The tap follows the processes while it runs: when the list of audio processes changes it takes the processes
/// again, and updates its description in place if they changed (a chosen app opened mid-take is recorded from
/// then on). While the chosen apps are not running the tap names only a placeholder, this process, and its buffers
/// are recorded as silence, so Toma's own sound is never recorded. A change of the tap's format, a restart of the
/// audio server and the aggregate device dying each end the run with an error, and the pipeline starts it again in a
/// new segment.
///
/// No permission can be read: if the user refused it, the tap delivers silence without an error.
public final class ProcessTapSource: CaptureSource, @unchecked Sendable {
    public let trackID = "system-audio"
    public let kind = TrackKind.systemAudio
    public let media = TrackMedia.audio
    public let sourceInfo: TrackSource

    private let scope: SystemAudioScope
    private let ownPID = getpid()
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier
    /// Every Core Audio call that builds, updates or destroys a run happens here, one at a time. Never on a queue the
    /// IOProc runs on: `AudioDeviceStart` and `AudioDeviceStop` may wait for an IOProc, and `AudioDeviceStart` for the
    /// permission prompt.
    private let controlQueue = DispatchSerialQueue(label: "dev.toma.ProcessTapSource.control")
    /// Where the IOProc runs (it is dispatched here synchronously from the audio thread). Only copies run here.
    private let ioQueue = DispatchSerialQueue(label: "dev.toma.ProcessTapSource.io")
    private let runs = CaptureRunLifecycle<Tap>(trackID: "system-audio")

    public init(scope: SystemAudioScope) {
        self.scope = scope
        sourceInfo = SystemAudioSelection.trackSource(scope: scope, ownBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// System audio has no device.
    public var activeDeviceUniqueID: String? { nil }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        // The previous run, if any, is torn down on the control queue.
        let (id, lastQueue) = runs.beginStart()
        await lastQueue?.drain()
        // Runs after any teardown already queued, so two taps of this source never overlap.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            controlQueue.async { [self] in
                continuation.resume(with: Result { try begin(id: id, queue: queue, sink: sink) })
            }
        }
    }

    public func stop() async {
        let lastQueue = runs.stop()
        // The tap is torn down (a `start` in progress included, which then throws `CancellationError`), so its IOProc
        // runs no more; a copy it was making has finished; and the samples it handed over, an error included, have
        // been delivered or dropped.
        await controlQueue.drain()
        await ioQueue.drain()
        await lastQueue?.drain()
    }

    // MARK: - Control queue

    /// Builds the tap, its aggregate device, its IOProc and its listeners, and starts it. Runs on `controlQueue`.
    private func begin(id: Int, queue: DispatchSerialQueue, sink: any CaptureSink) throws {
        let processes = try AudioProcessCatalog.processes()
        let ownObjectID = try AudioProcessCatalog.objectID(forPID: ownPID)
        let targets = SystemAudioSelection.targets(scope: scope, processes: processes, ownPID: ownPID, ownObjectID: ownObjectID)
        let tap = Tap(controlQueue: controlQueue, targets: targets)
        do {
            try tap.build(
                description: description(for: targets, processes: processes), ioQueue: ioQueue,
                silent: SystemAudioSelection.isPlaceholder(targets, ownObjectID: ownObjectID)
            ) { [weak self] input, time, io in
                self?.deliver(runID: id, input: input, time: time, io: io)
            }
            // Their calls wait on the control queue until this returns, and find no run if it throws.
            let system = AudioObjectID(kAudioObjectSystemObject)
            try tap.listen(on: system, to: kAudioHardwarePropertyProcessObjectList) { [weak self] in
                self?.refreshTargets(runID: id)
            }
            try tap.listen(on: tap.tapID, to: kAudioTapPropertyFormat) { [weak self] in
                self?.checkFormat(runID: id)
            }
            try tap.listen(on: system, to: kAudioHardwarePropertyServiceRestarted) { [weak self] in
                self?.runs.fail(runID: id, error: CaptureSourceError.systemAudioUnavailable(status: Int32(kAudioHardwareNotRunningError)))
            }
            try tap.listen(on: tap.aggregateID, to: kAudioDevicePropertyDeviceIsAlive) { [weak self] in
                self?.checkAlive(runID: id)
            }
        } catch {
            tap.tearDown()
            throw error
        }
        guard runs.install(id: id, resource: tap, queue: queue, sink: sink) else {
            tap.tearDown()
            throw CancellationError()
        }

        let status = AudioDeviceStart(tap.aggregateID, tap.procID)
        let outcome = runs.finishStart(
            id: id, deviceUniqueID: nil, failure: status == noErr ? nil : CaptureSourceError.systemAudioUnavailable(status: status))
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
        guard let tap = activeTap(runID: runID) else { return }
        let processes: [AudioProcessInfo]
        let next: TapTargets
        let silent: Bool
        do {
            let ownObjectID = try AudioProcessCatalog.objectID(forPID: ownPID)
            processes = try AudioProcessCatalog.processes()
            next = SystemAudioSelection.targets(scope: scope, processes: processes, ownPID: ownPID, ownObjectID: ownObjectID)
            silent = SystemAudioSelection.isPlaceholder(next, ownObjectID: ownObjectID)
        } catch {
            runs.fail(runID: runID, error: error)
            return
        }
        guard !SystemAudioSelection.sameTargets(next, tap.targets) else { return }
        if silent { tap.io.silent = true }
        do {
            try tap.update(description(for: next, processes: processes))
        } catch {
            runs.fail(runID: runID, error: error)
            return
        }
        tap.targets = next
        tap.io.silent = silent
    }

    /// The tap said its format changed: ends the run if it did. Runs on `controlQueue`.
    private func checkFormat(runID: Int) {
        guard let tap = activeTap(runID: runID) else { return }
        guard let initial = tap.initialTapFormat, let now = try? tap.readTapFormat(), Tap.same(initial, now) else {
            runs.fail(runID: runID, error: CaptureSourceError.systemAudioUnavailable(status: Int32(kAudioDeviceUnsupportedFormatError)))
            return
        }
    }

    /// The aggregate device said whether it is alive: ends the run if it is not. Runs on `controlQueue`.
    private func checkAlive(runID: Int) {
        guard let tap = activeTap(runID: runID), !tap.isAlive() else { return }
        runs.fail(runID: runID, error: CaptureSourceError.systemAudioUnavailable(status: Int32(kAudioHardwareBadDeviceError)))
    }

    /// Run `runID`'s tap, while it is the active run and has not failed.
    private func activeTap(runID: Int) -> Tap? {
        runs.activeRun().flatMap { $0.id == runID ? $0.resource : nil }
    }

    private func description(for targets: TapTargets, processes: [AudioProcessInfo]) -> CATapDescription {
        let description = switch targets {
        case .allExcept(let processes): CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        case .only(let processes): CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.name = "Toma System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        if #available(macOS 26, *) {
            description.bundleIDs = SystemAudioSelection.tapBundleIDs(
                scope: scope, targets: targets, processes: processes, ownPID: ownPID, ownBundleIdentifier: ownBundleIdentifier)
        }
        return description
    }

    // MARK: - IOProc

    /// Called by the IOProc, on `ioQueue`: copies the buffers into a sample, then hands it to the run's queue, where it
    /// goes to the sink if the run is still active. A failed copy ends the run the same way, after the samples
    /// already handed over.
    private func deliver(runID: Int, input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>, io: TapIO) {
        guard let (queue, sink) = runs.delivery(forRun: runID), time.pointee.mFlags.contains(.hostTimeValid) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, io.bytesPerFrame > 0 else { return }
        let frames = first.mDataByteSize / io.bytesPerFrame
        guard frames > 0 else { return }
        let hostTime = time.pointee.mHostTime
        let sample: CMSampleBuffer
        do {
            // A disabled stream has no data; its buffers still say how much there would have been.
            sample = io.silent || buffers.contains { $0.mData == nil }
                ? try TapSampleBuffers.silence(frameCount: frames, format: io.formatDescription, hostTime: hostTime)
                : try TapSampleBuffers.make(from: input, frameCount: frames, format: io.formatDescription, hostTime: hostTime)
        } catch {
            runs.fail(runID: runID, error: error)
            return
        }
        // Not annotated `Sendable`; nothing touches it after this.
        nonisolated(unsafe) let handed = sample
        queue.async { [runs, trackID] in
            guard runs.delivery(forRun: runID) != nil else { return }
            sink.source(trackID, didOutput: handed)
        }
    }
}

/// What the IOProc reads: the description of the aggregate's input stream, made once per run, and whether the tap
/// names only its placeholder, which the control queue changes while the IOProc runs.
private final class TapIO: @unchecked Sendable {
    /// Immutable once made, and Core Media's objects are safe to share.
    let formatDescription: CMAudioFormatDescription
    let bytesPerFrame: UInt32
    private let silence: Atomic<Bool>

    init(format: AudioStreamBasicDescription, silent: Bool) throws {
        formatDescription = try TapSampleBuffers.formatDescription(for: format)
        bytesPerFrame = format.mBytesPerFrame
        silence = Atomic(silent)
    }

    var silent: Bool {
        get { silence.load(ordering: .acquiring) }
        set { silence.store(newValue, ordering: .releasing) }
    }
}

/// The Core Audio objects of one run: the tap, its aggregate device, the IOProc and the property listeners, and the
/// processes the tap names. `@unchecked Sendable` because they are built, updated and destroyed only on the source's
/// control queue (each method checks it); the IOProc reads only `io`. One that is released before its teardown, by a
/// source released without `stop`, destroys what it built on a queue of its own.
private final class Tap: CaptureRunResource, @unchecked Sendable {
    private let controlQueue: DispatchSerialQueue
    /// The processes the tap names now.
    var targets: TapTargets
    /// Set by `build`.
    private(set) var io: TapIO!
    /// The tap's format when it was built, to tell a real change from a notification that changes nothing.
    private(set) var initialTapFormat: AudioStreamBasicDescription?
    private var tapUUID: UUID?
    private var objects: HALObjects

    var tapID: AudioObjectID { objects.tapID }
    var aggregateID: AudioObjectID { objects.aggregateID }
    var procID: AudioDeviceIOProcID? { objects.procID }

    init(controlQueue: DispatchSerialQueue, targets: TapTargets) {
        self.controlQueue = controlQueue
        self.targets = targets
        objects = HALObjects(controlQueue: controlQueue)
    }

    deinit {
        guard !objects.isEmpty else { return }
        // Wherever the last reference went (the IOProc's queue included), never destroyed from there.
        let objects = self.objects
        DispatchQueue.global(qos: .utility).async { objects.destroy() }
    }

    /// Tears it down on the control queue, after anything already queued there.
    func end() {
        controlQueue.async { self.tearDown() }
    }

    /// Creates the tap, a private aggregate device holding only it, and an IOProc on `ioQueue` that calls `deliver`
    /// with the input buffers, their time and `io`, which starts `silent` or not.
    func build(
        description: CATapDescription, ioQueue: DispatchSerialQueue, silent: Bool,
        deliver: @escaping (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>, TapIO) -> Void
    ) throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        objects.tapID = tap
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
        objects.aggregateID = aggregate

        let io = try TapIO(format: try inputFormat(), silent: silent)
        self.io = io
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) { _, input, inputTime, _, _ in
            deliver(input, inputTime, io)
        }
        guard status == noErr, let proc else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        objects.procID = proc
    }

    /// Calls `handler` on the control queue whenever `selector` of `object` changes, until `tearDown`.
    func listen(on object: AudioObjectID, to selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        var address = Self.globalAddress(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, controlQueue, block)
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        // Removing takes the same block object, which this value is.
        objects.listeners.append(HALObjects.Listener(object: object, address: address, block: block))
    }

    /// Gives the tap `description` in place, under the UID the aggregate device knows it by.
    func update(_ description: CATapDescription) throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        if let tapUUID { description.uuid = tapUUID }
        do {
            try AudioHardwareTap(id: tapID).setDescription(description)
        } catch let error as AudioHardwareError {
            throw CaptureSourceError.systemAudioUnavailable(status: error.error)
        }
    }

    func readTapFormat() throws -> AudioStreamBasicDescription {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        var address = Self.globalAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        return format
    }

    /// Whether the aggregate device is alive; not if that cannot be read.
    func isAlive() -> Bool {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        var address = Self.globalAddress(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    /// Stops and destroys what was built, in reverse order: listeners, IOProc, aggregate device, tap. Safe to call
    /// again.
    func tearDown() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        objects.destroy()
        objects = HALObjects(controlQueue: controlQueue)
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
            guard let data = bytes.baseAddress else { return noErr }
            return AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, data)
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

/// The Core Audio objects a tap built, as plain IDs, so they can be destroyed from wherever the tap ends.
/// `@unchecked Sendable`: the listener blocks are not annotated, and are only handed back to Core Audio.
private struct HALObjects: @unchecked Sendable {
    struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    /// The queue the listeners were added with, which removing them names.
    let controlQueue: DispatchSerialQueue
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var listeners: [Listener] = []

    var isEmpty: Bool {
        tapID == kAudioObjectUnknown && aggregateID == kAudioObjectUnknown && procID == nil && listeners.isEmpty
    }

    /// Removes the listeners, stops and destroys the IOProc, then destroys the aggregate device and the tap.
    func destroy() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, controlQueue, listener.block)
        }
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }
}
