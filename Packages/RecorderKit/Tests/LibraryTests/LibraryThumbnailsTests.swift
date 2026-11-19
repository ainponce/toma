// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Darwin
import Editing
import Foundation
import ImageIO
import ProjectFormat
import RecorderKitTestSupport
import Render
import Synchronization
import Testing
// @testable for `renders` (how many frames were drawn rather than read from the cache), `waiting(for:)`, `setHooks(_:)`
// and `size(for:)`.
@testable import Library

/// What the tests of this file share.
private enum Thumbs {
    static let app = AppInfo(name: "Toma", version: "0.3.0")
    static let now = Date(timeIntervalSince1970: 1_794_800_000)
    static let frame = Rect(x: 0, y: 0, width: 640, height: 360)

    static func context(_ dir: URL) -> EditContext {
        EditContext(
            app: app, cachesRoot: dir.appending(path: "Caches", directoryHint: .isDirectory), defaultStyle: .toma,
            now: { now }, makeID: { $0 + "00000001" })
    }

    static func summary(_ url: URL, in dir: URL, place: Place = .projectsFolder(subfolder: "")) -> ProjectSummary {
        ProjectReader.summary(of: url, place: place, fileSystem: SystemFileSystem(), context: context(dir), now: now)
    }

    /// `LibraryThumbnails.key(of:cachesRoot:)` of the package at `url`, with the caches of `context(dir)`.
    static func key(_ url: URL, in dir: URL) throws -> String {
        try LibraryThumbnails.key(of: url, cachesRoot: context(dir).cachesRoot)
    }

    /// The folder the thumbnails of a test go to.
    static func cache(_ dir: URL) -> URL {
        dir.appending(path: "thumbnails", directoryHint: .isDirectory)
    }

