// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Foundation
import ProjectFormat
import Recording
import Synchronization

/// A fake iPhone or iPad connected by cable, the `device` track `ExternalDeviceCaptureSource` records: `SampleFactory`
/// frames of `width` × `height` at `framesPerSecond`, timestamped with `clock()`, that turn to `height` × `width`
/// `rotateAt` seconds after its first run started (the pipeline goes on in a new segment, `formatChanged`; `nil`, never).
/// Its `sourceInfo` is the real source's: the device's name and `uniqueID`, with `globalFrame` (0, 0, `width`, `height`) in
/// pixels at `pixelScale` 1, the size its first run started with. Delivers on the start queue.
public final class SyntheticDeviceSource: CaptureSource {
    /// The `uniqueID` of the synthetic device, and of its sound.
    public static let uniqueID = "synthetic-device"
    public static let name = "Synthetic iPhone"

    public let trackID = "device"
    public let kind = TrackKind.device
    public var media: TrackMedia { video.media }

    private let video: SyntheticVideoSource
    private let size: (width: Int, height: Int)
    private let rotateAt: Double?
    private let state = Mutex(State())

    private struct State {
        var active = false
        /// Its turn is on its way: it comes once, from the first run.
        var turnScheduled = false
    }

    public init(
        width: Int, height: Int, framesPerSecond: Int = 60, rotateAt: Double? = nil,
        clock: @escaping @Sendable () -> HostTime = HostTime.now
    ) {
        precondition(rotateAt.map { $0 >= 0 && $0.isFinite } ?? true, "SyntheticDeviceSource: rotateAt must be a time from 0")
        video = SyntheticVideoSource(
            trackID: "device", kind: .device, width: width, height: height, framesPerSecond: framesPerSecond, clock: clock)
        size = (width, height)
        self.rotateAt = rotateAt
    }

    public var sourceInfo: TrackSource {
        TrackSource(
            name: Self.name, deviceUniqueID: Self.uniqueID,
            globalFrame: Rect(x: 0, y: 0, width: Double(size.width), height: Double(size.height)), pixelScale: 1)
    }

    /// The device, from a successful `start` until `stop`.
    public var activeDeviceUniqueID: String? { state.withLock { $0.active ? Self.uniqueID : nil } }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await video.start(on: queue, sink: sink)
        let turns = state.withLock { state -> Bool in
            state.active = true
            defer { state.turnScheduled = true }
            return !state.turnScheduled
        }
        guard turns, let rotateAt else { return }
        let (video, size) = (video, size)
        queue.asyncAfter(deadline: .now() + rotateAt) {
            video.resize(width: size.height, height: size.width)
        }
    }

    public func stop() async {
        await video.stop()
        state.withLock { $0.active = false }
    }
}

/// The sound of a `SyntheticDeviceSource`, the `deviceAudio` track `ExternalDeviceAudioSource` records: `SampleFactory`
/// stereo at 48 kHz in 10 ms blocks (`SyntheticAudioSource`), with the device's name and `uniqueID`.
public final class SyntheticDeviceAudioSource: CaptureSource {
    public let trackID = "deviceAudio"
    public let kind = TrackKind.deviceAudio
    public let media = TrackMedia.audio

    private let audio: SyntheticAudioSource
    private let active = Mutex(false)

    public init(clock: @escaping @Sendable () -> HostTime = HostTime.now) {
        audio = SyntheticAudioSource(trackID: "deviceAudio", kind: .deviceAudio, channels: 2, clock: clock)
        audio.deviceUniqueID = SyntheticDeviceSource.uniqueID
    }

    public var sourceInfo: TrackSource {
        TrackSource(name: SyntheticDeviceSource.name, deviceUniqueID: SyntheticDeviceSource.uniqueID)
    }

    /// The device, from a successful `start` until `stop`.
    public var activeDeviceUniqueID: String? { active.withLock { $0 ? SyntheticDeviceSource.uniqueID : nil } }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await audio.start(on: queue, sink: sink)
        active.withLock { $0 = true }
    }

    public func stop() async {
        await audio.stop()
        active.withLock { $0 = false }
    }
}
