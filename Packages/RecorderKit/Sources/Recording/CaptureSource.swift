// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Dispatch
import ProjectFormat

/// Receives what a `CaptureSource` produces.
///
/// Delivery contract: every call arrives on the queue passed to `CaptureSource.start(on:sink:)`,
/// one at a time and in order. Samples come in presentation order, timestamped on the host clock.
/// `source(_:didStopWithError:)` is the last call of a run: nothing more arrives until the next
/// `start`. Nothing arrives once `stop()` has returned.
///
/// The requirements are not isolated. An actor whose executor is that queue conforms with
/// `nonisolated` witnesses that enter the actor with `assumeIsolated`.
public protocol CaptureSink: AnyObject, Sendable {
    func source(_ trackID: String, didOutput sample: CMSampleBuffer)
    func source(_ trackID: String, didStopWithError error: any Error)
}

/// A live producer of one track: a display, a window, a camera, a microphone or system audio.
public protocol CaptureSource: AnyObject, Sendable {
    var trackID: String { get }
    var kind: TrackKind { get }
    var media: TrackMedia { get }
    var sourceInfo: TrackSource { get }
    /// The device being captured, for sources that have one: set by a successful `start`, kept
    /// after an error, cleared by `stop`.
    var activeDeviceUniqueID: String? { get }
    /// Starts delivering to `sink` on `queue`, with presentation timestamps on the host clock.
    /// May be called again after an error or after `stop()`: each call ends the previous run first
    /// and waits for its deliveries to finish. The sink is retained until the run ends (`stop()` or
    /// the error), never longer.
    ///
    /// Failures are reported once. A failure that happens before `start` returns makes `start`
    /// throw and is never delivered to the sink. `source(_:didStopWithError:)` only reports the
    /// failure of a run whose `start` succeeded. The sink can get that call on the queue before
    /// the caller has resumed from `start`. Samples may arrive as soon as capture is running,
    /// before `start` returns: ScreenCaptureKit can send the only frame of a still screen then.
    func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws
    /// Ends the current run, if any. When it returns, nothing more is delivered, a delivery that
    /// was in progress (an error included) has finished, and the sink is released.
    func stop() async
}

public enum CaptureSourceError: Error, Equatable {
    /// The display is not among the shareable displays (disconnected or asleep).
    case displayNotFound(displayID: UInt32)
    /// The window is not among the shareable windows (it was closed).
    case windowNotFound(windowID: UInt32)
    /// No audio input device is available.
    case microphoneNotFound
    /// The capture session refused the device input or its output (a microphone's or a camera's).
    case sessionConfigurationFailed
    /// `startRunning()` returned without the session running (a microphone's or a camera's).
    case sessionDidNotStart
    /// No camera is connected (or every one is suspended: a closed lid, a closed privacy iris).
    case cameraNotFound
    /// No format of the camera gives the frame rate asked for.
    case cameraFormatUnavailable
    /// The camera being recorded was disconnected.
    case cameraDisconnected
    /// The camera stopped delivering: another app took it, the session stopped, or the camera was suspended
    /// (the lid was closed).
    case cameraInterrupted
    /// Core Audio refused a step of system audio capture (listing processes, the tap, its aggregate device or
    /// its IOProc) with `status`, or the tap's format changed (`kAudioDeviceUnsupportedFormatError`).
    case systemAudioUnavailable(status: Int32)
}

extension DispatchSerialQueue {
    /// Returns once every block submitted to the queue before the call has run.
    package func drain() async {
        await withCheckedContinuation { continuation in
            self.async { continuation.resume() }
        }
    }
}
