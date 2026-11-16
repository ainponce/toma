// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os
import ProjectFormat
import Synchronization
import UniformTypeIdentifiers

/// The cursor macOS shows, as `CursorImageRecorder` records it.
public struct CursorSnapshot: Sendable {
    /// The cursor drawn at `scale(forPointSize:)` pixels per point: 4, or fewer for a cursor over 128 pt.
    public var image: CGImage
    /// Width (`x`) and height (`y`) in points.
    public var pointSize: SIMD2<Double>
    /// Where the pointer is in the image, in points from its top left.
    public var hotspot: SIMD2<Double>
    /// A cheap fingerprint of the cursor at 1× (its pixels, size and hotspot): the same cursor gives the same one, so
    /// the recorder only draws, hashes and writes an image when it changes. `CursorKindMatcher` matches on it.
    public var fingerprint: UInt64

    public init(image: CGImage, pointSize: SIMD2<Double>, hotspot: SIMD2<Double>, fingerprint: UInt64) {
        self.image = image
        self.pointSize = pointSize
        self.hotspot = hotspot
        self.fingerprint = fingerprint
    }

    /// How many pixels per point `image` has at most: sharp up to 4× of zoom and size (design §9).
    static let maxScale = 4.0
    /// The largest side, in pixels, of an image in `cursors/`: what the package's reader decodes (design §6.1).
    static let maxPixelSide = Double(PackageFileKind.cursorImage.maxPixelSide)
    /// The largest side, in pixels, of the 1× drawing the fingerprint is taken of.
    static let maxFingerprintSide = 128.0
    /// The largest cursor side, in points, that is drawn: anything bigger is not a cursor.
    static let maxPointSide = 1024.0

    /// The pixels per point `image` is drawn at: 4, or `512 / longest side` for a cursor over 128 pt, so that no side
    /// passes the 512 px the package's reader decodes (design §6.1). The event's `size` stays in points and its
    /// `hotspot` a fraction, so the editor draws it the same size, only less sharp when zoomed.
    static func scale(forPointSize size: SIMD2<Double>) -> Double {
        min(maxScale, maxPixelSide / max(size.x, size.y))
    }

    /// `cursor` drawn at `scale(forPointSize:)`, with `fingerprint` if the caller already has it. `nil` if its image
    /// has no size or a side over `maxPointSide`.
    @MainActor init?(cursor: NSCursor, fingerprint: UInt64? = nil) {
        let size = cursor.image.size
        guard let fingerprint = fingerprint ?? Self.fingerprint(of: cursor),
              let image = Self.draw(
                cursor.image, scale: Self.scale(forPointSize: SIMD2(size.width, size.height)), maxPixelSide: Self.maxPixelSide
              )?.makeImage()
        else { return nil }
        self.init(
            image: image, pointSize: SIMD2(size.width, size.height), hotspot: SIMD2(cursor.hotSpot.x, cursor.hotSpot.y),
            fingerprint: fingerprint)
    }

    /// FNV-1a over the size and hotspot of `cursor` (`Float64` bits) and its pixels at 1×, drawn as in `draw`; a
    /// cursor over 128 pt is drawn smaller, at most 128 px a side, so a sample never draws much. (No cursor of
    /// `CursorKindMatcher.makeLive()` is that big.) `nil` if its image has no size or a side over `maxPointSide`.
    @MainActor static func fingerprint(of cursor: NSCursor) -> UInt64? {
        let size = cursor.image.size
        let scale = min(1, maxFingerprintSide / max(size.width, size.height))
        guard let context = draw(cursor.image, scale: scale, maxPixelSide: maxFingerprintSide), let pixels = context.data
        else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: UnsafeRawBufferPointer) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
        }
        for value in [size.width, size.height, cursor.hotSpot.x, cursor.hotSpot.y] {
            withUnsafeBytes(of: Double(value).bitPattern.littleEndian, mix)
        }
        mix(UnsafeRawBufferPointer(start: pixels, count: context.bytesPerRow * context.height))
        return hash
    }

    /// A context of `image` drawn at `scale` pixels per point, in `CursorImageHash`'s pixel format, rows packed, each
    /// side rounded up to whole pixels and at most `maxPixelSide` (which only a rounding error of `scale` could pass).
    @MainActor private static func draw(_ image: NSImage, scale: Double, maxPixelSide: Double) -> CGContext? {
        let size = image.size
        guard size.width > 0, size.height > 0, size.width <= maxPointSide, size.height <= maxPointSide else { return nil }
        func pixels(_ side: Double) -> Int { Int(min((side * scale).rounded(.up), maxPixelSide)) }
        guard let context = CursorImageHash.makeContext(width: pixels(size.width), height: pixels(size.height)) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        return context
    }

    /// Whether its size is positive and its size and hotspot finite: what an event can say.
    var isLoggable: Bool {
        pointSize.x > 0 && pointSize.y > 0 && pointSize.x.isFinite && pointSize.y.isFinite
            && hotspot.x.isFinite && hotspot.y.isFinite
    }
}

