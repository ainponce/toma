// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Foundation
import ImageIO
import ProjectFormat
import RecorderKitTestSupport
import Testing
import UniformTypeIdentifiers

@Suite struct WallpaperLayoutTests {
    @Test func wallpaperSnapshotLivesInTheTakeAndNeverOverwrites() throws {
        try withTemporaryDirectory { dir in
            let package = try ProjectPackage.create(in: dir, name: "Recording", app: AppInfo(name: "Toma", version: "1.0"), now: Date())
            let take = TakeRecord(id: "take-001", status: .recording, startedAt: Date(), tracks: [])
            try FileManager.default.createDirectory(at: package.takeDirectory(take.id), withIntermediateDirectories: false)
            // Without the folder (a take of an earlier version, or whose snapshot failed) the layout is fine.
            try package.checkLayout(of: take)

            let url = WallpaperSnapshot.url(in: package, take: take.id, displayID: 1)
            #expect(try package.relativePath(of: url) == "takes/take-001/wallpapers/display-1.png")
            let png = try WallpaperSnapshot.pngData(Self.image(width: 4, height: 2))
            try WallpaperSnapshot.write(png, to: url)
            #expect(try Data(contentsOf: url) == png)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == 4 && decoded.height == 2)
            try package.checkLayout(of: take)

            // Never over the one there; another display's goes in the same folder.
            #expect(throws: POSIXError(.EEXIST)) { try WallpaperSnapshot.write(Data("another".utf8), to: url) }
            #expect(try Data(contentsOf: url) == png)
            try WallpaperSnapshot.write(png, to: WallpaperSnapshot.url(in: package, take: take.id, displayID: 2))
            #expect(try FileManager.default.contentsOfDirectory(atPath: package.wallpapersDirectory(take: take.id).path).sorted()
                == ["display-1.png", "display-2.png"])

            // Never a take folder of its own.
            #expect(throws: (any Error).self) {
                try WallpaperSnapshot.write(png, to: WallpaperSnapshot.url(in: package, take: "take-003", displayID: 1))
            }
            #expect(!FileManager.default.fileExists(atPath: package.takeDirectory("take-003").path))

            // `wallpapers` as a symlink: nothing is written through it, and the package needs repair.
            let outside = dir.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let linked = TakeRecord(id: "take-002", status: .recording, startedAt: Date(), tracks: [])
            try FileManager.default.createDirectory(at: package.takeDirectory(linked.id), withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: package.wallpapersDirectory(take: linked.id), withDestinationURL: outside)
            #expect(throws: POSIXError(.ENOTDIR)) {
                try WallpaperSnapshot.write(png, to: WallpaperSnapshot.url(in: package, take: linked.id, displayID: 1))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
            #expect(throws: PackagePathError.unexpectedEntry("takes/take-002/wallpapers")) { try package.checkLayout(of: linked) }
        }
    }

    @Test func wallpaperCaptureExcludesEverythingAboveTheDesktop() {
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        let windows = [
            DesktopWindowInfo(windowID: 10, layer: desktop),  // the wallpaper
            DesktopWindowInfo(windowID: 11, layer: icons),  // Finder's icons
            DesktopWindowInfo(windowID: 12, layer: icons + 1),  // a cover
            DesktopWindowInfo(windowID: 13, layer: 20),  // the Dock
            DesktopWindowInfo(windowID: 14, layer: 0),  // a window
        ]
        #expect(WallpaperSnapshot.excludedWindowIDs(windows) == [11, 12, 13, 14])
        #expect(WallpaperSnapshot.excludedWindowIDs(windows, desktopLevel: 0) == [13])
    }

    @Test func wallpaperSnapshotsAreOfTheRecordedDisplays() {
        let main = DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isMain: true, maximumFramesPerSecond: 120)
        let side = DisplayInfo(
            id: 2, frame: Rect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1, isMain: false, maximumFramesPerSecond: 60)
        var selection = CaptureSelection(mode: .display, displayIDs: [2, 1, 3], camera: .off, microphone: .off, systemAudio: .off)
        // Display 3 is no longer connected.
        #expect(WallpaperSnapshot.displayIDs(recording: selection, displays: [main, side], windowFrame: nil) == [2, 1])

        selection.mode = .area
        selection.area = AreaChoice(displayID: 2, rect: Rect(x: 1600, y: 100, width: 640, height: 360))
        #expect(WallpaperSnapshot.displayIDs(recording: selection, displays: [main, side], windowFrame: nil) == [2])
        selection.area = AreaChoice(displayID: 3, rect: Rect(x: 0, y: 0, width: 640, height: 360))
        #expect(WallpaperSnapshot.displayIDs(recording: selection, displays: [main, side], windowFrame: nil).isEmpty)

        // The display with most of the window.
        selection.mode = .window
        let straddling = Rect(x: 1312, y: 100, width: 800, height: 600)
        #expect(WallpaperSnapshot.displayIDs(recording: selection, displays: [main, side], windowFrame: straddling) == [2])
        let mostlyOnMain = Rect(x: 1012, y: 100, width: 800, height: 600)
        #expect(WallpaperSnapshot.displayIDs(recording: selection, displays: [main, side], windowFrame: mostlyOnMain) == [1])
        let offScreen = Rect(x: -5000, y: 0, width: 800, height: 600)
        #expect(WallpaperSnapshot.displayIDs(recording: selection, displays: [main, side], windowFrame: offScreen).isEmpty)
        #expect(WallpaperSnapshot.displayIDs(recording: selection, displays: [main, side], windowFrame: nil).isEmpty)
    }

    @Test(arguments: [
        (NSImageScaling.scaleProportionallyUpOrDown, true, CGRect(x: -117, y: 0, width: 1746, height: 982)),
        (.scaleProportionallyUpOrDown, false, CGRect(x: 0, y: 66, width: 1512, height: 850)),
        (.scaleAxesIndependently, true, CGRect(x: 0, y: 0, width: 1512, height: 982)),
        (.scaleNone, false, CGRect(x: -204, y: -49, width: 1920, height: 1080)),
        (.scaleProportionallyDown, false, CGRect(x: 0, y: 66, width: 1512, height: 850)),
    ])
    func wallpaperLayoutMatchesTheDesktopOptions(scaling: NSImageScaling, clipping: Bool, expected: CGRect) {
        let r = WallpaperLayout.imageRect(
            imageSize: CGSize(width: 1920, height: 1080), screenSize: CGSize(width: 1512, height: 982), scaling: scaling,
            allowsClipping: clipping)
        #expect(
            abs(r.minX - expected.minX) < 1 && abs(r.width - expected.width) < 1 && abs(r.minY - expected.minY) < 1
                && abs(r.height - expected.height) < 1)
    }

    @Test func wallpaperLayoutNeverEnlargesWhenOnlyShrinking() {
        let small = WallpaperLayout.imageRect(
            imageSize: CGSize(width: 800, height: 600), screenSize: CGSize(width: 1512, height: 982),
            scaling: .scaleProportionallyDown, allowsClipping: false)
        #expect(small == CGRect(x: 356, y: 191, width: 800, height: 600))
        let empty = WallpaperLayout.imageRect(
            imageSize: .zero, screenSize: CGSize(width: 1512, height: 982), scaling: .scaleProportionallyUpOrDown, allowsClipping: true)
        #expect(empty == CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    /// A `width` × `height` image of one color.
    private static func image(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
