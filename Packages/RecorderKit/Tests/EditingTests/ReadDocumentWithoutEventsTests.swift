// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
import Editing
import ProjectFormat

// Task 31b: the read-only resolution reads the take's event log only for a document that comes from it, so the library
// reads an edited project without decoding its `events.jsonl`.

/// The projects the read meets.
private enum Kind: CaseIterable {
    case v1, v2
    /// Of version 3, never opened in an editor: a `NewDocument`.
    case neverOpened
    /// Upgraded to version 3 from version 2 and never edited since: the legacy document.
    case upgradedNeverEdited
    /// Edited here: `edit.json` at the last line of the log.
    case edited
    /// Edited twice, with the `edit.json` of the first time: the log goes past it.
    case logAheadOfSnapshot
    case logWithoutSnapshot
    case snapshotWithoutLog
    /// A project of 1b, still of `documentVersion` 1 on disk.
    case from1b
    /// A line in the middle of the log does not decode, and there is no `edit.json`: the lines before it are applied.
    case damagedLog
    /// The log's first line does not decode, beside an `edit.json`.
    case damagedLogWithSnapshot
    /// The log's first line does not decode, and there is no `edit.json`: a `NewDocument`, as without a log.
    case damagedLogAlone
    /// An `edit.json` no render could draw, and no log: it is shown made drawable.
    case undrawableSnapshot

    /// The document comes from the take's events: the legacy one or a `NewDocument`.
    var comesFromEvents: Bool { [.v1, .v2, .neverOpened, .upgradedNeverEdited, .damagedLogAlone].contains(self) }

    var diskVersion: Int { self == .from1b ? 1 : EditDocument.currentVersion }
}

/// `LoadedProject.takeEvents`, counting its calls.
private final class CountingReader: Sendable {
    private let count = Mutex(0)

    var reads: Int { count.withLock { $0 } }

    var read: LoadedProject.EventsReader {
        { package, take in
            self.count.withLock { $0 += 1 }
            return try LoadedProject.takeEvents(package, take)
        }
    }
}

private enum Fixture {
    static let app = AppInfo(name: "Toma", version: "0.3.0")
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    /// `c-00000001`, `c-00000002`… from 1 for each new instance.
    final class IDs: Sendable {
        private let count = Mutex(0)