/// Where `CursorImageRecorder` reads the cursor macOS shows.
public protocol SystemCursorSource: Sendable {
    /// The cursor shown now, in any app; `nil` if macOS gives none.
    @MainActor func current() -> CursorSnapshot?
}

/// The cursor of `NSCursor.currentSystem`, which needs no permission. The SDK marks it `API_TO_BE_DEPRECATED`: when it
/// gives no cursor, `current()` is `nil` and the take records no image (plan decision 14). Its image is drawn (at
/// `CursorSnapshot.scale(forPointSize:)`, at most 512 px a side) only when its fingerprint changes.
public struct LiveSystemCursor: SystemCursorSource {
    /// The last cursor drawn.
    private final class Cache: Sendable {
        let last = Mutex<CursorSnapshot?>(nil)
    }

    private let cache = Cache()

    public init() {}

    @MainActor public func current() -> CursorSnapshot? {
        guard let cursor = NSCursor.currentSystem, let fingerprint = CursorSnapshot.fingerprint(of: cursor) else { return nil }
        if let last = cache.last.withLock({ $0 }), last.fingerprint == fingerprint { return last }
        let snapshot = CursorSnapshot(cursor: cursor, fingerprint: fingerprint)
        cache.last.withLock { $0 = snapshot }
        return snapshot
    }
}

/// The name of a cursor's image in `cursors/`.
public enum CursorImageHash {
    /// The first 16 bytes of SHA-256, as 32 lowercase hex digits, over the width and height of `snapshot.image` in
    /// pixels (`Int32` little-endian), `snapshot.hotspot` x and y in points (`Float64` little-endian) and the image's
    /// pixels as drawn, as `rgbaPixels(of:)` gives them (premultiplied RGBA, at 4× or, over 128 pt, at
    /// `CursorSnapshot.scale(forPointSize:)`).
    public static func hash(_ snapshot: CursorSnapshot) -> String {
        let image = snapshot.image
        var hasher = SHA256()
        withUnsafeBytes(of: Int32(clamping: image.width).littleEndian) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: Int32(clamping: image.height).littleEndian) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: snapshot.hotspot.x.bitPattern.littleEndian) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: snapshot.hotspot.y.bitPattern.littleEndian) { hasher.update(bufferPointer: $0) }
        rgbaPixels(of: image).withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The pixels of `image` drawn into 8-bit sRGB RGBA with premultiplied alpha, top row first, `width × 4` bytes a row.
    static func rgbaPixels(of image: CGImage) -> [UInt8] {
        let (width, height) = (image.width, image.height)
        guard let context = makeContext(width: width, height: height), let data = context.data else {
            return [UInt8](repeating: 0, count: width * height * 4)
        }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return [UInt8](UnsafeRawBufferPointer(start: data, count: width * height * 4))
    }

    /// An empty context in that pixel format.
    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }
}

