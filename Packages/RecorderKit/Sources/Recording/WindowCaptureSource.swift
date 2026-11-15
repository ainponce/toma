// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ProjectFormat
import ScreenCaptureKit

/// Captures one window with ScreenCaptureKit at `CaptureScale`, wherever it is (another Space included), without the
/// cursor, its shadow or what covers it. Only complete frames are delivered.
///
/// The filter is `SCContentFilter(desktopIndependentWindow:)`, and the frame matches the window's `kCGWindowBounds`:
/// without its shadow and its clip by the screen, dragging the window against an edge of the screen changes neither
/// the frame nor its `contentRect`. When the window is resized, the stream follows its size (`ScreenStreamCapture`)
/// and the pipeline opens a `.formatChanged` segment. A closed window ends the run with ScreenCaptureKit's error, and
/// a restart then throws `CaptureSourceError.windowNotFound`.
public final class WindowCaptureSource: NSObject, CaptureSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let trackID: String
    public let kind = TrackKind.window
    public let media: TrackMedia
    public var activeDeviceUniqueID: String? { nil }

    private let windowID: CGWindowID
    private let framesPerSecond: Int
    private let scale: CaptureScale
    private let capture: ScreenStreamCapture

    public init(windowID: CGWindowID, framesPerSecond: Int = 60, scale: CaptureScale = .native) {
        self.trackID = "window-\(windowID)"
        self.media = .video(framesPerSecond: framesPerSecond)
        self.windowID = windowID
        self.framesPerSecond = framesPerSecond
        self.scale = scale
        self.capture = ScreenStreamCapture(trackID: "window-\(windowID)", scale: scale) { size, _ in
            WindowCaptureSource.makeConfiguration(pixelSize: size, framesPerSecond: framesPerSecond)
        }
        super.init()
    }

    /// When the last complete frame arrived, on the host clock; `nil` before the first one. ScreenCaptureKit sends
    /// one only when the window changed, also while it is in another Space (`WindowVisibility`).
    public var lastCompleteFrameTime: HostTime? { capture.lastCompleteFrameTime }

    /// `name` is "<app> — <title>" (the app alone without a title); `globalFrame`, the window's `kCGWindowBounds`
    /// (global points); `pixelScale`, the pixels per point recorded (`ScreenCapture.recordedPixelScale`, with
    /// the scale of the display under the window's center). A window that does not exist only has its ID.
    public var sourceInfo: TrackSource {
        guard let window = WindowListEntry(windowID: windowID) else {
            return TrackSource(
                name: "Window \(windowID)", pixelScale: ScreenCapture.recordedPixelScale(displayScale: nil, scale: scale),
                windowID: windowID)
        }
        let app = window.ownerName ?? window.bundleIdentifier ?? "Window \(windowID)"
        return TrackSource(
            name: window.title.map { "\(app) — \($0)" } ?? app,
            globalFrame: Rect(window.bounds),
            pixelScale: ScreenCapture.recordedPixelScale(displayScale: window.displayScale, scale: scale),
            windowID: windowID,
            bundleIdentifier: window.bundleIdentifier
        )
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await capture.start(on: queue, sink: sink, output: self) {
            // Every window, on screen or not: the window may be in another Space, or minimized.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureSourceError.windowNotFound(windowID: windowID)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let pixelsPerPoint = ScreenCapture.recordedPixelScale(displayScale: Double(filter.pointPixelScale), scale: scale) ?? 1
            let size = WindowStreamSizing.pixelSize(
                contentRect: CGRect(origin: .zero, size: window.frame.size), contentScale: 1, scaleFactor: pixelsPerPoint)
            return ScreenStreamCapture.Setup(
                filter: filter, configuration: Self.makeConfiguration(pixelSize: size, framesPerSecond: framesPerSecond))
        }
    }

    public func stop() async {
        await capture.stop()
    }

    // MARK: - SCStreamOutput, SCStreamDelegate

    /// Called on the queue given to `start` (the stream's sample handler queue).
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        capture.output(stream, didOutput: sampleBuffer, of: type)
    }

    /// May arrive on any queue: it is handled on the run's queue, after the samples already queued.
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        capture.streamDidStop(stream, error: error)
    }

    // MARK: - Configuration

    /// `pixelSize` like every screen stream (`DisplayCaptureSource.makeConfiguration`), and the window alone: its
    /// child windows asked for (`includeChildWindows`, which has no documented effect with this filter: menus are not
    /// recorded), without its shadow or the screen's clip, so the frame is the window's `kCGWindowBounds`.
    public static func makeConfiguration(pixelSize: CGSize, framesPerSecond: Int) -> SCStreamConfiguration {
        let configuration = ScreenStreamCapture.configuration(
            width: Int(pixelSize.width), height: Int(pixelSize.height), framesPerSecond: framesPerSecond)
        configuration.includeChildWindows = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        return configuration
    }
}

/// A window as `CGWindowListCopyWindowInfo` describes it. Titles of other apps' windows need the Screen Recording
/// permission; without it there is none.
struct WindowListEntry {
    /// `kCGWindowBounds`: global points, origin at the top left of the main display.
    var bounds: CGRect
    /// `kCGWindowIsOnscreen`: `false` both when minimized and when in another Space.
    var onScreen: Bool
    var ownerName: String?
    var ownerPID: pid_t?
    /// `nil` when empty.
    var title: String?

    init?(windowID: CGWindowID) {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]])?.first,
              let boundsDictionary = info[kCGWindowBounds] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else { return nil }
        self.bounds = bounds
        self.onScreen = info[kCGWindowIsOnscreen] as? Bool ?? false
        self.ownerName = info[kCGWindowOwnerName] as? String
        self.ownerPID = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value
        let title = info[kCGWindowName] as? String
        self.title = title?.isEmpty == false ? title : nil
    }

    var bundleIdentifier: String? {
        ownerPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }

    /// Pixels per point of the display under the window's center, or of one it overlaps.
    var displayScale: Double? {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(CGPoint(x: bounds.midX, y: bounds.midY), 1, &displayID, &count) != .success || count == 0 {
            guard CGGetDisplaysWithRect(bounds, 1, &displayID, &count) == .success, count > 0 else { return nil }
        }
        return ScreenCapture.pixelScale(of: displayID)
    }
}

extension Rect {
    init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }
}
