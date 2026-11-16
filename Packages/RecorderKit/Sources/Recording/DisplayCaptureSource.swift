// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ProjectFormat
import ScreenCaptureKit
import Synchronization
import os

/// How many pixels a display is recorded at.
public enum CaptureScale: String, Codable, Sendable, CaseIterable {
    /// The display's own pixels (2 per point on Retina).
    case native
    /// One pixel per point: a smaller file, less sharp on Retina.
    case points
}

/// Apps a display's recording leaves out, besides Toma itself.
public enum DisplayExclusions {
    /// Notification Center: the notifications, and the widgets on the desktop.
    public static let bundleIdentifiers = ["com.apple.notificationcenterui"]

    /// The processes to exclude among `apps`, in their order: this app (`ownPID`) and every app whose bundle ID is in
    /// `bundleIDs`. Also the bundle IDs no app has, and whether this app is not among them (a process without
    /// windows, such as `recorder-dev`, is never listed).
    public static func excluded(
        apps: [(pid: pid_t, bundleID: String?)], ownPID: pid_t, bundleIDs: [String]
    ) -> (pids: [pid_t], missingBundleIDs: [String], ownAppMissing: Bool) {
        let pids = apps.filter { app in app.pid == ownPID || app.bundleID.map(bundleIDs.contains) == true }.map(\.pid)
        let present = Set(apps.compactMap(\.bundleID))
        return (pids, bundleIDs.filter { !present.contains($0) }, !apps.contains { $0.pid == ownPID })
    }

    /// The bundle IDs among `bundleIDs` of the apps in `after` whose process is not in `before`, each once, in the order
    /// of `after`: the excluded apps that launched when the running applications went from `before` to `after` (the
    /// whole lists, or, for an insertion, nothing and the apps inserted).
    static func launched(
        before: [(pid: pid_t, bundleID: String?)], after: [(pid: pid_t, bundleID: String?)], bundleIDs: [String]
    ) -> [String] {
        let running = Set(before.map(\.pid))
        var launched: [String] = []
        for app in after where !running.contains(app.pid) {
            guard let bundleID = app.bundleID, bundleIDs.contains(bundleID), !launched.contains(bundleID) else { continue }
            launched.append(bundleID)
        }
        return launched
    }
}