        func make(_ prefix: String) -> String {
            count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            }
        }
    }

    /// A context whose IDs start again at 1, so two reads of a new project name its clips alike.
    static func context(_ dir: URL) -> EditContext {
        let ids = IDs()
        return EditContext(
            app: app, cachesRoot: dir.appending(path: "Caches"), defaultStyle: .toma,
            now: { Date(timeIntervalSince1970: 1_794_773_523) }, makeID: { ids.make($0) })
    }

    /// A take of 1 s of one display with the cursor moving over it, in a new package `<name>.toma` of `formatVersion`.
    @concurrent static func package(
        in dir: URL, name: String, formatVersion: Int = 3, upgradedFrom: Int? = nil
    ) async throws -> URL {
        let builder = try TakeBuilder(in: dir, name: name, formatVersion: formatVersion, upgradedFrom: upgradedFrom)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        try builder.addEvents((0..<20).map { i in
            InputEvent(t: base.adding(seconds: Double(i) / 20), kind: .cursor(x: 100 + Double(i) * 10, y: 100))
        })
        return try builder.write().package.url
    }

    /// A take of two displays side by side, in a new package `<name>.toma` of `formatVersion`: the first recorded 1 s,
    /// the second, the one under the pointer, 0.5 s from 0.2 s on. Which one shows changes the output's length.
    @concurrent static func twoScreens(in dir: URL, name: String, formatVersion: Int) async throws -> URL {
        let builder = try TakeBuilder(in: dir, name: name, formatVersion: formatVersion)
        for (index, x) in [0.0, 640].enumerated() {
            let frame = Rect(x: x, y: 0, width: 640, height: 360)
            let display = UInt32(index + 1)
            try await builder.addVideoTrack(
                id: "display-\(display)",
                source: TrackSource(name: "Synthetic Display", displayID: display, globalFrame: frame, pixelScale: 1),
                segments: [
                    VideoSegmentSpec(
                        start: base.adding(seconds: 0.2 * Double(index)), seconds: index == 0 ? 1 : 0.5,
                        framesPerSecond: 10)
                ])
            let geometry = InputEvent.Kind.displayGeometry(displayID: display, frame: frame, scale: 1)
            try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: geometry)])
        }
        try builder.addEvents([InputEvent(t: base.adding(seconds: 0.25), kind: .cursor(x: 900, y: 100))])
        return try builder.write().package.url
    }

    /// Opens the project, sets its padding and closes it, which writes `edit.json` at the last line.
    @MainActor static func edit(_ url: URL, padding: Double, in dir: URL) async throws {
        let session = try await EditSession.open(url, take: nil, context: context(dir))
        let change = try #require(session.document.setChange("/style/padding", padding))
        #expect(session.perform(EditStep(label: .padding, target: "/style/padding", changes: [change])) == .applied)
        await session.close()
    }

    static func lines(_ url: URL) throws -> [String] {
        String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func write(_ lines: [String], to url: URL) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    }

    /// A package of `kind` in a folder of its own inside `dir`.
    @MainActor static func make(_ kind: Kind, in dir: URL) async throws -> URL {
        let folder = dir.appending(path: "\(kind)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(kind)"
        switch kind {
        case .v1: return try await package(in: folder, name: name, formatVersion: 1)
        case .v2: return try await package(in: folder, name: name, formatVersion: 2)
        case .neverOpened: return try await package(in: folder, name: name)
        case .upgradedNeverEdited: return try await package(in: folder, name: name, upgradedFrom: 2)
        case .from1b: return try await DocumentV1Fixture.make(in: folder, steps: 3, snapshotAt: 1)
        default: break
        }
        let url = try await package(in: folder, name: name)
        let files = ProjectPackage(url: url)
        try await edit(url, padding: 0.1, in: dir)
        switch kind {
        case .logAheadOfSnapshot:
            let first = try Data(contentsOf: files.editURL)
            try await edit(url, padding: 0.2, in: dir)
            try first.write(to: files.editURL)
        case .logWithoutSnapshot:
            try FileManager.default.removeItem(at: files.editURL)
        case .snapshotWithoutLog:
            try FileManager.default.removeItem(at: files.editLogURL)
        case .damagedLog:
            try await edit(url, padding: 0.2, in: dir)
            try FileManager.default.removeItem(at: files.editURL)
            var lines = try lines(files.editLogURL)
            // After the `create`, the two `migrate`s of the first edit and its step.
            lines.insert("{ not a line", at: 4)
            try write(lines, to: files.editLogURL)
        case .damagedLogWithSnapshot, .damagedLogAlone:
            if kind == .damagedLogAlone { try FileManager.default.removeItem(at: files.editURL) }
            var lines = try lines(files.editLogURL)
            lines[0] = "{ not a line"
            try write(lines, to: files.editLogURL)
        case .undrawableSnapshot:
            try FileManager.default.removeItem(at: files.editLogURL)
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: files.editURL)) as? [String: Any])
            json["frameRate"] = 0
            try JSONSerialization.data(withJSONObject: json).write(to: files.editURL)
        default:
            break
        }
        return url
    }

    /// The document `EditSession.open` shows of the project at `url` while another app holds its lock: read-only,
    /// from the project loaded with its events, writing nothing.
    @MainActor static func shownReadOnly(_ url: URL, in dir: URL) async throws -> EditDocument {
        let lock = try RecordingLock.acquire(at: ProjectPackage(url: url).editLockURL, info: .current(now: Date()))
        defer { lock.release() }
        let session = try await EditSession.open(url, take: nil, context: context(dir))
        #expect(session.access == .readOnly(.openElsewhere))
        let document = session.document
        await session.close()
        return document
    }

    /// Puts a FIFO where the take's event log is: opened, it would be refused (`EFTYPE`).
    static func replaceEventsWithAFifo(_ url: URL) throws {
        let events = ProjectPackage(url: url).eventsURL(take: try LoadedProject.load(url).take.id)
        try FileManager.default.removeItem(at: events)
        #expect(mkfifo(events.path, 0o644) == 0)
    }
}

