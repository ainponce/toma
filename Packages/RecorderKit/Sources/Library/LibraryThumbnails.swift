// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CryptoKit
import Darwin
import Editing
import Foundation
import ImageIO
import ProjectFormat
import Render
import Synchronization

/// The library's thumbnails (design §6.8, plan decision 26, `thumb-1`): each project as it is exported (style, layout,
/// camera) at output instant `time(outputSeconds:)`, drawn by the export's `FrameRenderer` from its document as
/// `EditSession.readDocument` reads it, at the size of its aspect inside `pixelSize`, and kept as HEIC in `directory`
/// as `<key>.heic`. The key comes from what the package holds (`key(of:)`, `key(manifest:edit:log:size:)`): a change to
/// the project gives another thumbnail, and a copy that did not change shares its original's. A project never opened in
/// the editor has no edit files: it is drawn with the new document of `EditContext.defaultStyle` (without an image
/// background, which only opening it copies into the package), which the key does not cover, so its thumbnail can show a
/// default style changed since, until it is opened (which writes its log, and so changes its key).
///
/// What the caller decides: which cards to draw (the visible ones, two at a time and with a low priority, cancelling a card
/// that scrolls away), and which projects may be looked at (`mayDraw(place:volume:opened:)`): never, by itself, one of
/// Other places or on a removable, network or synced volume. What it does by itself: it draws nothing while
/// `isRecording()` (the take owns the disk and the GPU; thumbnails already in the cache are still read, a light read), nor
/// for a project that cannot be opened (`ProjectState`), nor for a caller cancelled before its frame is drawn; it draws a
/// key asked for twice at once only once; and it never writes inside a package.
///
/// No thread of Swift's cooperative pool waits for anything: the cache and the package's files are read, the HEIC
/// decoded, the frame decoded and drawn and the HEIC written on a concurrent queue of the actor's own, which the actor
/// waits for suspended, so two thumbnails can be drawn at once. (Not a serial dispatch queue as the actor's executor:
/// the Thread Sanitizer of `make tsan` reports the isolated code of such an actor as racing with itself.)
///
/// The cache is trimmed after each thumbnail written, once it is handed back, to `maxBytes`, the files used longest ago
/// first (a file's date is touched whenever it is read); temporary files left by a write that never finished go after
/// `staleTemporarySeconds`.
public actor LibraryThumbnails {
    /// Twice the card's size (design §6.8): the box every thumbnail fits in.
    public static let pixelSize = SIMD2<Int>(520, 292)
    /// What the cache may take on the disk (design §13.4).
    public static let maxCacheBytes: Int64 = 500 * 1_048_576
    /// The version of how a thumbnail looks, in its key: what it shows, where, how big and how it is encoded.
    static let version = "thumb-1"
    /// The quality of the HEIC. Below 1, ImageIO's encoder stays at about 40 dB (PSNR) of the frame drawn on sharp
    /// coloured edges, as a screen has, from 0.92 up (0.9 falls under it); at 1, 47 dB, in the same time (10 ms for
    /// 520 × 292) and about 65 KB, 7 500 thumbnails in `maxCacheBytes`.
    static let quality = 1.0
    /// The largest file of the cache that is read.
    static let maxFileBytes = 8 * 1_048_576
    /// How old a temporary file of the cache is when the trim removes it: a write takes milliseconds, so one this old was
    /// left by a crash.
    static let staleTemporarySeconds: Int64 = 600

    /// `~/Library/Caches/dev.toma.Toma/Library/thumbnails`.
    public static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "dev.toma.Toma", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "thumbnails", directoryHint: .isDirectory)
    }

    private let directory: URL
    private let maxBytes: Int64
    private let isRecording: @Sendable () -> Bool
    /// Where the cache and the package's files are read, the frames drawn and the cache written, two or more at once:
    /// never a thread of the cooperative pool.
    private let work = DispatchQueue(label: "dev.toma.Toma.LibraryThumbnails", qos: .utility, attributes: .concurrent)
    /// The draws under way, by key, with how many callers wait for each.
    private var drawing = InFlight()
    /// How many frames were drawn on the GPU rather than read from the cache, for tests.
    private(set) var renders = 0
    /// What tests run on `work` while a thumbnail is drawn.
    private var hooks = Hooks()

    /// What tests run on `work`, to see where the cache is read, hold a draw or start a take in the middle of one.
    struct Hooks: Sendable {
        /// Before a thumbnail is read from the cache.
        var beforeReading: (@Sendable () -> Void)?
        /// Before the project's document is read.
        var beforeDrawing: (@Sendable () -> Void)?
        /// Once the frame is drawn, before the HEIC is encoded and written.
        var afterDrawing: (@Sendable () -> Void)?
    }

    /// - Parameters:
    ///   - directory: the cache's folder (`defaultDirectory` in the app), made when the first thumbnail is written;
    ///     never one inside a package.
    ///   - isRecording: whether the app is recording: while it is, nothing is drawn (the cache is still read).
    public init(
        directory: URL, maxBytes: Int64 = LibraryThumbnails.maxCacheBytes, isRecording: @escaping @Sendable () -> Bool
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.isRecording = isRecording
    }

    /// The output instant a project `outputSeconds` long is shown at: 10 % of the way, at most at 20 s (design §6.8:
    /// content, not the user starting); 0 for no length.
    public static func time(outputSeconds: Double) -> Double {
        guard outputSeconds.isFinite, outputSeconds > 0 else { return 0 }
        return min(0.1 * outputSeconds, 20)
    }

    /// The key of the thumbnail of a package (plan decision 26): SHA-256, in lowercase hex, of `thumb-1`, `\n`, the
    /// bytes of `manifest.json`, `\n`, those of `edit.json` (nothing without it), `\n`, the size and the modification date
    /// in nanoseconds of `edit-log.jsonl` as `<size> <date>` (nothing without it), `\n`, and the box the thumbnail is
    /// drawn in, `size`, as `<width>x<height>`.
    public static func key(manifest: Data, edit: Data?, log: FileSignature?, size: SIMD2<Int>) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(version)\n".utf8))
        hasher.update(data: manifest)
        hasher.update(data: Data("\n".utf8))
        if let edit { hasher.update(data: edit) }
        hasher.update(data: Data("\n".utf8))
        if let log { hasher.update(data: Data("\(log.size) \(log.modified)".utf8)) }
        hasher.update(data: Data("\n\(size.x)x\(size.y)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The size a thumbnail of `aspect` is drawn at: the largest output of that aspect (`StageLayout`'s, both sides even)
    /// inside `pixelSize`. 520 × 292 in 16:9, 164 × 292 in 9:16, 292 × 292 in 1:1; `auto` from `contentRatio`, the ratio of
    /// the recording's screen (`StageLayout.contentRatio`; 16:9 without it).
    static func size(for aspect: Aspect, contentRatio: Double? = nil) -> SIMD2<Int> {
        var shortSide = min(pixelSize.x, pixelSize.y)
        while shortSide > 1 {
            let size = StageLayout.outputSize(aspect: aspect, shortSide: shortSide, contentRatio: contentRatio)
            if size.x <= pixelSize.x, size.y <= pixelSize.y { return size }
            shortSide -= 1
        }
        return SIMD2(1, 1)
    }

    /// Whether the thumbnail of a project in `place`, on `volume`, may be drawn (design §6.5, §6.8). By itself, in the
    /// background: only one in the projects folder (or its trash) on a local volume inside the Mac that is not synced.
    /// When the user `opened` it in the editor: any one except on a network or synced volume, where reading its media
    /// could make the system download it.
    public static func mayDraw(place: Place, volume: VolumeInfo, opened: Bool = false) -> Bool {
        guard !volume.isNetwork, !volume.isSynced else { return false }
        if opened { return true }
        guard place != .elsewhere else { return false }
        return volume.isInternal && !volume.isRemovable
    }

    /// The thumbnail of key `key` (`ProjectSummary.thumbnailKey`, `key(of:)`) from the cache, which counts as a use of
    /// it; `nil` if there is none or it cannot be read. Read and decoded on the actor's queue, also while a take records.
    public func cached(_ key: String) async -> CGImage? {
        let directory = self.directory, hooks = self.hooks
        return await onWork {
            hooks.beforeReading?()
            return Self.read(key, in: directory)
        }
    }

    /// The thumbnail of the package at `url`, which `summary` describes: from the cache if the project did not change
    /// since one was drawn, also while a take records; otherwise drawn now and written to the cache, unless a take
    /// records. `nil` when it would have to be drawn while a take records, for a project that cannot be opened (to
    /// repair, of a newer version, unfinished or not available), for a caller cancelled before it is done, and if anything
    /// fails. Callers asking for the same key at once share one draw, which stops (drawing and writing nothing more) once
    /// all of them are cancelled.
    public func render(_ url: URL, summary: ProjectSummary, context: EditContext) async -> CGImage? {
        guard Self.isDrawable(summary.state) else { return nil }
        let directory = self.directory, hooks = self.hooks
        guard let looked = await onWork({ () -> (key: String, cached: CGImage?)? in
            guard let key = try? Self.key(of: url) else { return nil }
            hooks.beforeReading?()
            return (key, Self.read(key, in: directory))
        }) else { return nil }
        if let image = looked.cached { return image }

        guard !isRecording(), !Task.isCancelled else { return nil }
        let key = looked.key
        let task = drawing.join(key) { Task { await self.draw(url, key: key, context: context) } }
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(key, task) }
        }
        drawing.finish(key, task)
        return Task.isCancelled ? nil : image
    }

    private func leave(_ key: String, _ task: Task<CGImage?, Never>) {
        drawing.leave(key, task)
    }

    /// How many callers wait for the draw of `key`, for tests.
    func waiting(for key: String) -> Int {
        drawing.waiters(for: key)
    }

    func setHooks(_ hooks: Hooks) {
        self.hooks = hooks
    }

    /// The thumbnail of the package at `url`, whose key was `key`, drawn on `work` and written to the cache under that key
    /// if the package still has it; the image is handed back before the cache is trimmed and the renderer closed. Stops
    /// before drawing, and writes nothing, once a take records or the task is cancelled.
    private func draw(_ url: URL, key: String, context: EditContext) async -> CGImage? {
        let stopped = Flag()
        let isRecording = self.isRecording, directory = self.directory, maxBytes = self.maxBytes, hooks = self.hooks
        let shouldStop: @Sendable () -> Bool = { isRecording() || stopped.isSet }
        let drawn = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(image: CGImage?, drew: Bool), Never>) in
                work.async {
                    hooks.beforeDrawing?()
                    Self.draw(url, context: context, shouldStop: shouldStop) { image in
                        hooks.afterDrawing?()
                        // Kept only under the key of what was drawn (a project that changed meanwhile is drawn again
                        // next time), and neither encoded nor written once a take records: nothing competes with it.
                        let file = Self.file(key, in: directory)
                        let stored =
                            if let image, !shouldStop(), (try? Self.key(of: url)) == key, let heic = Self.heic(image),
                               !shouldStop()
                            {
                                Self.write(heic, to: file)
                            } else {
                                false
                            }
                        continuation.resume(returning: (image, true))
                        if stored { Self.trim(directory, to: maxBytes, keeping: file.lastPathComponent) }
                    } stopped: {
                        continuation.resume(returning: (nil, false))
                    }
                }
            }
        } onCancel: {
            stopped.set()
        }
        if drawn.drew { renders += 1 }
        return drawn.image
    }

    /// Whether a project in `state` can be drawn: it opens.
    private static func isDrawable(_ state: ProjectState) -> Bool {
        switch state {
        case .normal, .readOnlyVolume, .inTrash: true
        case .unfinished, .needsRepair, .newerVersion, .unavailable: false
        }
    }

    /// The key of the thumbnail of the package at `url` as it is now, at `pixelSize`: what the index keeps as
    /// `ProjectSummary.thumbnailKey`, for `cached(_:)`. `manifest.json` (at most `ProjectReader.maxManifestBytes`) and
    /// `edit.json` are read with `SafeRead`, never through a link, and `edit-log.jsonl` looked at with `lstat`: light reads,
    /// never on the main thread. Throws what reading them throws (a missing `edit.json` or log is part of the key).
    public static func key(of url: URL) throws -> String {
        let package = ProjectPackage(url: url)
        let manifest = try SafeRead.regularFile(at: package.manifestURL, maxBytes: ProjectReader.maxManifestBytes)
        let edit: Data?
        do {
            edit = try SafeRead.regularFile(at: package.editURL)
        } catch let error as POSIXError where error.code == .ENOENT {
            edit = nil
        }
        var info = stat()
        let log: FileSignature?
        if lstat(package.editLogURL.path, &info) == 0 {
            let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            log = FileSignature(size: Int64(info.st_size), modified: modified)
        } else if errno == ENOENT {
            log = nil
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return key(manifest: manifest, edit: edit, log: log, size: pixelSize)
    }

    /// Calls `finish` with the frame at `time(outputSeconds:)` of the project at `url` as the export draws it, at
    /// `size(for:)` of its aspect (`nil` if the GPU could not draw it), or `stopped` if nothing was drawn: the document
    /// could not be read (with the take's event log, which the cursor and the clicks come from: `readDocument` throws
    /// for one it cannot read, so no thumbnail is ever kept without them) or the renderer made, or `shouldStop()` once
    /// the document is read. One of them, once. The document is read without a lock and without writing anything.
    /// Decodes and waits for the GPU: never on the cooperative pool. The renderer goes only after `finish` returns:
    /// closing its readers (`AVAssetReader.cancelReading`) takes some 20 ms, which the thumbnail need not wait for.
    private static func draw(
        _ url: URL, context: EditContext, shouldStop: () -> Bool, then finish: (CGImage?) -> Void,
        stopped: () -> Void
    ) {
        let renderer: FrameRenderer, size: SIMD2<Int>
        do {
            let (project, document) = try EditSession.readDocument(url, take: nil, context: context)
            guard !shouldStop() else { return stopped() }
            size = Self.size(
                for: document.aspect,
                contentRatio: StageLayout.contentRatio(take: project.take, document: document, events: project.events))
            renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        } catch {
            return stopped()
        }
        withExtendedLifetime(renderer) {
            let bytes = try? renderer.renderBytes(at: time(outputSeconds: renderer.duration))
            finish(bytes.flatMap { image(bgra: $0, size: size) })
        }
    }

    /// The renderer's BGRA bytes, `size` big and opaque, as an image tagged Rec. 709: the space the preview and the export
    /// are shown in.
    private static func image(bgra bytes: [UInt8], size: SIMD2<Int>) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.itur_709),
              let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { return nil }
        return CGImage(
            width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// `image` as HEIC at `quality`, or `nil` if ImageIO cannot write it.
    private static func heic(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// `<directory>/<key>.heic`.
    private static func file(_ key: String, in directory: URL) -> URL {
        directory.appending(path: "\(key).heic", directoryHint: .notDirectory)
    }

    /// The thumbnail of `key` in `directory`, decoded now, its file's date touched; `nil` for a key that is not one
    /// (`key(manifest:edit:log:size:)`'s 64 hex digits: nothing outside `directory` is read), a file that is not there, is
    /// not a regular file (a link is not followed) or does not decode as HEIC.
    private static func read(_ key: String, in directory: URL) -> CGImage? {
        guard key.utf8.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        let file = file(key, in: directory)
        guard let data = try? SafeRead.regularFile(at: file, maxBytes: maxFileBytes),
              let image = BoundedImage.decode(
                data, maxPixelSide: max(pixelSize.x, pixelSize.y), allowedTypes: ["public.heic"])
        else { return nil }
        // Used now: the last to go when the cache is trimmed.
        utimensat(AT_FDCWD, file.path, nil, AT_SYMLINK_NOFOLLOW)
        return image
    }

    /// Writes `data` to `url` through a temporary file in its folder renamed over it, so a reader sees the old file or the
    /// new one, never part of one, making the folder if it is not there (macOS empties caches). Not synced to the drive:
    /// a cache can be made again. A write that fails leaves nothing; whether it was written.
    private static func write(_ data: Data, to url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: temporary, options: .withoutOverwriting)
            guard rename(temporary.path, url.path) == 0 else {
                unlink(temporary.path)
                return false
            }
            return true
        } catch {
            unlink(temporary.path)
            return false
        }
    }

    /// Removes the thumbnails of `directory` used longest ago (by their files' dates) until those left take at most
    /// `maxBytes`, never the file named `keeping`, the one just written, and the temporary files of `write` older than
    /// `staleTemporarySeconds`. Only regular files count; one that goes meanwhile counts as nothing.
    private static func trim(_ directory: URL, to maxBytes: Int64, keeping: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1e9)
        var files: [(name: String, size: Int64, used: Int64)] = []
        for name in names {
            let isTemporary = name.hasPrefix(".") && name.hasSuffix(".tmp")
            guard isTemporary || (name.hasSuffix(".heic") && !name.hasPrefix(".")) else { continue }
            let path = directory.appending(path: name, directoryHint: .notDirectory).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let used = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            if isTemporary {
                if now - used > staleTemporarySeconds * 1_000_000_000 { unlink(path) }
            } else {
                files.append((name, Int64(info.st_size), used))
            }
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { ($0.used, $0.name) < ($1.used, $1.name) }) where total > maxBytes {
            guard file.name != keeping else { continue }
            if unlink(directory.appending(path: file.name, directoryHint: .notDirectory).path) == 0 || errno == ENOENT {
                total -= file.size
            }
        }
    }

    /// Runs `body` on `work` and returns what it returns, suspended meanwhile.
    private func onWork<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            work.async { continuation.resume(returning: body()) }
        }
    }
}