/// Captures one display with ScreenCaptureKit at `CaptureScale`, without the cursor, the app's own windows (but for
/// `includedWindowIDs`) and the apps of `excludedBundleIDs`. Only complete frames are delivered.
///
/// It always records the whole display: an area (`captureArea`) only goes to the manifest, for the editor to crop.
/// When the display changes resolution or proportion the stream follows it (`ScreenStreamCapture`), so every frame
/// covers the whole display with the geometry of its moment, and the pipeline opens a `.formatChanged` segment. When
/// an app of `excludedBundleIDs` launches while it runs (Notification Center restarting), the filter is made again,
/// so the new process is left out too. Launches are heard from `NSWorkspace.runningApplications` (key-value
/// observed), which also lists the apps without a Dock icon (`LSUIElement`, as Notification Center is) that
/// `didLaunchApplicationNotification` leaves out, and from that notification as well. An app of `excludedBundleIDs`
/// that a start (a stream's restart too) did not find is looked for again once the stream runs: one that launched
/// while no stream ran is left out all the same.
public final class DisplayCaptureSource: NSObject, CaptureSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let trackID: String
    public let kind = TrackKind.display
    public let media: TrackMedia
    public var activeDeviceUniqueID: String? { nil }

    private let displayID: CGDirectDisplayID
    private let framesPerSecond: Int
    private let scale: CaptureScale
    private let captureArea: Rect?
    private let excludedBundleIDs: [String]
    private let includedWindowIDs: [CGWindowID]
    private let name: String
    private let capture: ScreenStreamCapture
    /// Hears the apps that launch, from the first `start` until `stop`.
    private let launches = Mutex<LaunchWatch?>(nil)

    /// What hears the apps that launch. `@unchecked Sendable`: the observer is only handed back to `removeObserver`,
    /// and the observation only invalidated.
    private struct LaunchWatch: @unchecked Sendable {
        let notification: any NSObjectProtocol
        let runningApplications: NSKeyValueObservation

        func end() {
            NSWorkspace.shared.notificationCenter.removeObserver(notification)
            runningApplications.invalidate()
        }
    }

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "DisplayCaptureSource")
    /// How many times a launched app is looked for, a second apart: its windows can come a moment after it launches.
    private static let relaunchAttempts = 3

    /// `captureArea` is in global points; `includedWindowIDs` are windows of this app that the recording keeps (the
    /// covers of the desktop icons).
    public init(
        displayID: CGDirectDisplayID, framesPerSecond: Int = 60, scale: CaptureScale = .native, captureArea: Rect? = nil,
        excludedBundleIDs: [String] = DisplayExclusions.bundleIdentifiers, includedWindowIDs: [CGWindowID] = []
    ) {
        self.trackID = "display-\(displayID)"
        self.media = .video(framesPerSecond: framesPerSecond)
        self.displayID = displayID
        self.framesPerSecond = framesPerSecond
        self.scale = scale
        self.captureArea = captureArea
        self.excludedBundleIDs = excludedBundleIDs
        self.includedWindowIDs = includedWindowIDs
        self.name = Self.displayName(displayID)
        self.capture = ScreenStreamCapture(trackID: "display-\(displayID)", scale: scale) { _, geometry in
            Self.makeConfiguration(
                contentRect: CGRect(origin: .zero, size: geometry.contentPoints), pointPixelScale: geometry.scaleFactor,
                framesPerSecond: framesPerSecond, scale: scale)
        }
        super.init()
    }

    deinit {
        launches.withLock { $0 }?.end()
    }

    /// `globalFrame` is `CGDisplayBounds` (global points, origin at the top left of the main display);
    /// `pixelScale`, the pixels per point recorded (`ScreenCapture.recordedPixelScale`); `captureArea`, the area chosen,
    /// if any.
    public var sourceInfo: TrackSource {
        let bounds = CGDisplayBounds(displayID)
        return TrackSource(
            name: name,
            displayID: displayID,
            globalFrame: Rect(
                x: Double(bounds.minX), y: Double(bounds.minY),
                width: Double(bounds.width), height: Double(bounds.height)),
            pixelScale: ScreenCapture.recordedPixelScale(displayScale: ScreenCapture.pixelScale(of: displayID), scale: scale),
            captureArea: captureArea
        )
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        observeLaunches()
        var missingBundleIDs: [String] = []
        try await capture.start(on: queue, sink: sink, output: self) {
            let made = try await makeFilter()
            missingBundleIDs = made.missingBundleIDs
            let configuration = Self.makeConfiguration(
                contentRect: made.filter.contentRect, pointPixelScale: Double(made.filter.pointPixelScale),
                framesPerSecond: framesPerSecond, scale: scale)
            return ScreenStreamCapture.Setup(filter: made.filter, configuration: configuration)
        }
        // A launch heard while no stream ran (this one restarting) found nothing to update: the apps this filter
        // missed are looked for again now that the stream runs.
        for bundleID in missingBundleIDs {
            Task { await self.refreshFilter(excluding: bundleID) }
        }
    }

    public func stop() async {
        launches.withLock { watch in
            defer { watch = nil }
            return watch
        }?.end()
        await capture.stop()
    }

    /// The display without this app and the apps of `excludedBundleIDs`, but with the windows of
    /// `includedWindowIDs`; and the bundle IDs not found. What is missing is logged.
    private func makeFilter() async throws -> (filter: SCContentFilter, missingBundleIDs: [String]) {
        // Every window, on screen or not: with only the on-screen ones, an app is listed (and excluded) only if it
        // has a window on screen right now, and a notification that comes later would be recorded.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureSourceError.displayNotFound(displayID: displayID)
        }
        let exclusions = DisplayExclusions.excluded(
            apps: content.applications.map { (pid: $0.processID, bundleID: $0.bundleIdentifier) }, ownPID: getpid(),
            bundleIDs: excludedBundleIDs)
        if !exclusions.missingBundleIDs.isEmpty {
            Self.logger.error(
                "\(self.trackID, privacy: .public) cannot exclude \(exclusions.missingBundleIDs, privacy: .public): not among the shareable apps")
        }
        if exclusions.ownAppMissing {
            Self.logger.error("\(self.trackID, privacy: .public) cannot exclude this app: it is not among the shareable apps")
        }
        let pids = Set(exclusions.pids)
        let included = content.windows.filter { includedWindowIDs.contains($0.windowID) }
        if included.count < Set(includedWindowIDs).count {
            let found = Set(included.map(\.windowID))
            Self.logger.error(
                "\(self.trackID, privacy: .public) cannot include windows \(self.includedWindowIDs.filter { !found.contains($0) }, privacy: .public): not among the shareable windows")
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: content.applications.filter { pids.contains($0.processID) },
            exceptingWindows: included)
        return (filter, exclusions.missingBundleIDs)
    }

    /// From the first `start` until `stop`: an app of `excludedBundleIDs` that launches gets the filter made again.
    /// `runningApplications` changes (on the main thread) for every app; `didLaunchApplicationNotification` is not
    /// posted for an app without a Dock icon, Notification Center among them.
    private func observeLaunches() {
        launches.withLock { watch in
            guard watch == nil else { return }
            let workspace = NSWorkspace.shared
            let notification = workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let self, let bundleID = app?.bundleIdentifier, excludedBundleIDs.contains(bundleID) else { return }
                Task { await self.refreshFilter(excluding: bundleID) }
            }
            let runningApplications = workspace.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
                guard let self else { return }
                let apps = { (apps: [NSRunningApplication]?) in
                    (apps ?? []).map { (pid: $0.processIdentifier, bundleID: $0.bundleIdentifier) }
                }
                let launched = DisplayExclusions.launched(
                    before: apps(change.oldValue), after: apps(change.newValue), bundleIDs: excludedBundleIDs)
                for bundleID in launched {
                    Task { await self.refreshFilter(excluding: bundleID) }
                }
            }
            watch = LaunchWatch(notification: notification, runningApplications: runningApplications)
        }
    }

    /// Gives the running stream a filter that leaves out the app `bundleID` (just launched, or missing when the stream
    /// started), looking for it again a second later while it is not among the shareable apps. Without a running
    /// stream, nothing: its next start makes its filter, and looks again for what that one misses.
    private func refreshFilter(excluding bundleID: String) async {
        for attempt in 1...Self.relaunchAttempts {
            if attempt > 1 { try? await Task.sleep(for: .seconds(1)) }
            Self.logger.notice(
                "\(self.trackID, privacy: .public) makes its filter again to exclude \(bundleID, privacy: .public) (attempt \(attempt))")
            let made: (filter: SCContentFilter, missingBundleIDs: [String])
            do {
                made = try await makeFilter()
            } catch {
                Self.logger.error("\(self.trackID, privacy: .public) could not make its filter again: \(error, privacy: .public)")
                return
            }
            do {
                guard try await capture.updateContentFilter(made.filter) else { return }
            } catch {
                Self.logger.error("\(self.trackID, privacy: .public) could not update its filter: \(error, privacy: .public)")
                return
            }
            if !made.missingBundleIDs.contains(bundleID) {
                Self.logger.notice("\(self.trackID, privacy: .public) excludes \(bundleID, privacy: .public) again")
                return
            }
        }
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

    /// `contentRect` × `pointPixelScale` pixels at `.native`, `contentRect`'s points at `.points`; no cursor,
    /// BGRA in sRGB, at most `framesPerSecond`, no audio.
    public static func makeConfiguration(
        contentRect: CGRect, pointPixelScale: Double, framesPerSecond: Int, scale: CaptureScale = .native
    ) -> SCStreamConfiguration {
        let pixelsPerPoint = switch scale {
        case .native: pointPixelScale
        case .points: 1.0
        }
        return ScreenStreamCapture.configuration(
            width: Int((Double(contentRect.width) * pixelsPerPoint).rounded()),
            height: Int((Double(contentRect.height) * pixelsPerPoint).rounded()),
            framesPerSecond: framesPerSecond)
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
