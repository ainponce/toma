// SPDX-License-Identifier: GPL-3.0-or-later
import CoreServices
import Dispatch
import Foundation
import ProjectFormat
import Synchronization

/// Tells which packages of the projects folder changed on disk (design §6.8, "FSEvents"), so the library looks at them
/// again (`LibraryScanner.look(at:)`): an FSEvents stream over `folder`, with an event per file, every `latency`
/// seconds. Each path is taken to the package that holds it (`<folder>/…/X.toma`); a folder outside any package is told
/// only when it was made, removed or renamed (its projects moved with it), and the folder itself when events were lost
/// or it changed. Hidden items, and files outside packages, are not told. The package being recorded
/// (`recordingPackage`) is told at most once every 2 s however often it changes.
///
/// The stream asks for nothing (no privacy prompt), and is made only for a folder on a local internal volume: a
/// projects folder anywhere else is not looked at by itself (design §6.5), so it has no stream. `onPackages` is called
/// on the watcher's own queue, never with the same package twice in a call, and never after `stop()` returns.
public final class LibraryWatcher: Sendable {
    /// The least time between two notices of the package being recorded.
    static let recordingInterval: Duration = .seconds(2)

    private let handler: Handler
    private let latency: Double
    private let stream = Mutex<Stream?>(nil)

    /// An `FSEventStreamRef`, touched only on the handler's queue.
    private struct Stream: @unchecked Sendable {
        let reference: FSEventStreamRef
    }

    public init(
        folder: URL, latency: Double = 0.3, recordingPackage: @escaping @Sendable () -> URL?,
        onPackages: @escaping @Sendable ([URL]) -> Void
    ) {
        handler = Handler(folder: folder, recordingPackage: recordingPackage, onPackages: onPackages)
        self.latency = latency
    }

    deinit {
        stop()
    }

    /// Starts watching, on the watcher's queue (it returns at once); nothing if it watches already, or if the folder is
    /// not on a local internal volume.
    public func start() {
        handler.queue.async { [self] in
            stream.withLock { stream in
                guard stream == nil, handler.isOnALocalInternalVolume() else { return }
                handler.prepare()
                var context = FSEventStreamContext(
                    version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
                    retain: { info in
                        guard let info else { return nil }
                        _ = Unmanaged<Handler>.fromOpaque(info).retain()
                        return info
                    },
                    release: { info in
                        guard let info else { return }
                        Unmanaged<Handler>.fromOpaque(info).release()
                    }, copyDescription: nil)
                let flags = FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
                        | kFSEventStreamCreateFlagNoDefer)
                guard
                    let reference = FSEventStreamCreate(
                        kCFAllocatorDefault, watcherCallback, &context, [handler.folder.path] as CFArray,
                        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
                else { return }
                FSEventStreamSetDispatchQueue(reference, handler.queue)
                guard FSEventStreamStart(reference) else {
                    FSEventStreamInvalidate(reference)
                    FSEventStreamRelease(reference)
                    return
                }
                stream = Stream(reference: reference)
            }
        }
    }

    /// Stops watching: once it returns, `onPackages` is not called again (a notice of the package being recorded that
    /// was waiting is dropped). It may be called from `onPackages`.
    public func stop() {
        let work = { [self] in
            stream.withLock { stream in
                if let reference = stream?.reference {
                    FSEventStreamStop(reference)
                    FSEventStreamInvalidate(reference)
                    FSEventStreamRelease(reference)
                }
                stream = nil
            }
            handler.stop()
        }
        if DispatchQueue.getSpecific(key: Handler.queueKey) == ObjectIdentifier(handler) {
            work()
        } else {
            handler.queue.sync(execute: work)
        }
    }
}

/// The events of the stream, on its queue: the stream keeps it alive while it lasts.
private final class Handler: Sendable {
    /// Which handler's queue the code runs on, if any.
    static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    let folder: URL
    let queue = DispatchQueue(label: "dev.toma.Toma.LibraryWatcher", qos: .utility)
    private let recordingPackage: @Sendable () -> URL?
    private let onPackages: @Sendable ([URL]) -> Void
    /// The folder's path components as given and, if it differs, as the disk names it (FSEvents gives real paths:
    /// `/private/var/…` for `/var/…`).
    private let roots = Mutex<[[String]]>([])
    private let coalescing = Mutex(Coalescing())

    private struct Coalescing {
        var lastNotice: ContinuousClock.Instant?
        /// The package being recorded, changed since its last notice.
        var pending: URL?
        var isScheduled = false
        var isStopped = true
        /// Which start a scheduled notice belongs to.
        var generation = 0
    }

    init(folder: URL, recordingPackage: @escaping @Sendable () -> URL?, onPackages: @escaping @Sendable ([URL]) -> Void) {
        self.folder = URL(filePath: folder.standardizedFileURL.path, directoryHint: .isDirectory)
        self.recordingPackage = recordingPackage
        self.onPackages = onPackages
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    }