/// The draws under way, by key, which every caller asking for the same key while one runs shares: the first caller starts
/// it, the others wait for the same result, and it is cancelled once every caller waiting for it was cancelled (as
/// `SharedWork` does for the editor's caches). Kept by the actor, which uses it only from its own isolation.
private struct InFlight {
    private var running: [String: (task: Task<CGImage?, Never>, waiters: Int)] = [:]

    /// The draw of `key`: the one running, now with one more waiter, or the one `start` makes.
    mutating func join(_ key: String, start: () -> Task<CGImage?, Never>) -> Task<CGImage?, Never> {
        if var entry = running[key] {
            entry.waiters += 1
            running[key] = entry
            return entry.task
        }
        let task = start()
        running[key] = (task, 1)
        return task
    }

    /// A waiter of `task` was cancelled: once none waits for it, the draw is cancelled and the next caller starts anew.
    mutating func leave(_ key: String, _ task: Task<CGImage?, Never>) {
        guard var entry = running[key], entry.task == task else { return }
        entry.waiters -= 1
        if entry.waiters > 0 {
            running[key] = entry
        } else {
            running[key] = nil
            task.cancel()
        }
    }

    /// `task` returned to a waiter: the next caller for `key` starts anew (and finds what it left in the cache).
    mutating func finish(_ key: String, _ task: Task<CGImage?, Never>) {
        if running[key]?.task == task { running[key] = nil }
    }

    func waiters(for key: String) -> Int {
        running[key]?.waiters ?? 0
    }
}

/// A flag set once, from any thread.
private final class Flag: Sendable {
    private let state = Mutex(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() {
        state.withLock { $0 = true }
    }
}