@MainActor @Test func editedProjectsAreReadWithoutTheirEventLog() async throws {
    try await withTemporaryDirectory { dir in
        for kind in Kind.allCases where !kind.comesFromEvents {
            let url = try await Fixture.make(kind, in: dir)
            let reader = CountingReader()
            let (project, document, diskVersion) = try EditSession.readDocumentWithDiskVersion(
                url, take: nil, context: Fixture.context(dir), readingEvents: reader.read)
            #expect(reader.reads == 0, "\(kind)")
            // Asked for, they are the take's whole event log, read once.
            let events = try LoadedProject.load(url).events
            #expect(!events.isEmpty, "\(kind)")
            #expect(project.events == events, "\(kind)")
            #expect(project.events == events, "\(kind)")
            #expect(reader.reads == 1, "\(kind)")
            // Copies asking for them at the same time, from several threads: read once, by one of them.
            let together = CountingReader()
            let (shared, _, _) = try EditSession.readDocumentWithDiskVersion(
                url, take: nil, context: Fixture.context(dir), readingEvents: together.read)
            let all = await withTaskGroup(of: [InputEvent].self) { group in
                for _ in 0..<8 { group.addTask { shared.events } }
                var all: [[InputEvent]] = []
                for await events in group { all.append(events) }
                return all
            }
            #expect(all.count == 8 && all.allSatisfy { $0 == events }, "\(kind)")
            #expect(together.reads == 1, "\(kind)")

            // `readDocument` comes with them read: what it gives keeps them after the file cannot be read any more.
            let file = ProjectPackage(url: url).eventsURL(take: project.take.id)
            let (whole, plain) = try EditSession.readDocument(url, take: nil, context: Fixture.context(dir))
            #expect(plain == document, "\(kind)")
            #expect(chmod(file.path, 0) == 0)
            #expect(whole.events == events, "\(kind)")

            // The library's read does not read it: one it cannot read is told only when the events are asked for, which
            // then gives none. `readDocument`, whose callers draw from them, throws it, as before.
            let (unreadable, same, sameVersion) = try EditSession.readDocumentWithDiskVersion(
                url, take: nil, context: Fixture.context(dir))
            #expect(same == document && sameVersion == diskVersion, "\(kind)")
            #expect(throws: POSIXError(.EACCES), "\(kind)") { try unreadable.readEvents() }
            #expect(unreadable.events.isEmpty, "\(kind)")
            #expect(throws: POSIXError(.EACCES), "\(kind)") {
                try EditSession.readDocument(url, take: nil, context: Fixture.context(dir))
            }
            #expect(chmod(file.path, 0o644) == 0)

            // An event log that was there when the project was read and is gone when its events are asked for (the
            // package renamed meanwhile) is an error, never a take without one.
            let (moved, _, _) = try EditSession.readDocumentWithDiskVersion(
                url, take: nil, context: Fixture.context(dir))
            let elsewhere = url.deletingLastPathComponent().appending(path: "moved.toma", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: url, to: elsewhere)
            #expect(throws: POSIXError(.ENOENT), "\(kind)") { try moved.readEvents() }
            #expect(moved.events.isEmpty, "\(kind)")
            try FileManager.default.moveItem(at: elsewhere, to: url)

            // Asked for later, the event log is read as `load` reads it: a FIFO put there since is refused at once,
            // never waited on.
            let (unread, _, _) = try EditSession.readDocumentWithDiskVersion(url, take: nil, context: Fixture.context(dir))
            let outside = dir.appending(path: "\(kind)-events.jsonl")
            try FileManager.default.copyItem(at: file, to: outside)
            try Fixture.replaceEventsWithAFifo(url)
            #expect(throws: POSIXError(.EFTYPE), "\(kind)") { try unread.readEvents() }
            #expect(unread.events.isEmpty, "\(kind)")
            // One there before is refused by the read itself, as before, and a link too: looked at, never opened.
            #expect(throws: POSIXError(.EFTYPE), "\(kind)") {
                try EditSession.readDocumentWithDiskVersion(url, take: nil, context: Fixture.context(dir))
            }
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            #expect(throws: POSIXError(.ELOOP), "\(kind)") {
                try EditSession.readDocumentWithDiskVersion(url, take: nil, context: Fixture.context(dir))
            }
        }
    }
}

@MainActor @Test func legacyAndNewProjectsReadTheirEventLogOnce() async throws {
    try await withTemporaryDirectory { dir in
        for kind in Kind.allCases where kind.comesFromEvents {
            let url = try await Fixture.make(kind, in: dir)
            let reader = CountingReader()
            let (project, _, _) = try EditSession.readDocumentWithDiskVersion(
                url, take: nil, context: Fixture.context(dir), readingEvents: reader.read)
            #expect(reader.reads == 1, "\(kind)")
            let events = try LoadedProject.load(url).events
            #expect(!events.isEmpty, "\(kind)")
            #expect(project.events == events, "\(kind)")
            #expect(reader.reads == 1, "\(kind)")

            // Their document cannot be had without it: an event log that cannot be read is an error, as before.
            try Fixture.replaceEventsWithAFifo(url)
            #expect(throws: POSIXError(.EFTYPE), "\(kind)") {
                try EditSession.readDocumentWithDiskVersion(url, take: nil, context: Fixture.context(dir))
            }
        }
    }
}

