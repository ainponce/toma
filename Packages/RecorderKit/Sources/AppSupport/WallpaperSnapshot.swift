// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import ProjectFormat
import Recording
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A window on the screen as ScreenCaptureKit lists it: what the wallpaper's capture keeps or leaves out.
public struct DesktopWindowInfo: Equatable, Sendable {
    /// Its `CGWindowID`.
    public var windowID: UInt32
    /// Its window level (`SCWindow.windowLayer`).
    public var layer: Int

    public init(windowID: UInt32, layer: Int) {
        self.windowID = windowID
        self.layer = layer
    }
}

/// Why the wallpaper could not be captured or saved.
public enum WallpaperSnapshotError: Error, Equatable {
    /// Screen Recording is not granted: asking ScreenCaptureKit would show the system's prompt.
    case noScreenRecordingAccess
    /// The display is not among the shareable displays (disconnected or asleep).
    case displayNotFound(displayID: UInt32)
    /// No window on the screen is at or below the desktop's level: there is no wallpaper to capture.
    case noDesktopPicture(displayID: UInt32)
    /// ImageIO could not make a PNG of the image.
    case encodingFailed
}

/// The wallpaper of a display as it is seen on the current desktop (dynamic, tiled or that desktop's own), with
/// nothing over it: the desktop covers draw it, and each take keeps one per display it records, taken as it starts
/// (spec §13, "Blur del escritorio original"), in `takes/<take>/wallpapers/`.
public enum WallpaperSnapshot {
    /// How long a capture of the wallpaper may take (`capture` under `withTimeLimit`); it takes a fraction of a second.
    /// ScreenCaptureKit that does not answer must never keep a take from stopping, nor a countdown from starting.
    public static let captureTimeLimit = Duration.seconds(3)

    /// `takes/<take>/wallpapers/display-<displayID>.png`.
    public static func url(in package: ProjectPackage, take: String, displayID: UInt32) -> URL {
        package.wallpapersDirectory(take: take).appendingPathComponent("display-\(displayID).png", isDirectory: false)
    }

    /// Writes `png` at `url` (`self.url`), never over one there (`DurableFile.writeNew`, `POSIXError(.EEXIST)`).
    /// Makes the `wallpapers/` folder if the take has none, never the take's folder: a `wallpapers` that is not a
    /// folder (a symlink, which is never followed) throws `POSIXError(.ENOTDIR)`.
    public static func write(_ png: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try DurableFile.syncDirectory(folder.deletingLastPathComponent())
        } catch CocoaError.fileWriteFileExists {
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        }
        try DurableFile.writeNew(png, to: url)
    }

    /// Takes and saves the wallpaper of each of `displayIDs` for `take` of `package`, one display after the other, each
    /// `capture` given `timeLimit`. A display whose capture fails or takes longer, or whose picture cannot be saved (on a
    /// volume without `RENAME_EXCL`, as exFAT or SMB, `writeNew` gives `ENOTSUP`), is left without one and its error is
    /// returned; the others are saved all the same. Off the main thread: the files are synced to the drive.
    @concurrent
    public static func save(
        displayIDs: [UInt32], in package: ProjectPackage, take: String, timeLimit: Duration = captureTimeLimit,
        capture: @escaping @Sendable (UInt32) async throws -> CGImage = { try await WallpaperSnapshot.capture(displayID: $0) }
    ) async -> [UInt32: any Error] {
        var failures: [UInt32: any Error] = [:]
        for displayID in displayIDs {
            do {
                let image = try await withTimeLimit(timeLimit) { try await capture(displayID) }
                try write(pngData(image), to: url(in: package, take: take, displayID: displayID))
            } catch {
                failures[displayID] = error
            }
        }
        return failures
    }

    /// `image` as a PNG.
    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw WallpaperSnapshotError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WallpaperSnapshotError.encodingFailed }
        return data as Data
    }

    /// What the wallpaper's capture keeps, in the order given: the windows at or below the desktop's level
    /// (`desktopLevel`), where the wallpaper is. Everything above it is left out: the desktop's icons and widgets,
    /// the covers over them, the Dock, the menu bar and every app's windows, also one that appears after the windows
    /// were listed (a notification, a palette that shows again): the capture only has the windows it names.
    public static func desktopPictureWindowIDs(
        _ windows: [DesktopWindowInfo], desktopLevel: Int = Int(CGWindowLevelForKey(.desktopWindow))
    ) -> [UInt32] {
        windows.filter { $0.layer <= desktopLevel }.map(\.windowID)
    }

    /// The displays of `displays` whose wallpaper a take of `selection` keeps, in track order: the ones it records in
    /// Display mode, the area's in Area mode, and in Window mode the one with most of the window's frame now
    /// (`windowFrame`, global points); none when the window is on none of them, nor for an iPhone or iPad (nothing of
    /// the Mac's screen is recorded).
    public static func displayIDs(recording selection: CaptureSelection, displays: [DisplayInfo], windowFrame: Rect?) -> [UInt32] {
        let connected = Set(displays.map(\.id))
        switch selection.mode {
        case .display:
            return selection.displayIDs.filter(connected.contains)
        case .area:
            return selection.area.map { [$0.displayID] }?.filter(connected.contains) ?? []
        case .window:
            guard let windowFrame else { return [] }
            let window = CGRect(windowFrame)
            let overlaps = displays.map { display -> (id: UInt32, area: Double) in
                let shared = CGRect(display.frame).intersection(window)
                return (display.id, shared.isNull ? 0 : Double(shared.width * shared.height))
            }
            guard let most = overlaps.max(by: { $0.area < $1.area }), most.area > 0 else { return [] }
            return [most.id]
        case .device:
            return []
        }
    }

    /// Captures the wallpaper of `displayID` at the display's own pixels, as the take records it (BGRA in sRGB, no
    /// cursor: `DisplayCaptureSource.makeConfiguration`): `SCScreenshotManager` with only the on-screen windows at or
    /// below the desktop's level (`desktopPictureWindowIDs`), so a window that appears meanwhile is never in it.
    /// Throws without Screen Recording, never asking for it, and when no window is at the desktop's level
    /// (`noDesktopPicture`). It has no time limit of its own: `save` and the covers give it `captureTimeLimit`.
    public static func capture(displayID: UInt32) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw WallpaperSnapshotError.noScreenRecordingAccess }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw WallpaperSnapshotError.displayNotFound(displayID: displayID)
        }
        let kept = Set(
            desktopPictureWindowIDs(content.windows.map { DesktopWindowInfo(windowID: $0.windowID, layer: $0.windowLayer) }))
        let windows = content.windows.filter { kept.contains($0.windowID) }
        guard !windows.isEmpty else { throw WallpaperSnapshotError.noDesktopPicture(displayID: displayID) }
        let filter = SCContentFilter(display: display, including: windows)
        let configuration = DisplayCaptureSource.makeConfiguration(
            contentRect: filter.contentRect, pointPixelScale: Double(filter.pointPixelScale), framesPerSecond: 1)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

extension CGRect {
    fileprivate init(_ rect: Rect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