/// Records the shape of the cursor while a take runs: every `interval`, on the main actor, the cursor macOS shows
/// (`SystemCursorSource`); when its fingerprint differs from the last one sent, its image goes to
/// `takes/<take>/cursors/<hash>.png` (the folder next to the log) and a `cursorImage` event, with the time of the
/// sample, to the log once the image is on disk. An image already written this take, or already in the folder, is not
/// written again: a cursor that goes back and forth between the arrow and the I-beam syncs the disk once per shape and
/// take, not once per change. Nothing is sampled while paused; on `start` and `resume` the cursor is logged at once.
///
/// The images are written off the main thread, one after the other, with `DurableFile.writeNew`, and the events are
/// appended in the order of their samples. An image that cannot be written, or whose PNG is over the 1 MiB the
/// package's reader takes (design §6.1), logs no event, only a line in the app's log; it is tried again the next time
/// the cursor takes that shape. Needs no permission.
public final class CursorImageRecorder: InputRecorder, Sendable {
    public static let interval: Duration = .nanoseconds(33_333_333)

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "CursorImageRecorder")
    /// The main queue, where the timer fires. It is a serial queue (`dispatch_queue_main_t` is a subclass of
    /// `dispatch_queue_serial_t` in `<dispatch/queue.h>`); Swift only types `DispatchQueue.main` as a `DispatchQueue`.
    private static let mainQueue = DispatchQueue.main as! DispatchSerialQueue

    private struct State {
        var log: EventLogWriter?
        var generation = 0
        var kinds: CursorKindMatcher?
        /// From `start` until `stop`: the timer may run.
        var accepting = false
        var paused = false
        var timer: (any RecordingTimer)?
        /// The fingerprint of the last cursor sent to be written; `nil` sends the next one.
        var lastFingerprint: UInt64?
        /// The hashes whose image is in `cursors/` this take.
        var saved: Set<String> = []
        /// Images written this take, not counting those already there.
        var imagesWritten = 0
    }

    /// A sample to write: its image if needed, then its event.
    private struct Job: Sendable {
        let snapshot: CursorSnapshot
        let t: HostTime
        let kind: CursorKind?
        let log: EventLogWriter
        let generation: Int
    }

    private let source: any SystemCursorSource
    private let givenKinds: CursorKindMatcher?
    private let clock: @Sendable () -> HostTime
    private let ticks: RecordingTicks
    private let maxImageBytes: Int
    /// Writes the images and appends their events, one sample after the other.
    private let writer = DispatchQueue(label: "dev.toma.cursor-images", qos: .utility)
    private let state = Mutex(State())

    /// `kinds` `nil` builds `CursorKindMatcher.makeLive()` on the main actor when a take starts.
    public convenience init(
        source: any SystemCursorSource = LiveSystemCursor(), kinds: CursorKindMatcher? = nil,
        clock: @escaping @Sendable () -> HostTime = HostTime.now
    ) {
        self.init(source: source, kinds: kinds, clock: clock, ticks: .live)
    }

    /// Tests pass their own ticks, and a smaller limit for a PNG.
    init(
        source: any SystemCursorSource, kinds: CursorKindMatcher?, clock: @escaping @Sendable () -> HostTime, ticks: RecordingTicks,
        maxImageBytes: Int = PackageFileKind.cursorImage.maxBytes
    ) {
        self.source = source
        givenKinds = kinds
        self.clock = clock
        self.ticks = ticks
        self.maxImageBytes = maxImageBytes
    }

    /// Images written to `cursors/` this take, not counting those already there.
    var imagesWritten: Int {
        state.withLock { $0.imagesWritten }
    }

    public func start(log: EventLogWriter) async {
        let generation: Int? = state.withLock { s in
            guard s.log == nil else { return nil }
            s.log = log
            s.generation += 1
            s.kinds = nil
            s.accepting = true
            s.paused = false
            s.lastFingerprint = nil
            s.saved = []
            s.imagesWritten = 0
            return s.generation
        }
        guard let generation else { return }
        let kinds: CursorKindMatcher
        if let givenKinds {
            kinds = givenKinds
        } else {
            kinds = await MainActor.run { CursorKindMatcher.makeLive() }
        }
        let started = state.withLock { s in
            guard s.log != nil, s.generation == generation else { return false }
            s.kinds = kinds
            return startSampling(&s)
        }
        if started { await MainActor.run { sample() } }
    }

    /// Stops sampling and waits for the images being written: once it returns, no event of the take before the pause is
    /// still to come.
    public func pause() async {
        let (pausedNow, timer) = state.withLock { s -> (Bool, (any RecordingTimer)?) in
            guard s.log != nil, !s.paused else { return (false, nil) }
            s.paused = true
            defer { s.timer = nil }
            return (true, s.timer)
        }
        guard pausedNow else { return }
        timer?.cancel()
        await writesDone()
    }

    /// Samples again, logging the cursor at once.
    public func resume() async {
        let started = state.withLock { s in
            guard s.log != nil, s.paused else { return false }
            s.paused = false
            s.lastFingerprint = nil
            return startSampling(&s)
        }
        if started { await MainActor.run { sample() } }
    }

    /// Stops sampling and waits for the images being written and their events, which land before it returns.
    public func stop() async {
        let timer = state.withLock { s -> (any RecordingTimer)? in
            s.accepting = false
            defer { s.timer = nil }
            return s.timer
        }
        timer?.cancel()
        await writesDone()
        state.withLock { s in
            s.log = nil
            s.kinds = nil
            s.paused = false
            s.lastFingerprint = nil
            s.saved = []
        }
    }

    /// Starts the timer unless it runs, the take is paused or stopping, or the matcher is not ready. Whether it did.
    private func startSampling(_ s: inout State) -> Bool {
        guard s.log != nil, s.accepting, !s.paused, s.kinds != nil, s.timer == nil else { return false }
        s.timer = ticks.every(Self.interval, Self.mainQueue) { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
        return true
    }

    /// Sends the cursor to be written if it changed. Sent under the lock: `pause()` and `stop()` take it before they
    /// wait for the writer, so they wait for this sample too.
    @MainActor private func sample() {
        let time = clock()
        guard let snapshot = source.current(), snapshot.isLoggable else { return }
        state.withLock { s in
            guard let log = s.log, let kinds = s.kinds, !s.paused, s.timer != nil, s.lastFingerprint != snapshot.fingerprint
            else { return }
            s.lastFingerprint = snapshot.fingerprint
            let job = Job(snapshot: snapshot, t: time, kind: kinds.kind(of: snapshot), log: log, generation: s.generation)
            writer.async { [self] in save(job) }
        }
    }

    /// On the writer: the image unless it is there, then the event.
    private func save(_ job: Job) {
        let hash = CursorImageHash.hash(job.snapshot)
        let folder = job.log.url.deletingLastPathComponent().appendingPathComponent("cursors", isDirectory: true)
        let name = hash + ".png"
        let known = state.withLock { $0.generation == job.generation && $0.saved.contains(hash) }
        if !known {
            if !Self.isRegularFile(name, in: folder) {
                do {
                    let png = try Self.pngData(job.snapshot.image)
                    guard png.count <= maxImageBytes else {
                        Self.logger.error(
                            "A cursor image of \(png.count) bytes is over the \(self.maxImageBytes) a package's reader takes: not saved")
                        return
                    }
                    let written = try Self.write(png, to: folder.appendingPathComponent(name, isDirectory: false))
                    if written { state.withLock { $0.imagesWritten += 1 } }
                } catch {
                    Self.logger.error("Could not save a cursor image: \(String(describing: error), privacy: .public)")
                    return
                }
            }
            state.withLock { s in
                if s.generation == job.generation { s.saved.insert(hash) }
            }
        }
        let size = job.snapshot.pointSize
        let event = InputEvent(
            t: job.t, kind: .cursorImage(hash: hash, hotspot: job.snapshot.hotspot / size, size: size, kind: job.kind))
        // Under the lock, so nothing is appended once `stop()` has cleared the log.
        state.withLock { s in
            guard s.log === job.log, s.generation == job.generation else { return }
            job.log.append(event)
        }
    }

    /// Returns once everything sent to the writer before it is done.
    func writesDone() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            writer.async { done.resume() }
        }
    }

    /// Whether `folder` (`cursors/`) is a folder and has a regular file called `name`, following no symlink in either.
    private static func isRegularFile(_ name: String, in folder: URL) -> Bool {
        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return false }
        defer { close(directory) }
        var info = stat()
        return fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// Writes `png` at `url` with `DurableFile.writeNew`, making `cursors/` if the take has none (never the take's
    /// folder). Whether it wrote it: `false` if something was there already, which is kept, since the name is the
    /// content. A `cursors` that is not a folder (a symlink, which is never followed) throws `POSIXError(.ENOTDIR)`.
    private static func write(_ png: Data, to url: URL) throws -> Bool {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try DurableFile.syncDirectory(folder.deletingLastPathComponent())
        } catch CocoaError.fileWriteFileExists {
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        }
        do {
            try DurableFile.writeNew(png, to: url)
            return true
        } catch POSIXError.EEXIST {
            return false
        }
    }

    /// `image` as a PNG.
    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw POSIXError(.EIO) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw POSIXError(.EIO) }
        return data as Data
    }
}