@MainActor @Test func answersAreTheSameForEveryKindOfProject() async throws {
    try await withTemporaryDirectory { dir in
        for kind in Kind.allCases {
            let url = try await Fixture.make(kind, in: dir)
            let before = try treeHash(url)
            let (project, document, diskVersion) = try EditSession.readDocumentWithDiskVersion(
                url, take: nil, context: Fixture.context(dir))
            let (plainProject, plain) = try EditSession.readDocument(url, take: nil, context: Fixture.context(dir))
            #expect(try treeHash(url) == before, "\(kind)")
            #expect(diskVersion == kind.diskVersion, "\(kind)")
            #expect(plain == document, "\(kind)")

            // The project is the one `load` gives, events and all.
            let loaded = try LoadedProject.load(url)
            for read in [project, plainProject] {
                #expect(read.package == loaded.package, "\(kind)")
                #expect(read.manifest == loaded.manifest, "\(kind)")
                #expect(read.take == loaded.take, "\(kind)")
                #expect(read.events == loaded.events, "\(kind)")
            }
            // The document is the one the editor shows read-only, from the project loaded with its events.
            #expect(document == (try await Fixture.shownReadOnly(url, in: dir)), "\(kind)")
        }
    }
}

@MainActor @Test func outlinesAreThoseOfTheFullRead() async throws {
    try await withTemporaryDirectory { dir in
        var cases: [(name: String, url: URL, decodes: Bool)] = []
        for kind in Kind.allCases {
            // Told without the events: the legacy and new documents of one screen; read as before: the rest.
            let derived = [Kind.v1, .v2, .neverOpened, .upgradedNeverEdited].contains(kind)
            cases.append(("\(kind)", try await Fixture.make(kind, in: dir), kind.comesFromEvents && !derived))
        }
        let extra = dir.appending(path: "extra", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        // Two screens: which one shows depends on the first pointer position, in the events.
        for version in [2, 3] {
            let url = try await Fixture.twoScreens(in: extra, name: "two-\(version)", formatVersion: version)
            cases.append(("two screens v\(version)", url, true))
        }
        // A new document of a take paused from 0.4 s to 0.6 s: the pause is cut.
        let paused = try await Fixture.package(in: extra, name: "paused")
        let log = ProjectPackage(url: paused).eventsURL(take: try LoadedProject.load(paused).take.id)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        for event in [
            InputEvent(t: Fixture.base.adding(seconds: 0.4), kind: .paused(reason: "user")),
            InputEvent(t: Fixture.base.adding(seconds: 0.6), kind: .resumed),
        ] {
            try handle.write(contentsOf: Data((try event.jsonLine() + "\n").utf8))
        }
        try handle.close()
        cases.append(("paused", paused, true))
        // A new document of a take without an event log: nothing to decode.
        let silent = try await Fixture.package(in: extra, name: "silent")
        let silentTake = try LoadedProject.load(silent).take.id
        try FileManager.default.removeItem(at: ProjectPackage(url: silent).eventsURL(take: silentTake))
        cases.append(("no event log", silent, false))

        for (name, url, decodes) in cases {
            let before = try treeHash(url)
            let reader = CountingReader()
            let (project, outline) = try EditSession.readOutline(
                url, take: nil, context: Fixture.context(dir), readingEvents: reader.read)
            #expect(reader.reads == (decodes ? 1 : 0), "\(name)")
            let (full, document, diskVersion) = try EditSession.readDocumentWithDiskVersion(
                url, take: nil, context: Fixture.context(dir))
            #expect(outline == DocumentOutline(document, diskVersion: diskVersion), "\(name)")
            #expect(project.manifest == full.manifest && project.take == full.take, "\(name)")
            #expect(try treeHash(url) == before, "\(name)")
        }
        // Where the outline is told from the events, the take alone would tell it wrong.
        for (name, url, _) in cases where name.hasPrefix("two screens") || name == "paused" {
            let (project, outline) = try EditSession.readOutline(url, take: nil, context: Fixture.context(dir))
            let takeAlone = DocumentOutline(EditDocument.legacy(take: project.take, events: []), diskVersion: 2)
            #expect(outline.outputSeconds != takeAlone.outputSeconds, "\(name)")
        }
        // A take without an event log has none, without the reader being asked, and it is no error.
        let reader = CountingReader()
        let (project, _, _) = try EditSession.readDocumentWithDiskVersion(
            silent, take: nil, context: Fixture.context(dir), readingEvents: reader.read)
        #expect(project.events.isEmpty && reader.reads == 0)
        try project.readEvents()
    }
}
