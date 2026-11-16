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

@Suite struct LibraryWatcherTests {
    @Test func finderChangesArriveWithinASecond() async throws {
        try await withTemporaryDirectory { dir in
            let folder = dir.appending(path: "Projects", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let notices = Notices()
            let watcher = LibraryWatcher(folder: folder, recordingPackage: { nil }, onPackages: notices.append)
            watcher.start()
            defer { watcher.stop() }
            // FSEvents watches from when the stream starts: give it a moment.
            try await Task.sleep(for: .milliseconds(500))
            let clock = ContinuousClock()

            // Made, as a recording makes one: its folder, then a file inside.
            let made = folder.appending(path: "Demo.toma", directoryHint: .isDirectory)
            var start = clock.now
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false)
            try Data("{}".utf8).write(to: made.appending(path: "manifest.json"))
            #expect(await eventually(timeout: .seconds(3)) { notices.first(naming: made) != nil })
            #expect(start.duration(to: try #require(notices.first(naming: made))) <= .seconds(1))

            // Renamed by another app: the old path and the new one.
            let renamed = folder.appending(path: "Renamed.toma", directoryHint: .isDirectory)
            start = clock.now
            let before = notices.all.count
            try FileManager.default.moveItem(at: made, to: renamed)
            #expect(await eventually(timeout: .seconds(3)) { notices.first(naming: renamed) != nil })
            #expect(start.duration(to: try #require(notices.first(naming: renamed))) <= .seconds(1))
            #expect(notices.all.dropFirst(before).contains { $0.packages.contains { $0.path == made.path } })

            // Deleted.
            start = clock.now
            let count = notices.naming(renamed).count
            try FileManager.default.removeItem(at: renamed)
            #expect(await eventually(timeout: .seconds(3)) { notices.naming(renamed).count > count })
            #expect(start.duration(to: try #require(notices.naming(renamed).last).at) <= .seconds(1))

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
            try await Task.sleep(for: .milliseconds(500))
            let named = Set(notices.all.flatMap(\.packages).map(\.path))
            #expect(!named.contains { $0.contains("/.hidden") || $0.hasSuffix("notes.txt") || $0.contains("/takes") })
            #expect(named.allSatisfy { $0.hasPrefix(folder.path + "/") })
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
            try await Task.sleep(for: .milliseconds(500))
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
            #expect(start.duration(to: try #require(notices.first(naming: other))) <= .seconds(2))
            #expect(notices.all.allSatisfy { notice in Set(notice.packages.map(\.path)).count == notice.packages.count })

            // Once the take ends, its package is a package like any other.
            recording.set(nil)
            let count = notices.naming(recorded).count
            let ended = clock.now
            try Data("{}".utf8).write(to: recorded.appending(path: "manifest.json"))
            #expect(await eventually(timeout: .seconds(3)) { notices.naming(recorded).count > count })
            #expect(ended.duration(to: try #require(notices.naming(recorded).last).at) <= .seconds(1))
        }
    }
}
