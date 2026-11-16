// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import RecorderKitTestSupport
import Synchronization
import Testing
import UniformTypeIdentifiers
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share.
private enum StoreFixture {
    static let app = AppInfo(name: "Toma", version: "0.2.0")
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static func context(caches: URL, defaultStyle: DefaultStyle, styleDirectory: URL?) -> EditContext {
        let count = Mutex(0)
        return EditContext(
            app: app, cachesRoot: caches, defaultStyle: defaultStyle, now: { Date(timeIntervalSince1970: 1_794_773_523) },
            makeID: { prefix in
                count.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            },
            styleDirectory: styleDirectory)
    }

    /// A take of 1 s of one display, in a new version 3 package `<name>.toma` that was never opened. Written off the
    /// main actor, where the tests' sessions live.
    @concurrent static func package(in dir: URL, name: String) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name, formatVersion: 3)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        return try builder.write()
    }

    /// A 32 × 32 PNG, filled.
    static func png() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TestSupportError.failed("no context") }
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage() else { throw TestSupportError.failed("no image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw TestSupportError.failed("no destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestSupportError.failed("no PNG") }
        return data as Data
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@Test func defaultStyleStoreRoundTripsAndFallsBack() throws {
    #expect(DefaultStyleStore.defaultDirectory.standardizedFileURL.path.hasSuffix("/Library/Application Support/Toma/Style"))
    try withTemporaryDirectory { dir in
        let store = DefaultStyleStore(directory: dir.appending(path: "Style", directoryHint: .isDirectory))
        let file = store.directory.appending(path: "default-style.json")
        // None saved: Toma's.
        #expect(store.load() == .toma)

        var style = DefaultStyle.toma
        style.style.padding = 0.1
        style.style.background = .wallpaper("dune-1")
        style.cursor.scale = 2
        style.zoomAuto.depth = 2.5
        try store.save(style, from: nil)
        #expect(store.load() == style)
        #expect(try Data(contentsOf: file) == ProjectJSON.encoder().encode(style))

        // Damaged: Toma's.
        try Data("{\"style\":".utf8).write(to: file)
        #expect(store.load() == .toma)
        // Reset: Toma's, and nothing left.
        try store.save(style, from: nil)
        try store.reset()
        #expect(store.load() == .toma)
        #expect(!StoreFixture.exists(file))
        try store.reset()

        // An image named anywhere but `assets/`, and one saved without the package it is in: Toma's background.
        var outside = style
        outside.style.background = .image(file: "../../\(String(repeating: "a", count: 32)).png")
        try ProjectJSON.encoder().encode(outside).write(to: file)
        #expect(store.load().style.background == DefaultStyle.toma.style.background)
        #expect(store.load().style.padding == 0.1)
        var image = style
        image.style.background = .image(file: "assets/\(String(repeating: "a", count: 32)).png")
        try store.save(image, from: nil)
        #expect(store.load().style.background == DefaultStyle.toma.style.background)
    }
}

@MainActor @Test func defaultStyleImageTravelsToNewProjects() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        let source = try await StoreFixture.package(in: dir, name: "Source")
        let png = try StoreFixture.png()
        let picked = dir.appending(path: "Background.png")
        try png.write(to: picked)
        let file = try AssetImport.copy(picked, into: source.package)
        let name = String(file.dropFirst("assets/".count))
        var style = DefaultStyle.toma
        style.style.background = .image(file: file)
        style.style.padding = 0.05

        // Saved from the project it is in: copied to `Style/<sha>.png`, named as it was.
        let store = DefaultStyleStore(directory: dir.appending(path: "Style", directoryHint: .isDirectory))
        try store.save(style, from: source.package)
        #expect(try Data(contentsOf: store.directory.appending(path: name)) == png)
        #expect(store.load() == style)

        // A new project starts with it, in its own `assets/` before its document is written.
        let new = try await StoreFixture.package(in: dir, name: "New")
        let session = try await EditSession.open(
            new.package.url, take: nil,
            context: StoreFixture.context(caches: caches, defaultStyle: store.load(), styleDirectory: store.directory))
        #expect(session.access == .editable)
        #expect(session.document.style.background == .image(file: file))
        #expect(session.document.style.padding == 0.05)
        #expect(try Data(contentsOf: new.package.fileURL(file)) == png)
        await session.close()
        guard case let .create(_, created, _)? = try EditLogReader.read(new.package.editLogURL).entries.first else {
            Issue.record("no create")
            return
        }
        #expect(created.style.background == .image(file: file))

        // Without the copy in `Style/`, or without the folder: Toma's background.
        try FileManager.default.removeItem(at: store.directory.appending(path: name))
        for (index, folder) in [store.directory, nil].enumerated() {
            let other = try await StoreFixture.package(in: dir, name: "Other \(index)")
            let session = try await EditSession.open(
                other.package.url, take: nil,
                context: StoreFixture.context(caches: caches, defaultStyle: style, styleDirectory: folder))
            #expect(session.document.style.background == DefaultStyle.toma.style.background)
            #expect(session.document.style.padding == 0.05)
            #expect(!StoreFixture.exists(other.package.assetsURL))
            await session.close()
        }

        // A new project read without being opened is never shown with an image it may not hold, and nothing is written.
        try store.save(style, from: source.package)
        let unopened = try await StoreFixture.package(in: dir, name: "Unopened")
        let (_, read) = try EditSession.readDocument(
            unopened.package.url, take: nil,
            context: StoreFixture.context(caches: caches, defaultStyle: style, styleDirectory: store.directory))
        #expect(read.style.background == DefaultStyle.toma.style.background)
        #expect(!StoreFixture.exists(unopened.package.assetsURL))

        // Another style lets the image go from `Style/`; so does going back to Toma's.
        try store.save(.toma, from: nil)
        #expect(!StoreFixture.exists(store.directory.appending(path: name)))
        try store.save(style, from: source.package)
        try store.reset()
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }
}
