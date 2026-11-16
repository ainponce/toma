// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CryptoKit
import Darwin
import Editing
import Foundation
import ImageIO
import ProjectFormat
import Render

/// The library's thumbnails (design §6.8, plan decision 26, `thumb-1`): each project as it is exported (style, layout,
/// camera) at output instant `time(outputSeconds:)`, drawn by the export's `FrameRenderer` from its document as
/// `EditSession.readDocument` reads it, at the size of its aspect inside `pixelSize`, and kept as HEIC in `directory`
/// as `<key>.heic`. The key comes from what the package holds (`key(manifest:edit:log:size:)`): a change to the project
/// gives another thumbnail, and a copy that did not change shares its original's.
///
/// What the caller decides: which cards to draw (the visible ones, two at a time and with a low priority), and which
/// projects may be looked at (`mayDraw(place:volume:opened:)`): never, by itself, one of Other places or on a removable,
/// network or synced volume. What it does by itself: nothing while `isRecording()` (the take owns the disk and the GPU),
/// nothing for a project that cannot be opened (`ProjectState`), and it never writes inside a package.
///
/// No thread of Swift's cooperative pool waits for anything: the package's files are read, the frame decoded and drawn,
/// and the HEIC written on a queue of the actor's own, which the actor waits for suspended, so two thumbnails can be
/// drawn at once. `cached(_:)` reads one small file of the cache on the actor.
///
/// The cache is trimmed after each thumbnail written, to `maxBytes`, the files used longest ago first: a file's date is
/// touched whenever it is read.
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

    /// `~/Library/Caches/dev.toma.Toma/Library/thumbnails`.
    public static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "dev.toma.Toma", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "thumbnails", directoryHint: .isDirectory)
    }

    private let directory: URL
    private let maxBytes: Int64
    private let isRecording: @Sendable () -> Bool
    /// Where the files are read and written and the frames drawn: never a thread of the cooperative pool.
    private let work = DispatchQueue(label: "dev.toma.Toma.LibraryThumbnails", qos: .utility, attributes: .concurrent)
    /// How many thumbnails were set to be drawn rather than read from the cache, for tests.
    private(set) var renders = 0

    /// - Parameters:
    ///   - directory: the cache's folder (`defaultDirectory` in the app), made when the first thumbnail is written;
    ///     never one inside a package.
    ///   - isRecording: whether the app is recording: while it is, nothing is drawn.
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
    /// inside `pixelSize`. 520 × 292 in 16:9, 164 × 292 in 9:16, 292 × 292 in 1:1.
    static func size(for aspect: Aspect) -> SIMD2<Int> {
        var shortSide = min(pixelSize.x, pixelSize.y)
        while shortSide > 1 {
            let size = StageLayout.outputSize(aspect: aspect, shortSide: shortSide)
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

    /// The thumbnail of key `key` from the cache, which counts as a use of it; `nil` if there is none or it cannot be
    /// read.
    public func cached(_ key: String) -> CGImage? {
        Self.read(key, in: directory)
    }

    /// The thumbnail of the package at `url`, which `summary` describes: from the cache if the project did not change
    /// since one was drawn, otherwise drawn now and written to the cache. `nil` while the app is recording, for a project
    /// that cannot be opened (to repair, of a newer version, unfinished or not available), and if anything fails.
    public func render(_ url: URL, summary: ProjectSummary, context: EditContext) async -> CGImage? {
        guard !isRecording(), Self.isDrawable(summary.state) else { return nil }
        let directory = self.directory
        guard let looked = await onWork({ () -> (key: String, cached: CGImage?)? in
            guard let key = try? Self.key(of: url) else { return nil }
            return (key, Self.read(key, in: directory))
        }) else { return nil }
        if let image = looked.cached { return image }

        let isRecording = self.isRecording, maxBytes = self.maxBytes
        guard !isRecording() else { return nil }
        renders += 1
        return await withCheckedContinuation { continuation in
            work.async {
                Self.draw(url, context: context, isRecording: isRecording) { image in
                    // Kept only under the key of what was drawn: a project that changed meanwhile is drawn again next
                    // time.
                    if let image, (try? Self.key(of: url)) == looked.key, let heic = Self.heic(image) {
                        let file = Self.file(looked.key, in: directory)
                        if Self.write(heic, to: file) { Self.trim(directory, to: maxBytes, keeping: file.lastPathComponent) }
                    }
                    continuation.resume(returning: image)
                }
            }
        }
    }

    /// Whether a project in `state` can be drawn: it opens.
    private static func isDrawable(_ state: ProjectState) -> Bool {
        switch state {
        case .normal, .readOnlyVolume, .inTrash: true
        case .unfinished, .needsRepair, .newerVersion, .unavailable: false
        }
    }

    /// The key of the package at `url` as it is now, at `pixelSize`: `manifest.json` (at most
    /// `ProjectReader.maxManifestBytes`) and `edit.json` read with `SafeRead`, never through a link, and `edit-log.jsonl`
    /// looked at with `lstat`.
    static func key(of url: URL) throws -> String {
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

    /// Calls `finish`, once, with the frame at `time(outputSeconds:)` of the project at `url` as the export draws it, at
    /// `size(for:)` of its aspect, or with `nil` if it cannot be drawn: its document read without a lock and without
    /// writing anything, and nothing drawn if `isRecording()` by then. Decodes and waits for the GPU: never on the
    /// cooperative pool. The renderer goes only after `finish` returns: closing its readers (`AVAssetReader.cancelReading`)
    /// takes some 20 ms, which the thumbnail need not wait for.
    private static func draw(
        _ url: URL, context: EditContext, isRecording: () -> Bool, then finish: (CGImage?) -> Void
    ) {
        let renderer: FrameRenderer, size: SIMD2<Int>
        do {
            let (project, document) = try EditSession.readDocument(url, take: nil, context: context)
            guard !isRecording() else { return finish(nil) }
            size = Self.size(for: document.aspect)
            renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        } catch {
            return finish(nil)
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
    /// `maxBytes`, never the file named `keeping`, the one just written. Only the regular `.heic` files of the folder
    /// count; one that goes meanwhile counts as nothing.
    private static func trim(_ directory: URL, to maxBytes: Int64, keeping: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var files: [(name: String, size: Int64, used: Int64)] = []
        for name in names where name.hasSuffix(".heic") && !name.hasPrefix(".") {
            var info = stat()
            guard lstat(directory.appending(path: name, directoryHint: .notDirectory).path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG
            else { continue }
            let used = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            files.append((name, Int64(info.st_size), used))
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
