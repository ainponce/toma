// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ProjectFormat
import ScreenCaptureKit
import Synchronization
import os

/// Captures one display with ScreenCaptureKit at native pixels, without the cursor and without the
/// app's own windows. Only complete frames are delivered.
public final class DisplayCaptureSource: NSObject, CaptureSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let trackID: String
    public let kind = TrackKind.display
    public let media: TrackMedia
    public var activeDeviceUniqueID: String? { nil }

    private let displayID: CGDirectDisplayID
    private let framesPerSecond: Int
    private let name: String
    private let state = Mutex(State())

    private struct State {
        /// Bumped by every `start` and `stop`, so a `start` overtaken by a later call gives up.
        var generation = 0
        var run: Run?
        /// Queue of the last run installed. Kept when the run ends, so `start` and `stop` can wait
        /// for a delivery still running there, such as the error that ended it.
        var lastQueue: DispatchSerialQueue?
    }

    /// One `start`, until it is stopped or fails. `@unchecked Sendable` because `SCStream` is not
    /// annotated: `start` hands it to the state, and whoever ends the run takes it out; the stream
    /// callbacks only compare its identity.
    private struct Run: @unchecked Sendable {
        let id: Int
        let stream: SCStream
        let queue: DispatchSerialQueue
        let sink: any CaptureSink
        /// Set once `startCapture` has returned and `start` is about to return successfully.
        var started = false
        /// An error from the stream before `started`, which `start` throws instead of delivering.
        var failure: (any Error)?
    }

    private enum StartOutcome {
        case started
        case failed(any Error)
        case overtaken
    }

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "DisplayCaptureSource")

    public init(displayID: CGDirectDisplayID, framesPerSecond: Int = 60) {
        self.trackID = "display-\(displayID)"
        self.media = .video(framesPerSecond: framesPerSecond)
        self.displayID = displayID
        self.framesPerSecond = framesPerSecond
        self.name = Self.displayName(displayID)
        super.init()
    }

    /// `globalFrame` is `CGDisplayBounds` (global points, origin at the top left of the main display).
    public var sourceInfo: TrackSource {
        let bounds = CGDisplayBounds(displayID)
        return TrackSource(
            name: name,
            displayID: displayID,
            globalFrame: Rect(
                x: Double(bounds.minX), y: Double(bounds.minY),
                width: Double(bounds.width), height: Double(bounds.height)),
            pixelScale: Self.pixelScale(of: displayID)
        )
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        let (id, previous, lastQueue) = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return (state.generation, state.run, state.lastQueue)
        }
        // A previous run that had not started yet is stopped by its own `start`.
        if let previous, previous.started { await stopCapture(previous.stream) }
        await lastQueue?.drain()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureSourceError.displayNotFound(displayID: displayID)
        }
        let ownApplications = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = Self.makeConfiguration(
            contentRect: filter.contentRect,
            pointPixelScale: Double(filter.pointPixelScale),
            framesPerSecond: framesPerSecond
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        let run = Run(id: id, stream: stream, queue: queue, sink: sink)
        let installed = state.withLock { state in
            guard state.generation == id else { return false }
            state.run = run
            state.lastQueue = queue
            return true
        }
        guard installed else { throw CancellationError() }
        do {
            try await stream.startCapture()
        } catch {
            state.withLock { state in
                if state.run?.id == id { state.run = nil }
            }
            throw error
        }
        let outcome = state.withLock { state -> StartOutcome in
            guard var current = state.run, current.id == id else { return .overtaken }
            if let failure = current.failure {
                state.run = nil
                return .failed(failure)
            }
            current.started = true
            state.run = current
            return .started
        }
        switch outcome {
        case .started:
            return
        case .failed(let error):
            // The stream reported the error, so it has already stopped.
            throw error
        case .overtaken:
            // A `stop` or `start` took this run while the capture was starting and left the
            // stream to this call: stop it now.
            await stopCapture(stream)
            throw CancellationError()
        }
    }

    public func stop() async {
        let (run, lastQueue) = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return (state.run, state.lastQueue)
        }
        // A run that had not started yet is stopped by its own `start`.
        if let run, run.started { await stopCapture(run.stream) }
        // Deliveries already queued (an error being delivered included) finish; later ones see no run.
        await lastQueue?.drain()
    }

    private func stopCapture(_ stream: SCStream) async {
        do {
            try await stream.stopCapture()
        } catch {
            Self.logger.error("stopCapture failed for \(self.trackID, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - SCStreamOutput, SCStreamDelegate

    /// Called on the queue given to `start` (the stream's sample handler queue).
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.isCompleteFrame(sampleBuffer) else { return }
        let streamID = ObjectIdentifier(stream)
        let sink = state.withLock { state in
            state.run.flatMap { ObjectIdentifier($0.stream) == streamID && $0.failure == nil ? $0.sink : nil }
        }
        sink?.source(trackID, didOutput: sampleBuffer)
    }

    /// May arrive on any queue: it is handled on the run's queue, after the samples already queued.
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let streamID = ObjectIdentifier(stream)
        let target = state.withLock { state in
            state.run.flatMap { ObjectIdentifier($0.stream) == streamID ? ($0.id, $0.queue) : nil }
        }
        guard let (id, queue) = target else { return }
        queue.async { [self] in fail(runID: id, error: error) }
    }

    /// Runs on the run's queue. Before `start` has succeeded the error is kept for `start` to throw;
    /// afterwards the run ends and the error is its last delivery.
    private func fail(runID: Int, error: any Error) {
        let sink = state.withLock { state -> (any CaptureSink)? in
            guard var run = state.run, run.id == runID, run.failure == nil else { return nil }
            guard run.started else {
                run.failure = error
                state.run = run
                return nil
            }
            state.run = nil
            return run.sink
        }
        sink?.source(trackID, didStopWithError: error)
    }

    // MARK: - Configuration

    /// Native pixels (`contentRect` × `pointPixelScale`), no cursor, BGRA in sRGB, at most
    /// `framesPerSecond`, no audio.
    public static func makeConfiguration(contentRect: CGRect, pointPixelScale: Double, framesPerSecond: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int((Double(contentRect.width) * pointPixelScale).rounded())
        configuration.height = Int((Double(contentRect.height) * pointPixelScale).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.queueDepth = 6
        configuration.capturesAudio = false
        return configuration
    }

    /// True for a sample whose `SCStreamFrameInfo.status` is `.complete`: the only frames that
    /// carry a new image. Idle, blank, suspended, started and stopped frames are not forwarded.
    public static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard sample.isValid, CMSampleBufferGetImageBuffer(sample) != nil,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }

    /// Pixels per point of the display's current mode (2 on Retina), or `nil` if it is not online.
    private static func pixelScale(of displayID: CGDirectDisplayID) -> Double? {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return nil }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    /// The display's localized name (for example "Built-in Retina Display") when created on the main
    /// thread, where AppKit may be used; a generic name otherwise.
    private static func displayName(_ displayID: CGDirectDisplayID) -> String {
        if Thread.isMainThread {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID }
            if let screen { return screen.localizedName }
        }
        return CGDisplayIsBuiltin(displayID) != 0 ? "Built-in Display" : "Display \(displayID)"
    }
}
