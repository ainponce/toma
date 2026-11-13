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
    }

    /// One `start`, until it is stopped or fails. `@unchecked Sendable` because `SCStream` is not
    /// annotated: `start` hands it to the state, and whoever ends the run takes it out; the stream
    /// callbacks only compare its identity.
    private struct Run: @unchecked Sendable {
        let id: Int
        let stream: SCStream
        let queue: DispatchSerialQueue
        let sink: any CaptureSink
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
        let (id, previous) = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return (state.generation, state.run)
        }
        if let previous { await end(previous) }

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
        // A `stop` or `start` that came in while the capture was starting has taken this run out of
        // the state; its `stopCapture` may have raced the start, so stop the stream again.
        let current = state.withLock { $0.run?.id == id }
        if !current {
            await end(run)
            throw CancellationError()
        }
    }

    public func stop() async {
        let run = state.withLock { state in
            state.generation += 1
            defer { state.run = nil }
            return state.run
        }
        if let run { await end(run) }
    }

    /// Stops the stream and waits for deliveries already queued, which see the run gone and drop.
    private func end(_ run: Run) async {
        do {
            try await run.stream.stopCapture()
        } catch {
            Self.logger.error("stopCapture failed for \(self.trackID, privacy: .public): \(error, privacy: .public)")
        }
        await run.queue.drain()
    }

    // MARK: - SCStreamOutput, SCStreamDelegate

    /// Called on the queue given to `start` (the stream's sample handler queue).
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.isCompleteFrame(sampleBuffer) else { return }
        let streamID = ObjectIdentifier(stream)
        let sink = state.withLock { state in
            state.run.flatMap { ObjectIdentifier($0.stream) == streamID ? $0.sink : nil }
        }
        sink?.source(trackID, didOutput: sampleBuffer)
    }

    /// May arrive on any queue: the error is delivered on the run's queue, after the samples
    /// already queued there.
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let streamID = ObjectIdentifier(stream)
        let run = state.withLock { state in
            state.run.flatMap { ObjectIdentifier($0.stream) == streamID ? $0 : nil }
        }
        guard let run else { return }
        let id = run.id
        run.queue.async { [self] in
            let ended = state.withLock { state in
                guard state.run?.id == id else { return nil as Run? }
                defer { state.run = nil }
                return state.run
            }
            ended?.sink.source(trackID, didStopWithError: error)
        }
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