    /// Whether the folder (or, if it is not there yet, the nearest folder above it) is on a local internal volume.
    func isOnALocalInternalVolume() -> Bool {
        var url = folder
        while true {
            if let volume = try? SystemFileSystem().volume(of: url) { return volume.isLookedAtAlone }
            guard url.path != "/" else { return false }
            url = url.deletingLastPathComponent()
        }
    }

    /// Before a start: where the folder is on disk, and notices allowed again.
    func prepare() {
        let given = folder.standardizedFileURL.pathComponents
        var existing = folder.standardizedFileURL
        var rest: [String] = []
        var real: [String]?
        while real == nil {
            if let resolved = realpath(existing.path, nil) {
                real = URL(filePath: String(cString: resolved)).pathComponents + rest
                free(resolved)
            } else if existing.path == "/" {
                break
            } else {
                rest.insert(existing.lastPathComponent, at: 0)
                existing = existing.deletingLastPathComponent()
            }
        }
        roots.withLock { $0 = [given] + (real.map { $0 == given ? [] : [$0] } ?? []) }
        coalescing.withLock { coalescing in
            coalescing.isStopped = false
            coalescing.generation += 1
        }
    }

    func stop() {
        coalescing.withLock { coalescing in
            coalescing.isStopped = true
            coalescing.isScheduled = false
            coalescing.pending = nil
            coalescing.generation += 1
        }
    }

    /// One callback of the stream.
    func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard !coalescing.withLock({ $0.isStopped }) else { return }
        let recording = recordingPackage().map { $0.standardizedFileURL.path }
        var packages: [URL] = []
        var seen: Set<String> = []
        var recorded: URL?
        for (path, flags) in zip(paths, flags) {
            guard let url = package(at: path, flags: flags) else { continue }
            let path = url.standardizedFileURL.path
            if path == recording {
                recorded = url
            } else if seen.insert(path).inserted {
                packages.append(url)
            }
        }
        if !packages.isEmpty { onPackages(packages) }
        if let recorded { coalesce(recorded) }
    }

    /// What the event at `path` tells: the package that holds it, a folder made, removed or renamed, the folder itself
    /// when events were lost or it changed; `nil` for the rest.
    private func package(at path: String, flags: FSEventStreamEventFlags) -> URL? {
        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        let rescan = has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagRootChanged)
        let components = URL(filePath: path).standardizedFileURL.pathComponents
        guard let root = roots.withLock({ $0.first { components.starts(with: $0) } }) else {
            return has(kFSEventStreamEventFlagRootChanged) ? folder : nil
        }
        let relative = Array(components.dropFirst(root.count))
        guard !relative.isEmpty else { return rescan ? folder : nil }
        if let index = relative.firstIndex(where: PackageNames.isPackage) {
            let named = relative[...index]
            guard !named.contains(where: PackageNames.isHidden) else { return nil }
            return url(of: named)
        }
        guard !relative.contains(where: PackageNames.isHidden) else { return nil }
        let changed = has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved)
            || has(kFSEventStreamEventFlagItemRenamed)
        guard rescan || (has(kFSEventStreamEventFlagItemIsDir) && changed) else { return nil }
        return url(of: relative[...])
    }

    private func url(of relative: ArraySlice<String>) -> URL {
        relative.reduce(folder) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    /// Tells `url`, the package being recorded, now if its last notice was `recordingInterval` ago, or else once that
    /// time is up.
    private func coalesce(_ url: URL) {
        enum Action {
            case now
            case later(Duration, generation: Int)
            case nothing
        }
        let now = ContinuousClock.now
        let action = coalescing.withLock { coalescing -> Action in
            guard !coalescing.isScheduled else {
                coalescing.pending = url
                return .nothing
            }
            if let last = coalescing.lastNotice, last.duration(to: now) < LibraryWatcher.recordingInterval {
                coalescing.pending = url
                coalescing.isScheduled = true
                return .later(LibraryWatcher.recordingInterval - last.duration(to: now), generation: coalescing.generation)
            }
            coalescing.lastNotice = now
            return .now
        }
        switch action {
        case .now:
            onPackages([url])
        case .later(let delay, let generation):
            queue.asyncAfter(deadline: .now() + delay.dispatchInterval) { self.notifyPending(generation) }
        case .nothing:
            break
        }
    }

    private func notifyPending(_ generation: Int) {
        let url = coalescing.withLock { coalescing -> URL? in
            guard coalescing.generation == generation, !coalescing.isStopped else { return nil }
            coalescing.isScheduled = false
            defer { coalescing.pending = nil }
            if coalescing.pending != nil { coalescing.lastNotice = .now }
            return coalescing.pending
        }
        if let url { onPackages([url]) }
    }
}

/// The stream's callback: paths as `CFString`s (`kFSEventStreamCreateFlagUseCFTypes`).
private func watcherCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int, _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>, _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
    handler.handle(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
}
