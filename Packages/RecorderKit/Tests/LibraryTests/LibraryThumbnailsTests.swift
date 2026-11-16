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
// @testable for `renders`, how many thumbnails were drawn rather than read from the cache, and `key(of:)` and
// `size(for:)`, which the tests compare with.
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
            let original = try LibraryThumbnails.key(of: url)
            #expect(Thumbs.files(Thumbs.cache(dir)) == ["\(original).heic"])

            // A copy that did not change, as the library duplicates (a clone, with the files' dates), shares it.
            let copy = dir.appending(path: "copy.toma", directoryHint: .isDirectory)
            #expect(clonefile(url.path, copy.path, 0) == 0)
            #expect(try LibraryThumbnails.key(of: copy) == original)
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
            let edited = try LibraryThumbnails.key(of: copy)
            #expect(edited != original)
            _ = try #require(await thumbnails.render(copy, summary: Thumbs.summary(copy, in: dir), context: context))
            #expect(await thumbnails.renders == 2)
            #expect(Thumbs.files(Thumbs.cache(dir)) == ["\(edited).heic", "\(original).heic"].sorted())
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func portraitFitsInsideTheCard() async throws {
        #expect(LibraryThumbnails.size(for: .landscape) == SIMD2(520, 292))
        #expect(LibraryThumbnails.size(for: .portrait) == SIMD2(164, 292))
        #expect(LibraryThumbnails.size(for: .square) == SIMD2(292, 292))
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
            let file = Thumbs.cache(dir).appending(path: "\(try LibraryThumbnails.key(of: url)).heic", directoryHint: .notDirectory)
            let decoded = try Thumbs.decodeHEIC(file)
            #expect(SIMD2(decoded.width, decoded.height) == SIMD2(164, 292))
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func cacheEvictsTheLeastUsed() async throws {
        try await withTemporaryDirectory { dir in
            // Three projects that look the same, so their thumbnails are about as big, with keys of their own.
            let urls = try await LibraryFixtures.folder(in: dir, kinds: [.v3, .v3, .v3])
            let keys = try urls.map { try LibraryThumbnails.key(of: $0) }
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

            // A third does not fit with both: the least used goes.
            _ = try #require(await small.render(urls[2], summary: Thumbs.summary(urls[2], in: dir), context: context))
            #expect(Thumbs.files(cache) == ["\(keys[0]).heic", "\(keys[2]).heic"].sorted())
            #expect(await small.cached(keys[1]) == nil)
            #expect(await small.cached(keys[0]) != nil)
        }
    }

    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func noThumbnailsWhileRecording() async throws {
        try await withTemporaryDirectory { dir in
            let urls = try await LibraryFixtures.folder(in: dir, kinds: [.v3, .needsRepair, .unfinished])
            let recording = Mutex(true)
            let thumbnails = LibraryThumbnails(directory: Thumbs.cache(dir), isRecording: { recording.withLock { $0 } })
            let context = Thumbs.context(dir)
            let summary = Thumbs.summary(urls[0], in: dir)

            #expect(await thumbnails.render(urls[0], summary: summary, context: context) == nil)
            #expect(await thumbnails.renders == 0)
            #expect(Thumbs.files(Thumbs.cache(dir)).isEmpty)

            // Nor of a project that cannot be opened, or is not there.
            recording.withLock { $0 = false }
            #expect(Thumbs.summary(urls[1], in: dir).state != .normal)
            #expect(Thumbs.summary(urls[2], in: dir).state == .unfinished)
            for url in urls.dropFirst() {
                #expect(await thumbnails.render(url, summary: Thumbs.summary(url, in: dir), context: context) == nil)
            }
            var gone = summary
            gone.state = .unavailable(.notFound)
            #expect(await thumbnails.render(urls[0], summary: gone, context: context) == nil)
            var newer = summary
            newer.state = .newerVersion
            #expect(await thumbnails.render(urls[0], summary: newer, context: context) == nil)
            #expect(await thumbnails.renders == 0)
            #expect(Thumbs.files(Thumbs.cache(dir)).isEmpty)

            // Once the take ends, it is drawn.
            #expect(await thumbnails.render(urls[0], summary: summary, context: context) != nil)
            #expect(await thumbnails.renders == 1)
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