    /// The names of the files in `folder`, sorted; none if it is not there.
    static func files(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// A project of one display recorded for `seconds` at 10 fps, `width` × `height`, without edits: its document is a
    /// new one, of Toma's style.
    static func display(
        in dir: URL, name: String, seconds: Double, width: Int = 640, height: Int = 360, framesPerSecond: Int = 10
    ) async throws -> URL {
        let builder = try TakeBuilder(in: dir, name: name)
        let base = HostTime(nanoseconds: 5_000_000_000_000)
        let frame = Rect(x: 0, y: 0, width: Double(width), height: Double(height))
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [
                VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: framesPerSecond, width: width, height: height)
            ])
        try builder.addEvents([
            InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))
        ])
        return try builder.write().package.url
    }

    /// The camera's frame of `cameraTake`: the person over a checkerboard (`CameraPictureFixtures.person`).
    static let personFrame = CameraPictureFixtures.bytes(width: 640, height: 360) {
        CameraPictureFixtures.person($0, $1, width: 640, height: 360)
    }

    /// A project of a display (`display`'s) and a camera of the person (`personFrame`) in two segments of `seconds / 2`,
    /// at 10 fps, whose document draws its camera with `background` (and `framing`), written in its edit log: the
    /// package's URL, the project and its document as `EditSession` reads them, and the caches of `context(dir)`.
    static func cameraTake(
        in dir: URL, name: String, seconds: Double = 2, background: CameraBackground,
        framing: CameraFramingMode = .center
    ) async throws -> (url: URL, project: LoadedProject, document: EditDocument, caches: ProjectCaches) {
        let builder = try TakeBuilder(in: dir, name: name)
        let base = HostTime(nanoseconds: 5_000_000_000_000)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 10, width: 640, height: 360)])
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera"),
            segments: [0, seconds / 2].map { from in
                VideoSegmentSpec(
                    start: base.adding(seconds: from), seconds: seconds / 2, framesPerSecond: 10, width: 640, height: 360,
                    transform: { _, sample in CameraPictureFixtures.copying(sample, bytes: personFrame) })
            })
        try builder.addEvents([
            InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))
        ])
        let project = try builder.write()
        var document = EditDocument.legacy(for: project)
        document.logSequence = 1
        document.camera.background = background
        document.camera.framing.mode = framing
        let line = try EditLogEntry.create(seq: 1, document: document, app: app).jsonLine()
        try DurableFile.writeAtomically(Data((line + "\n").utf8), to: project.package.editLogURL)
        let url = project.package.url
        let (read, shown) = try EditSession.readDocument(url, take: nil, context: context(dir))
        #expect(shown.camera.show && shown.camera.background == background && shown.camera.framing.mode == framing)
        return (url, read, shown, ProjectCaches(root: context(dir).cachesRoot, projectID: read.manifest.resolvedProjectID))
    }

    /// The camera's segments of `project`, in order.
    static func cameraSegments(_ project: LoadedProject) throws -> [SegmentRecord] {
        try #require(project.take.track("camera")).segments.sorted { $0.index < $1.index }
    }

    /// The mask's cache file of camera segment `segment` of `project` in `caches`.
    static func maskFile(_ segment: SegmentRecord, of project: LoadedProject, in caches: ProjectCaches) throws -> URL {
        let identity = try #require(SegmentIdentity.of(segment, in: project.package))
        return try #require(CameraAnalysisCaches.maskFile(take: project.take.id, track: "camera", identity: identity, caches: caches))
    }

    /// The frame at `seconds` of the project at `url` as the export draws it, `size` big, as BGRA bytes: its document as
    /// `EditSession` reads it, drawn by a `FrameRenderer` on a thread of its own.
    static func exportFrame(_ url: URL, at seconds: Double, size: SIMD2<Int>, in dir: URL) async throws -> [UInt8] {
        let (project, document) = try EditSession.readDocument(url, take: nil, context: context(dir))
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        return try await offThePool { try renderer.renderBytes(at: seconds) }
    }

    /// `image` drawn into BGRA bytes (premultiplied, alpha first, little-endian: the renderer's layout) in Rec. 709, the
    /// space thumbnails are tagged with.
    static func bgra(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.itur_709))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// The image the HEIC at `url` holds, decoded by ImageIO.
    static func decodeHEIC(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.heic")
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The peak signal-to-noise ratio of two BGRA images of the same size over their colour channels, in dB.
    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        precondition(a.count == b.count)
        var total = 0.0, count = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            for channel in 0..<3 {
                let d = Double(Int(a[i + channel]) - Int(b[i + channel]))
                total += d * d
                count += 1
            }
        }
        let mse = total / Double(count)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// Sets the modification date of the file at `url` to `date`.
    static func setModified(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

/// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread: drawing a take
/// decodes, which blocks (`offThePool` in RenderTests).
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

@Suite struct LibraryThumbnailsTests {
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func thumbnailIsTheExportFrameAtTenPercent() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await Thumbs.display(in: dir, name: "Thirty", seconds: 30)
            let summary = Thumbs.summary(url, in: dir)
            #expect(summary.outputSeconds == 30)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })

            let image = try #require(await thumbnails.render(url, summary: summary, context: Thumbs.context(dir)))
            #expect(SIMD2(image.width, image.height) == LibraryThumbnails.pixelSize)
            let atThree = try await Thumbs.exportFrame(url, at: 3, size: LibraryThumbnails.pixelSize, in: dir)
            // The image given is the renderer's frame, byte for byte.
            #expect(try Thumbs.bgra(image) == atThree)

            // The file, named by the key of what the package holds, is that frame in HEIC.
            let package = ProjectPackage(url: url)
            let key = LibraryThumbnails.key(
                manifest: try SafeRead.regularFile(at: package.manifestURL), edit: nil, log: nil,
                size: LibraryThumbnails.pixelSize)
            #expect(Thumbs.files(Thumbs.cache(dir)) == ["\(key).heic"])
            let file = Thumbs.cache(dir).appending(path: "\(key).heic", directoryHint: .notDirectory)
            let decoded = try Thumbs.bgra(try Thumbs.decodeHEIC(file))
            let psnr = Thumbs.psnr(decoded, atThree)
            #expect(psnr >= 40, "PSNR \(psnr) dB")
            // Another instant of the take is another picture.
            let atZero = try await Thumbs.exportFrame(url, at: 0, size: LibraryThumbnails.pixelSize, in: dir)
            #expect(Thumbs.psnr(decoded, atZero) < 30)

            // Read again from the cache, by its key.
            let cached = try #require(await thumbnails.cached(key))
            #expect(SIMD2(cached.width, cached.height) == LibraryThumbnails.pixelSize)
            #expect(Thumbs.psnr(try Thumbs.bgra(cached), atThree) >= 40)
            #expect(await thumbnails.renders == 1)
        }
    }

    @Test func capsAtTwentySeconds() {
        #expect(LibraryThumbnails.time(outputSeconds: 600) == 20)
        #expect(LibraryThumbnails.time(outputSeconds: 200) == 20)
        #expect(LibraryThumbnails.time(outputSeconds: 30) == 3)
        #expect(LibraryThumbnails.time(outputSeconds: 0.5) == 0.05)
        #expect(LibraryThumbnails.time(outputSeconds: 0) == 0)
        #expect(LibraryThumbnails.time(outputSeconds: .nan) == 0)
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func keyChangesWithTheProjectAndIsSharedByAnUnchangedCopy() async throws {
        // Every part of the key counts.
        let manifest = Data("{\"formatVersion\":3}".utf8), edit = Data("{\"documentVersion\":2}".utf8)
        let log = FileSignature(size: 120, modified: 1_794_800_000_123_456_789)
        let size = LibraryThumbnails.pixelSize
        let key = LibraryThumbnails.key(manifest: manifest, edit: edit, log: log, size: size)
        #expect(key.count == 64 && key.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(LibraryThumbnails.key(manifest: manifest, edit: edit, log: log, size: size) == key)
        let others = [
            LibraryThumbnails.key(manifest: Data("{\"formatVersion\":2}".utf8), edit: edit, log: log, size: size),
            LibraryThumbnails.key(manifest: manifest, edit: nil, log: log, size: size),
            LibraryThumbnails.key(manifest: manifest, edit: Data("{\"documentVersion\":1}".utf8), log: log, size: size),
            LibraryThumbnails.key(manifest: manifest, edit: edit, log: nil, size: size),
            LibraryThumbnails.key(manifest: manifest, edit: edit, log: FileSignature(size: 121, modified: log.modified), size: size),
            LibraryThumbnails.key(manifest: manifest, edit: edit, log: FileSignature(size: 120, modified: log.modified + 1), size: size),
            LibraryThumbnails.key(manifest: manifest, edit: edit, log: log, size: SIMD2(260, 146)),
        ]
        #expect(Set(others + [key]).count == others.count + 1)

        try await withTemporaryDirectory { dir in
            let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.v3]).first)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })
            let context = Thumbs.context(dir)
            let first = try #require(await thumbnails.render(url, summary: Thumbs.summary(url, in: dir), context: context))
            #expect(await thumbnails.renders == 1)
            let original = try Thumbs.key(url, in: dir)
            #expect(Thumbs.files(Thumbs.cache(dir)) == ["\(original).heic"])

            // A copy that did not change, as the library duplicates (a clone, with the files' dates), shares it.
            let copy = dir.appending(path: "copy.toma", directoryHint: .isDirectory)
            #expect(clonefile(url.path, copy.path, 0) == 0)
            #expect(try Thumbs.key(copy, in: dir) == original)
            let shared = try #require(await thumbnails.render(copy, summary: Thumbs.summary(copy, in: dir), context: context))
            #expect(await thumbnails.renders == 1)
            #expect(try Thumbs.bgra(shared) == Thumbs.bgra(try #require(await thumbnails.cached(original))))
            #expect(SIMD2(shared.width, shared.height) == SIMD2(first.width, first.height))

            // An edit (the log written again, keeping the first quarter second) is another thumbnail.
            let package = ProjectPackage(url: copy)
            let (_, before) = try EditSession.readDocument(copy, take: nil, context: context)
            var document = before
            document.logSequence = 1
            document.sequence[0].end = document.sequence[0].start.adding(seconds: 0.25)
            let line = try EditLogEntry.create(seq: 1, document: document, app: Thumbs.app).jsonLine()
            try DurableFile.writeAtomically(Data((line + "\n").utf8), to: package.editLogURL)
            let edited = try Thumbs.key(copy, in: dir)
            #expect(edited != original)
            _ = try #require(await thumbnails.render(copy, summary: Thumbs.summary(copy, in: dir), context: context))
            #expect(await thumbnails.renders == 2)
            #expect(Thumbs.files(Thumbs.cache(dir)) == ["\(edited).heic", "\(original).heic"].sorted())
        }
    }

    @Test func anExtremeAutoRatioFitsTheCard() {
        // A crafted window of 10¹⁷ × 1 points: held to 4:1, inside the card (no size that overflows).
        #expect(LibraryThumbnails.size(for: .auto, contentRatio: 1e17) == SIMD2(520, 130))
        #expect(LibraryThumbnails.size(for: .auto, contentRatio: 1e-17) == SIMD2(73, 292))
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func portraitFitsInsideTheCard() async throws {
        #expect(LibraryThumbnails.size(for: .landscape) == SIMD2(520, 292))
        #expect(LibraryThumbnails.size(for: .portrait) == SIMD2(164, 292))
        #expect(LibraryThumbnails.size(for: .square) == SIMD2(292, 292))
        #expect(LibraryThumbnails.size(for: .auto, contentRatio: 2.4) == SIMD2(520, 217))
        #expect(LibraryThumbnails.size(for: .auto) == SIMD2(520, 292))
        #expect(LibraryThumbnails.size(for: .fourByFive) == SIMD2(234, 292))
        try await withTemporaryDirectory { dir in
            // In 9:16, half a second long: its thumbnail is of 0.05 s.
            let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.v3]).first)
            let summary = Thumbs.summary(url, in: dir)
            #expect(summary.aspect == .portrait)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })
            let image = try #require(await thumbnails.render(url, summary: summary, context: Thumbs.context(dir)))
            #expect(SIMD2(image.width, image.height) == SIMD2(164, 292))
            let expected = try await Thumbs.exportFrame(url, at: 0.05, size: SIMD2(164, 292), in: dir)
            #expect(try Thumbs.bgra(image) == expected)
            let file = Thumbs.cache(dir).appending(path: "\(try Thumbs.key(url, in: dir)).heic", directoryHint: .notDirectory)
            let decoded = try Thumbs.decodeHEIC(file)
            #expect(SIMD2(decoded.width, decoded.height) == SIMD2(164, 292))
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func cacheEvictsTheLeastUsed() async throws {
        try await withTemporaryDirectory { dir in
            // Three projects that look the same, so their thumbnails are about as big, with keys of their own.
            let urls = try await LibraryFixtures.folder(in: dir, kinds: [.v3, .v3, .v3])
            let keys = try urls.map { try Thumbs.key($0, in: dir) }
            #expect(Set(keys).count == 3)
            let cache = Thumbs.cache(dir), context = Thumbs.context(dir)
            func file(_ index: Int) -> URL { cache.appending(path: "\(keys[index]).heic", directoryHint: .notDirectory) }

            let roomy = LibraryThumbnails(directory: cache, isRecording: { false })
            for url in urls.prefix(2) {
                _ = try #require(await roomy.render(url, summary: Thumbs.summary(url, in: dir), context: context))
            }
            // The first was drawn first and used longer ago than the second…
            try Thumbs.setModified(file(0), to: Thumbs.now.addingTimeInterval(-20))
            try Thumbs.setModified(file(1), to: Thumbs.now.addingTimeInterval(-10))
            let size = try #require(try FileManager.default.attributesOfItem(atPath: file(0).path)[.size] as? Int)

            // …until it is shown again: now the second is the least used.
            let small = LibraryThumbnails(directory: cache, maxBytes: Int64(size) * 5 / 2, isRecording: { false })
            _ = try #require(await small.cached(keys[0]))
            #expect(Thumbs.files(cache) == ["\(keys[0]).heic", "\(keys[1]).heic"].sorted())

            // A third does not fit with both: the least used goes (once the thumbnail is handed back).
            _ = try #require(await small.render(urls[2], summary: Thumbs.summary(urls[2], in: dir), context: context))
            let kept = ["\(keys[0]).heic", "\(keys[2]).heic"].sorted()
            #expect(await eventually { Thumbs.files(cache) == kept })
            #expect(await small.cached(keys[1]) == nil)
            #expect(await small.cached(keys[0]) != nil)
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func noThumbnailsWhileRecording() async throws {
        try await withTemporaryDirectory { dir in
            let urls = try await LibraryFixtures.folder(in: dir, kinds: [.v3, .v3, .needsRepair, .unfinished])
            let recording = Mutex(true)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { recording.withLock { $0 } })
            let context = Thumbs.context(dir)
            let drawn = Thumbs.summary(urls[0], in: dir), notDrawn = Thumbs.summary(urls[1], in: dir)

            #expect(await thumbnails.render(urls[1], summary: notDrawn, context: context) == nil)
            #expect(await thumbnails.renders == 0)
            #expect(Thumbs.files(Thumbs.cache(dir)).isEmpty)

            // Nor of a project that cannot be opened, or is not there.
            recording.withLock { $0 = false }
            #expect(Thumbs.summary(urls[2], in: dir).state != .normal)
            #expect(Thumbs.summary(urls[3], in: dir).state == .unfinished)
            for url in urls.suffix(2) {
                #expect(await thumbnails.render(url, summary: Thumbs.summary(url, in: dir), context: context) == nil)
            }
            var gone = notDrawn
            gone.state = .unavailable(.notFound)
            #expect(await thumbnails.render(urls[1], summary: gone, context: context) == nil)
            var newer = notDrawn
            newer.state = .newerVersion
            #expect(await thumbnails.render(urls[1], summary: newer, context: context) == nil)
            #expect(await thumbnails.renders == 0)
            #expect(Thumbs.files(Thumbs.cache(dir)).isEmpty)

            // One drawn before a take…
            let before = try #require(await thumbnails.render(urls[0], summary: drawn, context: context))
            #expect(await thumbnails.renders == 1)

            // …is still shown while it records, by its key (the index's) or by the project, a light read; only drawing
            // waits.
            recording.withLock { $0 = true }
            let key = try Thumbs.key(urls[0], in: dir)
            #expect(Thumbs.files(Thumbs.cache(dir)) == ["\(key).heic"])
            let byKey = try #require(await thumbnails.cached(key))
            let byProject = try #require(await thumbnails.render(urls[0], summary: drawn, context: context))
            #expect(try Thumbs.bgra(byKey) == Thumbs.bgra(byProject))
            #expect(Thumbs.psnr(try Thumbs.bgra(byProject), try Thumbs.bgra(before)) >= 40)
            #expect(await thumbnails.render(urls[1], summary: notDrawn, context: context) == nil)
            #expect(await thumbnails.renders == 1)
            #expect(Thumbs.files(Thumbs.cache(dir)) == ["\(key).heic"])

            // Once the take ends, the other is drawn.
            recording.withLock { $0 = false }
            #expect(await thumbnails.render(urls[1], summary: notDrawn, context: context) != nil)
            #expect(await thumbnails.renders == 2)
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aTakeThatStartsWhileDrawingWritesNothing() async throws {
        try await withTemporaryDirectory { dir in
            let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.v3]).first)
            let recording = Mutex(false)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { recording.withLock { $0 } })
            await thumbnails.setHooks(.init(afterDrawing: { recording.withLock { $0 = true } }))
            // The frame drawn is handed back; nothing is encoded or written while the take records.
            #expect(await thumbnails.render(url, summary: Thumbs.summary(url, in: dir), context: Thumbs.context(dir)) != nil)
            #expect(await thumbnails.renders == 1)
            #expect(Thumbs.files(Thumbs.cache(dir)).isEmpty)
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aCardCancelledBeforeItsFrameIsDrawnDrawsAndWritesNothing() async throws {
        try await withTemporaryDirectory { dir in
            let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.v3]).first)
            let key = try Thumbs.key(url, in: dir)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })
            let gate = DispatchSemaphore(value: 0)
            await thumbnails.setHooks(.init(beforeDrawing: { _ = gate.wait(timeout: .now() + 10) }))
            let summary = Thumbs.summary(url, in: dir), context = Thumbs.context(dir)

            let card = Task { await thumbnails.render(url, summary: summary, context: context) }
            #expect(await eventually { await thumbnails.waiting(for: key) == 1 })
            // The card scrolls away while its draw waits for its turn.
            card.cancel()
            #expect(await eventually { await thumbnails.waiting(for: key) == 0 })
            gate.signal()
            #expect(await card.value == nil)
            #expect(await thumbnails.renders == 0)
            #expect(Thumbs.files(Thumbs.cache(dir)).isEmpty)

            // Asked for again, it is drawn.
            await thumbnails.setHooks(.init())
            #expect(await thumbnails.render(url, summary: summary, context: context) != nil)
            #expect(await thumbnails.renders == 1)
            #expect(Thumbs.files(Thumbs.cache(dir)) == ["\(key).heic"])
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func theSameKeyAskedForTwiceAtOnceIsDrawnOnce() async throws {
        try await withTemporaryDirectory { dir in
            // A project and its unchanged copy, both on screen.
            let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.v3]).first)
            let copy = dir.appending(path: "copy.toma", directoryHint: .isDirectory)
            #expect(clonefile(url.path, copy.path, 0) == 0)
            let key = try Thumbs.key(url, in: dir)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })
            let gate = DispatchSemaphore(value: 0)
            await thumbnails.setHooks(.init(beforeDrawing: { _ = gate.wait(timeout: .now() + 10) }))
            let context = Thumbs.context(dir)
            let original = Thumbs.summary(url, in: dir), copied = Thumbs.summary(copy, in: dir)

            async let first = thumbnails.render(url, summary: original, context: context)
            async let second = thumbnails.render(copy, summary: copied, context: context)
            #expect(await eventually { await thumbnails.waiting(for: key) == 2 })
            gate.signal()
            let images = await [first, second]
            #expect(images.allSatisfy { $0 != nil })
            #expect(await thumbnails.renders == 1)
            #expect(Thumbs.files(Thumbs.cache(dir)) == ["\(key).heic"])
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func twoProjectsAreDrawnAtOnce() async throws {
        try await withTemporaryDirectory { dir in
            let urls = try await LibraryFixtures.folder(in: dir, kinds: [.v3, .from1b])
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })
            let context = Thumbs.context(dir)
            let summaries = urls.map { Thumbs.summary($0, in: dir) }
            async let first = thumbnails.render(urls[0], summary: summaries[0], context: context)
            async let second = thumbnails.render(urls[1], summary: summaries[1], context: context)
            let images = await [first, second]
            #expect(images.allSatisfy { $0 != nil })
            #expect(await thumbnails.renders == 2)
            let keys = try urls.map { "\(try Thumbs.key($0, in: dir)).heic" }
            #expect(Thumbs.files(Thumbs.cache(dir)) == keys.sorted())
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func untouchedProjectsOfBeforeAreTheirLegacyFrame() async throws {
        try await withTemporaryDirectory { dir in
            // Packages of format 1 and 2 without edits: what phase 0 and 1a draw, `FrameRenderer(project:outputSize:)`.
            let urls = try await LibraryFixtures.folder(in: dir, kinds: [.v1, .v2])
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })
            for url in urls {
                let summary = Thumbs.summary(url, in: dir)
                let image = try #require(await thumbnails.render(url, summary: summary, context: Thumbs.context(dir)))
                let project = try LoadedProject.load(url)
                let size = LibraryThumbnails.size(for: EditDocument.legacy(for: project).aspect)
                let renderer = try FrameRenderer(project: project, outputSize: size)
                let seconds = LibraryThumbnails.time(outputSeconds: renderer.duration)
                let expected = try await offThePool { try renderer.renderBytes(at: seconds) }
                #expect(SIMD2(image.width, image.height) == size)
                #expect(try Thumbs.bgra(image) == expected, "\(url.lastPathComponent)")
            }
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func leftoverTemporaryFilesGoWhenOld() async throws {
        try await withTemporaryDirectory { dir in
            let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.v3]).first)
            let cache = Thumbs.cache(dir)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            // What a crash between the write and the rename leaves: one an hour ago, one being written now.
            let old = ".\(String(repeating: "a", count: 64)).heic.\(UUID().uuidString).tmp"
            let fresh = ".\(String(repeating: "b", count: 64)).heic.\(UUID().uuidString).tmp"
            for name in [old, fresh] {
                try Data(repeating: 7, count: 100).write(to: cache.appending(path: name, directoryHint: .notDirectory))
            }
            try Thumbs.setModified(cache.appending(path: old, directoryHint: .notDirectory), to: Date().addingTimeInterval(-3600))
            let thumbnails = LibraryThumbnails(directory: cache, isRecording: { false })
            _ = try #require(await thumbnails.render(url, summary: Thumbs.summary(url, in: dir), context: Thumbs.context(dir)))
            let left = [fresh, "\(try Thumbs.key(url, in: dir)).heic"].sorted()
            #expect(await eventually { Thumbs.files(cache) == left })
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func theCacheIsReadOffThePool() async throws {
        try await withTemporaryDirectory { dir in
            let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.v3]).first)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })
            let summary = Thumbs.summary(url, in: dir), context = Thumbs.context(dir)
            _ = try #require(await thumbnails.render(url, summary: summary, context: context))
            // Where each read of the cache (and its HEIC's decoding) runs: the actor's dispatch queue.
            let queues = Mutex<[String]>([])
            await thumbnails.setHooks(.init(beforeReading: {
                let label = String(cString: __dispatch_queue_get_label(nil))
                queues.withLock { $0.append(label) }
            }))
            #expect(await thumbnails.cached(try Thumbs.key(url, in: dir)) != nil)
            #expect(await thumbnails.render(url, summary: summary, context: context) != nil)
            #expect(queues.withLock { $0 } == ["dev.toma.Toma.LibraryThumbnails", "dev.toma.Toma.LibraryThumbnails"])
            #expect(await thumbnails.renders == 1)
            // A key that is not one reads nothing.
            #expect(await thumbnails.cached("../../etc/passwd") == nil)
        }
    }

    @Test func onlyLocalProjectsOfTheProjectsFolderAreDrawnByThemselves() {
        let local = VolumeInfo(
            uuid: "8C2F6A1E-0B3D-4E0F-9A51-0C1D2E3F4A5B", name: "Macintosh HD", isInternal: true, isRemovable: false,
            isNetwork: false, isSynced: false, mountPath: "/System/Volumes/Data")
        var removable = local
        removable.isInternal = false
        removable.isRemovable = true
        var network = local
        network.isInternal = false
        network.isNetwork = true
        var synced = local
        synced.isSynced = true
        var readOnly = local
        readOnly.isReadOnly = true

        for place in [Place.projectsFolder(subfolder: ""), .projectsFolder(subfolder: "Clientes/Acme"), .trash] {
            #expect(LibraryThumbnails.mayDraw(place: place, volume: local))
            #expect(LibraryThumbnails.mayDraw(place: place, volume: readOnly))
            for volume in [removable, network, synced] {
                #expect(!LibraryThumbnails.mayDraw(place: place, volume: volume))
            }
        }
        #expect(!LibraryThumbnails.mayDraw(place: .elsewhere, volume: local))
        // When the user opens it: anywhere but where reading its media could make the system download it.
        for place in [Place.projectsFolder(subfolder: ""), .trash, .elsewhere] {
            #expect(LibraryThumbnails.mayDraw(place: place, volume: local, opened: true))
            #expect(LibraryThumbnails.mayDraw(place: place, volume: removable, opened: true))
            #expect(!LibraryThumbnails.mayDraw(place: place, volume: network, opened: true))
            #expect(!LibraryThumbnails.mayDraw(place: place, volume: synced, opened: true))
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func neverWritesInThePackage() async throws {
        try await withTemporaryDirectory { dir in
            // A project of 1b (its document of version 1, which must stay so), one edited in 1c, one without edits.
            let projects = dir.appending(path: "Projects", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
            let urls = try await LibraryFixtures.folder(in: projects, kinds: [.from1b, .v3, .v1])
            let before = try treeHash(projects)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })
            for url in urls {
                let summary = Thumbs.summary(url, in: dir)
                _ = try #require(await thumbnails.render(url, summary: summary, context: Thumbs.context(dir)))
            }
            #expect(await thumbnails.renders == 3)
            #expect(try treeHash(projects) == before)
            #expect(Thumbs.files(Thumbs.cache(dir)).count == 3)
        }
    }

    /// Task 31b: the library reads an edited project without its event log, but its thumbnail draws the cursor and the
    /// clicks from it. One that cannot be read (here `EACCES`, as a disk that fails, `EIO`, would) gives no thumbnail
    /// and keeps none, never one without them under the project's key; once it reads, the thumbnail is drawn.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func unreadableEventLogIsNoThumbnail() async throws {
        try await withTemporaryDirectory { dir in
            let url = try #require(try await LibraryFixtures.folder(in: dir, kinds: [.v3]).first)
            let events = ProjectPackage(url: url).eventsURL(take: LibraryFixtures.take)
            #expect(chmod(events.path, 0) == 0)
            defer { chmod(events.path, 0o644) }
            let summary = Thumbs.summary(url, in: dir)
            #expect(summary.state == .normal)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })
            #expect(await thumbnails.render(url, summary: summary, context: Thumbs.context(dir)) == nil)
            #expect(await thumbnails.renders == 0)
            #expect(Thumbs.files(Thumbs.cache(dir)).isEmpty)

            #expect(chmod(events.path, 0o644) == 0)
            _ = try #require(await thumbnails.render(url, summary: summary, context: Thumbs.context(dir)))
            #expect(await thumbnails.renders == 1)
            #expect(Thumbs.files(Thumbs.cache(dir)) == ["\(try Thumbs.key(url, in: dir)).heic"])
        }
    }

    /// The camera's analysis in the caches (final review of phase 2): the thumbnail reads the masks and the faces
    /// (`CameraAnalysisCaches.fill`), makes none, and leaves out a Blurred or Removed camera with a segment still
    /// without its mask rather than show the room behind the person. A mask or a face committed is another key; a
    /// temporary not committed is not.
    @Test func thumbnailReadsTheCamerasAnalysisAndNeverShowsTheRoom() async throws {
        try await withTemporaryDirectory { dir in
            for background in [CameraBackground.removed, .blurred] {
                let take = try await Thumbs.cameraTake(in: dir, name: "Camera \(background)", background: background)
                let segments = try Thumbs.cameraSegments(take.project)
                #expect(segments.count == 2)
                let masks = try segments.map { try Thumbs.maskFile($0, of: take.project, in: take.caches) }
                var keys = [try Thumbs.key(take.url, in: dir)]

                var drawn = LibraryThumbnails.drawn(take.project, document: take.document, caches: take.caches)
                #expect(!drawn.document.camera.show && drawn.analysis.personMasks.isEmpty)
                // Half done: one segment without its mask still shows the room.
                #expect(ProjectCaches.writeAnalysis(Data("mask".utf8), to: masks[0]))
                keys.append(try Thumbs.key(take.url, in: dir))
                drawn = LibraryThumbnails.drawn(take.project, document: take.document, caches: take.caches)
                #expect(!drawn.document.camera.show && drawn.analysis.personMasks.count == 1)
                // A temporary of the second mask's job is not a mask, nor another key.
                let temporary = try ProjectCaches.temporaryFile(for: masks[1])
                try Data("half".utf8).write(to: temporary)
                #expect(try Thumbs.key(take.url, in: dir) == keys.last)
                #expect(!LibraryThumbnails.drawn(take.project, document: take.document, caches: take.caches).document.camera.show)
                // Both: the camera, with them, and nothing else of the document changed.
                #expect(try ProjectCaches.commit(temporary, to: masks[1]))
                keys.append(try Thumbs.key(take.url, in: dir))
                drawn = LibraryThumbnails.drawn(take.project, document: take.document, caches: take.caches)
                #expect(drawn.document == take.document)
                #expect(drawn.analysis.personMasks == [
                    CameraSegment(take: take.project.take.id, track: "camera", segment: segments[0].index): masks[0],
                    CameraSegment(take: take.project.take.id, track: "camera", segment: segments[1].index): masks[1],
                ])
                #expect(Set(keys).count == 3)
            }

            // Original reads no mask, and hides nothing; Follow the Face reads the faces.
            let face = try await Thumbs.cameraTake(in: dir, name: "Face", background: .original, framing: .face)
            let segment = try #require(try Thumbs.cameraSegments(face.project).first)
            let identity = try #require(SegmentIdentity.of(segment, in: face.project.package))
            #expect(ProjectCaches.writeAnalysis(Data("mask".utf8), to: try Thumbs.maskFile(segment, of: face.project, in: face.caches)))
            var drawn = LibraryThumbnails.drawn(face.project, document: face.document, caches: face.caches)
            #expect(drawn.document == face.document && drawn.analysis == .none)
            let before = try Thumbs.key(face.url, in: dir)
            let track = CameraFaceTrack(
                algorithm: CameraFaceTrack.id, frameSize: [640, 360],
                samples: [CameraFaceSample(t: segment.startHostTime, face: NormalizedRect(x: 0.6, y: 0.2, width: 0.2, height: 0.3))])
            let file = try #require(CameraAnalysisCaches.faceFile(
                take: face.project.take.id, track: "camera", identity: identity, caches: face.caches))
            #expect(ProjectCaches.writeAnalysis(try ProjectJSON.encoder().encode(track), to: file))
            #expect(try Thumbs.key(face.url, in: dir) != before)
            drawn = LibraryThumbnails.drawn(face.project, document: face.document, caches: face.caches)
            #expect(drawn.document == face.document)
            #expect(drawn.analysis.faceTracks == [CameraSegment(take: face.project.take.id, track: "camera", segment: segment.index): track])
        }
    }

    /// Drawn: a Removed camera without its masks is left out of the thumbnail; with them, the person is drawn as the
    /// export draws it with the caches' analysis, under another key.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func removedCameraIsDrawnWithItsMasksOrNotAtAll() async throws {
        try await withTemporaryDirectory { dir in
            let take = try await Thumbs.cameraTake(in: dir, name: "Removed", background: .removed)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { false })
            let context = Thumbs.context(dir)
            func frame(_ document: EditDocument, _ analysis: AnalysisInputs, size: SIMD2<Int>) async throws -> [UInt8] {
                let renderer = try FrameRenderer(project: take.project, document: document, outputSize: size, analysis: analysis)
                return try await offThePool { try renderer.renderBytes(at: LibraryThumbnails.time(outputSeconds: renderer.duration)) }
            }

            let hidden = try #require(await thumbnails.render(take.url, summary: Thumbs.summary(take.url, in: dir), context: context))
            let size = SIMD2(hidden.width, hidden.height)
            var withoutCamera = take.document
            withoutCamera.camera.show = false
            #expect(try Thumbs.bgra(hidden) == (try await frame(withoutCamera, .none, size: size)))
            #expect(try Thumbs.bgra(hidden) != (try await frame(take.document, .none, size: size)), "the room behind the person")

            var analysis = AnalysisInputs()
            for segment in try Thumbs.cameraSegments(take.project) {
                let url = try Thumbs.maskFile(segment, of: take.project, in: take.caches)
                try await CameraPictureFixtures.writeMask(
                    to: url, scratch: dir.appending(path: "scratch", directoryHint: .isDirectory), start: segment.startHostTime,
                    seconds: try #require(segment.endHostTime).seconds(since: segment.startHostTime), framesPerSecond: 10,
                    width: 320, height: 180) { _, x, y in CameraPictureFixtures.personMask(x, y, width: 320, height: 180) }
                analysis.personMasks[CameraSegment(take: take.project.take.id, track: "camera", segment: segment.index)] = url
            }
            let masked = try #require(await thumbnails.render(take.url, summary: Thumbs.summary(take.url, in: dir), context: context))
            #expect(await thumbnails.renders == 2)
            #expect(try Thumbs.bgra(masked) == (try await frame(take.document, analysis, size: size)))
            #expect(try Thumbs.bgra(masked) != Thumbs.bgra(hidden))
            #expect(Thumbs.files(Thumbs.cache(dir)).count == 2)
        }
    }

    /// A new thumbnail of a take of a 4K screen (a minute at 30 fps: its frame at 6 s), drawn from nothing, ten times, each
    /// in a cache of its own. Run by an agent, with `TOMA_BENCH=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func newThumbnailFromA4KSourceIsFast() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await Thumbs.display(
                in: dir, name: "Screen 4K", seconds: 60, width: 3840, height: 2160, framesPerSecond: 30)
            let summary = Thumbs.summary(url, in: dir)
            let context = Thumbs.context(dir)
            var times: [Double] = []
            // One more first, to warm up.
            for round in 0..<11 {
                let thumbnails = LibraryThumbnails(
                    directory: dir.appending(path: "thumbnails-\(round)", directoryHint: .isDirectory), isRecording: { false })
                let clock = ContinuousClock()
                let start = clock.now
                let image = await thumbnails.render(url, summary: summary, context: context)
                let elapsed = clock.now - start
                #expect(image != nil)
                if round > 0 {
                    times.append(Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15)
                }
            }
            times.sort()
            let median = (times[4] + times[5]) / 2
            print(
                "newThumbnailFromA4KSourceIsFast: median \(median) ms, min \(times.first!) ms, max \(times.last!) ms, "
                    + "3840x2160 source, 10 renders")
            #expect(median <= 80)
        }
    }
}
