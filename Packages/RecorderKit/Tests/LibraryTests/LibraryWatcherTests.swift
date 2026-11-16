// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Library
import ProjectFormat
import RecorderKitTestSupport

/// Every notice a watcher gave, with when it arrived.
private final class Notices: Sendable {
    struct Notice: Sendable {
        var packages: [URL]
        var at: ContinuousClock.Instant
    }

    private let log = Mutex<[Notice]>([])

    func append(_ packages: [URL]) {
        log.withLock { $0.append(Notice(packages: packages, at: .now)) }
    }

    var all: [Notice] { log.withLock { $0 } }

    /// When the first notice that names `url` arrived.
    func first(naming url: URL) -> ContinuousClock.Instant? {
        all.first { notice in notice.packages.contains { $0.path == url.path } }?.at
    }

    /// The notices that name `url`.
    func naming(_ url: URL) -> [Notice] {
        all.filter { notice in notice.packages.contains { $0.path == url.path } }
    }
}

/// A URL the test sets and the watcher reads.
private final class RecordingPackage: Sendable {
    private let url = Mutex<URL?>(nil)

    var current: URL? { url.withLock { $0 } }

    func set(_ value: URL?) {
        url.withLock { $0 = value }
    }
}

/// Waits until `notices` names a change made in `folder`: the watcher's stream has started (FSEvents tells only what
/// happens after that). It writes in `<folder>/Ready.toma/` until a notice names that package.
private func ready(_ folder: URL, _ notices: Notices) async throws -> Bool {
    let package = folder.appending(path: "Ready.toma", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    for attempt in 0..<40 {
        try Data("\(attempt)".utf8).write(to: package.appending(path: "ready", directoryHint: .notDirectory))
        if await eventually(timeout: .milliseconds(250), { notices.first(naming: package) != nil }) { return true }
    }
    return false
}

@Suite struct LibraryWatcherTests {
    @Test func finderChangesArriveWithinASecond() async throws {
        try await withTemporaryDirectory { dir in
            let folder = dir.appending(path: "Projects", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let notices = Notices()
            let watcher = LibraryWatcher(folder: folder, recordingPackage: { nil }, onPackages: notices.append)
            watcher.start()
            defer { watcher.stop() }
            #expect(try await ready(folder, notices))
            let clock = ContinuousClock()

            // Made, as a recording makes one: its folder, then a file inside.
            let made = folder.appending(path: "Demo.toma", directoryHint: .isDirectory)
            var start = clock.now
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false)
            try Data("{}".utf8).write(to: made.appending(path: "manifest.json"))
            #expect(await eventually(timeout: .seconds(3)) { notices.first(naming: made) != nil })
            #expect(start.duration(to: try #require(notices.first(naming: made))) <= soon(.seconds(1)))

            // Renamed by another app: the old path and the new one.
            let renamed = folder.appending(path: "Renamed.toma", directoryHint: .isDirectory)
            start = clock.now
            let before = notices.all.count
            try FileManager.default.moveItem(at: made, to: renamed)
            #expect(await eventually(timeout: .seconds(3)) { notices.first(naming: renamed) != nil })
            #expect(start.duration(to: try #require(notices.first(naming: renamed))) <= soon(.seconds(1)))
            #expect(notices.all.dropFirst(before).contains { $0.packages.contains { $0.path == made.path } })

            // Deleted.
            start = clock.now
            let count = notices.naming(renamed).count
            try FileManager.default.removeItem(at: renamed)
            #expect(await eventually(timeout: .seconds(3)) { notices.naming(renamed).count > count })
            #expect(start.duration(to: try #require(notices.naming(renamed).last).at) <= soon(.seconds(1)))

            // A file inside a package names the package; a subfolder renamed names the folders; hidden ones and loose
            // files name nothing.
            let sub = folder.appending(path: "Clientes", directoryHint: .isDirectory)
            let inside = sub.appending(path: "Inside.toma", directoryHint: .isDirectory)
            let take = inside.appending(path: "takes/take-001", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: take, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: inside.appending(path: "takes/take-001/events.jsonl"))
            let ghost = folder.appending(path: ".hidden/Ghost.toma", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: ghost, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appending(path: "notes.txt"))
            #expect(await eventually(timeout: .seconds(3)) { notices.first(naming: inside) != nil })
            let clients = folder.appending(path: "Clients", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: sub, to: clients)
            #expect(await eventually(timeout: .seconds(3)) { notices.first(naming: clients) != nil })
            #expect(notices.first(naming: sub) != nil)
            // Once a last change reaches it, every one before it has.
            let last = folder.appending(path: "Last.toma", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: last, withIntermediateDirectories: false)
            #expect(await eventually(timeout: .seconds(3)) { notices.first(naming: last) != nil })
            let named = Set(notices.all.flatMap(\.packages).map(\.path))
            #expect(!named.contains { $0.contains("/.hidden") || $0.hasSuffix("notes.txt") || $0.contains("/takes") })
            #expect(named.allSatisfy { $0.hasPrefix(folder.path + "/") })
        }
    }

    @Test func watchesOnlyALocalInternalFolder() async throws {
        try await withTemporaryDirectory { dir in
            let folder = dir.appending(path: "Projects", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            // The same folder, said to be on a removable disk to one watcher and on the Mac's disk to another.
            let removable = CountingFileSystem(
                base: DelayingFileSystem(volumes: [
                    .init(
                        root: folder,
                        info: DelayingFileSystem.volumeInfo(uuid: "USB", name: "USB", isInternal: false, isRemovable: true))
                ]))
            let local = DelayingFileSystem(volumes: [
                .init(root: folder, info: DelayingFileSystem.volumeInfo(uuid: "DISK", name: "Macintosh HD"))
            ])
            let refused = Notices()
            let watched = Notices()
            let outside = LibraryWatcher(
                folder: folder, recordingPackage: { nil }, onPackages: refused.append, fileSystem: removable)
            let inside = LibraryWatcher(folder: folder, recordingPackage: { nil }, onPackages: watched.append, fileSystem: local)
            outside.start()
            inside.start()
            defer {
                outside.stop()
                inside.stop()
            }
            #expect(try await ready(folder, watched))

            // Two changes, one after the other: once the second reaches the watcher on the Mac's disk, the first would
            // have reached the other one, had it a stream.
            for name in ["One.toma", "Two.toma"] {
                let package = folder.appending(path: name, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
                #expect(await eventually(timeout: .seconds(3)) { watched.first(naming: package) != nil })
            }
            #expect(refused.all.isEmpty)
            // Once `stop()` returns, what `start()` did on the watcher's queue is done. It asked where the folder is, and
            // nothing else.
            outside.stop()
            #expect(removable.accesses.map(\.url.path) == [folder.path])
            #expect(removable.accesses.map(\.operation) == [.volume])
        }
    }

    @Test func recordingPackageIsCoalesced() async throws {
        try await withTemporaryDirectory { dir in
            let folder = dir.appending(path: "Projects", directoryHint: .isDirectory)
            let recorded = folder.appending(path: "Recording.toma", directoryHint: .isDirectory)
            let other = folder.appending(path: "Other.toma", directoryHint: .isDirectory)
            let take = recorded.appending(path: "takes/take-001", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: take, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let recording = RecordingPackage()
            recording.set(recorded)
            let notices = Notices()
            let watcher = LibraryWatcher(folder: folder, recordingPackage: { recording.current }, onPackages: notices.append)
            watcher.start()
            defer { watcher.stop() }
            #expect(try await ready(folder, notices))
            let clock = ContinuousClock()

            // 100 writes in a second, as the recorder writes its segments and events.
            let start = clock.now
            let events = take.appending(path: "events.jsonl")
            try Data().write(to: events)
            let handle = try FileHandle(forWritingTo: events)
            for number in 0..<100 {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("{\"n\":\(number)}\n".utf8))
                try handle.synchronize()
                if number == 50 { try Data("{}".utf8).write(to: other.appending(path: "manifest.json")) }
                try await Task.sleep(for: .milliseconds(10))
            }
            try handle.close()
            let writing = start.duration(to: clock.now)
            try await Task.sleep(for: .seconds(3.5))

            let times = notices.naming(recorded).map(\.at)
            #expect(!times.isEmpty)
            for (earlier, later) in zip(times, times.dropFirst()) {
                #expect(earlier.duration(to: later) >= .seconds(1.9), "\(times.map { start.duration(to: $0) })")
            }
            // Writing took about a second: at most one at its start, one 2 s later and one after the end.
            let elapsed = start.duration(to: clock.now)
            #expect(
                times.count <= Int((elapsed / .seconds(2)).rounded(.up)) + 1, "\(times.count) in \(elapsed), writing \(writing)")
            // Another package written meanwhile is not held back.
            #expect(start.duration(to: try #require(notices.first(naming: other))) <= soon(.seconds(2)))
            #expect(notices.all.allSatisfy { notice in Set(notice.packages.map(\.path)).count == notice.packages.count })

            // Once the take ends, its package is a package like any other.
            recording.set(nil)
            let count = notices.naming(recorded).count
            let ended = clock.now
            try Data("{}".utf8).write(to: recorded.appending(path: "manifest.json"))
            #expect(await eventually(timeout: .seconds(3)) { notices.naming(recorded).count > count })
            #expect(ended.duration(to: try #require(notices.naming(recorded).last).at) <= soon(.seconds(1)))
        }
    }
}
