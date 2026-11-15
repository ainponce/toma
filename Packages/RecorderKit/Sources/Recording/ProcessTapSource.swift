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
    private let runs = CaptureRunLifecycle<Tap>(trackID: "system-audio")

    public init(scope: SystemAudioScope) {
        self.scope = scope
        sourceInfo = SystemAudioSelection.trackSource(scope: scope, ownBundleIdentifier: Bundle.main.bundleIdentifier)
        tapBundleIDs = sourceInfo.includedBundleIDs ?? sourceInfo.excludedBundleIDs ?? []
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
        let tap = Tap(
            controlQueue: controlQueue, targets: targets, silent: SystemAudioSelection.isPlaceholder(targets, ownObjectID: ownObjectID))
        do {
            try tap.build(description: description(for: targets), queue: queue) { [weak self] input, time, io in
                self?.deliver(runID: id, input: input, time: time, io: io)
            }
            // Their calls wait on the control queue until this returns, and find no run if it throws.
            try tap.listen(on: AudioObjectID(kAudioObjectSystemObject), to: kAudioHardwarePropertyProcessObjectList) { [weak self] in
                self?.refreshTargets(runID: id)
            }
            try tap.listen(on: tap.tapID, to: kAudioTapPropertyFormat) { [weak self] in
                self?.checkFormat(runID: id)
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
        let next: TapTargets
        let silent: Bool
        do {
            let ownObjectID = try AudioProcessCatalog.objectID(forPID: ownPID)
            next = SystemAudioSelection.targets(
                scope: scope, processes: try AudioProcessCatalog.processes(), ownPID: ownPID, ownObjectID: ownObjectID)
            silent = SystemAudioSelection.isPlaceholder(next, ownObjectID: ownObjectID)
        } catch {
            runs.fail(runID: runID, error: error)
            return
        }
        guard next != tap.targets else { return }
        if silent { tap.io.silent = true }
        do {
            try tap.update(description(for: next))
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

    /// Run `runID`'s tap, while it is the active run and has not failed.
    private func activeTap(runID: Int) -> Tap? {
        runs.activeRun().flatMap { $0.id == runID ? $0.resource : nil }
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

    // MARK: - IOProc

    /// Called by the IOProc, on the run's queue (the IOProc is dispatched there synchronously).
    private func deliver(runID: Int, input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>, io: TapIO) {
        guard let (_, sink) = runs.delivery(forRun: runID), time.pointee.mFlags.contains(.hostTimeValid) else { return }
        let format = io.format
        let silent = io.silent
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
            // Already on the run's queue: end the run now (its teardown queued first, so a restart from inside the sink
            // cannot overlap the old tap), and no later sample goes out before the error.
            runs.failOnQueue(runID: runID, error: error)
        }
    }
}

/// What the IOProc reads: the format of the aggregate's input stream, and whether the tap names only its
/// placeholder, which the control queue changes while the IOProc runs.
private final class TapIO: Sendable {
    let format: AudioStreamBasicDescription
    private let silence: Atomic<Bool>

    init(format: AudioStreamBasicDescription, silent: Bool) {
        self.format = format
        silence = Atomic(silent)
    }

    var silent: Bool {
        get { silence.load(ordering: .acquiring) }
        set { silence.store(newValue, ordering: .releasing) }
    }
}

/// The Core Audio objects of one run: the tap, its aggregate device, the IOProc and the property listeners, and the
/// processes the tap names. `@unchecked Sendable` because they are built, updated and destroyed only on the source's
/// control queue; the IOProc reads only `io`.
private final class Tap: CaptureRunResource, @unchecked Sendable {
    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let controlQueue: DispatchSerialQueue
    /// The processes the tap names now.
    var targets: TapTargets
    private let initiallySilent: Bool
    /// Set by `build`.
    private(set) var io: TapIO!
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private(set) var procID: AudioDeviceIOProcID?
    /// The tap's format when it was built, to tell a real change from a notification that changes nothing.
    private(set) var initialTapFormat: AudioStreamBasicDescription?
    private var tapUUID: UUID?
    private var listeners: [Listener] = []

    init(controlQueue: DispatchSerialQueue, targets: TapTargets, silent: Bool) {
        self.controlQueue = controlQueue
        self.targets = targets
        initiallySilent = silent
    }

    /// Tears it down on the control queue, after anything already queued there.
    func end() {
        controlQueue.async { self.tearDown() }
    }

    /// Creates the tap, a private aggregate device holding only it, and an IOProc on `queue` that calls `deliver`
    /// with the input buffers, their time and `io`.
    func build(
        description: CATapDescription, queue: DispatchSerialQueue,
        deliver: @escaping (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>, TapIO) -> Void
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

        let io = TapIO(format: try inputFormat(), silent: initiallySilent)
        self.io = io
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, inputTime, _, _ in
            deliver(input, inputTime, io)
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
