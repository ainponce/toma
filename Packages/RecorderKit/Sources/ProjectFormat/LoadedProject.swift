// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization

/// One take of a package as read from disk, for the tools that look at a recording: the verifier,
/// the renderer and the exporter. Loading never changes anything in the package.
public struct LoadedProject: Sendable {
    public var package: ProjectPackage
    public var manifest: Manifest
    public var take: TakeRecord
    /// The take's `events.jsonl` in file order, which is not always the order of `t`. Empty if the
    /// take has no event log. A cut-short last line and lines this version cannot read are skipped.
    ///
    /// A project loaded with `load(_:take:deferringEvents:)` reads them the first time they are asked for, here or with
    /// `readEvents()`, as `load(_:take:)` reads them: that first access reads and decodes the whole log from the disk,
    /// holding a lock the copies share, so it is never made on the main thread. One whose event log cannot be read then
    /// has none here; `readEvents()` throws why.
    public var events: [InputEvent] {
        get { (try? source.events()) ?? [] }
        set { source = EventSource(newValue) }
    }

    /// Where `events` come from, shared by the copies of this value until one of them sets its own.
    private var source: EventSource

    public init(package: ProjectPackage, manifest: Manifest, take: TakeRecord, events: [InputEvent]) {
        self.init(package: package, manifest: manifest, take: take, source: EventSource(events))
    }

    private init(package: ProjectPackage, manifest: Manifest, take: TakeRecord, source: EventSource) {
        self.package = package
        self.manifest = manifest
        self.take = take
        self.source = source
    }

    /// Reads the package at `url`, its take `take` (the last one in the manifest when `nil`) and that
    /// take's events.
    ///
    /// Throws `LoadedProjectError` for a manifest of a format version outside `Manifest.supportedFormatVersions`
    /// (a newer one, for example), one with a path that could leave the package
    /// (`Manifest.validatePaths()`), a package without takes or an unknown take, and the underlying error if
    /// the manifest or the event log cannot be read. Both are read with `SafeRead`: one that is a symlink, or reached
    /// through one inside the package (`takes/`, `takes/<take>/`), throws `ELOOP`, and one that is a FIFO or anything
    /// else that is not a regular file `EFTYPE`, at once, never followed nor waited on. A take without an event log has
    /// no events.
    public static func load(_ url: URL, take: String? = nil) throws -> LoadedProject {
        let (package, manifest, record) = try loadTake(url, take: take)
        let events: [InputEvent]
        do {
            events = try takeEvents(package, record.id)
        } catch let error as POSIXError where error.code == .ENOENT {
            events = []
        }
        return LoadedProject(package: package, manifest: manifest, take: record, events: events)
    }

    /// `load(_:take:)` without reading the take's events yet: `read` reads them, once for this value and its copies,
    /// the first time they are asked for (`events`, `readEvents()`, which read the disk then: never on the main
    /// thread), so who needs only the manifest and the take never opens the event log.
    ///
    /// The event log is looked at without opening it (`SafeRead.checkRegularFile(_:in:)`): one `load(_:take:)` would
    /// refuse for being a link, being reached through one (`takes/`, `takes/<take>/`) or not being a regular file
    /// throws the same error here, at once, and a take without one has no events (`read` is never called). Only what
    /// reading it tells (`EACCES` on the file itself, `EIO`) waits until the events are asked for; so does an event log
    /// that was there and is gone by then (`ENOENT`, the package renamed or moved meanwhile), which is an error, not a
    /// take without one.
    package static func load(
        _ url: URL, take: String?, deferringEvents read: @escaping EventsReader
    ) throws -> LoadedProject {
        let (package, manifest, record) = try loadTake(url, take: take)
        let id = record.id
        do {
            // Where `EventLogReader.read(take:of:)` reads it.
            try SafeRead.checkRegularFile("takes/\(id)/events.jsonl", in: package.url)
        } catch let error as POSIXError where error.code == .ENOENT {
            return LoadedProject(package: package, manifest: manifest, take: record, events: [])
        }
        return LoadedProject(
            package: package, manifest: manifest, take: record, source: EventSource(reading: { try read(package, id) }))
    }

    /// The package at `url`, its manifest and its take `take` (the last one when `nil`), read and checked as
    /// `load(_:take:)` says.
    private static func loadTake(_ url: URL, take: String?) throws -> (ProjectPackage, Manifest, TakeRecord) {
        let package = ProjectPackage(url: url)
        let data = try SafeRead.regularFile(at: package.manifestURL)
        let version = try Manifest.formatVersion(of: data)
        guard Manifest.supportedFormatVersions.contains(version) else {
            throw LoadedProjectError.unsupportedFormatVersion(version)
        }
        let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: data)
        do {
            try manifest.validatePaths()
        } catch {
            throw LoadedProjectError.invalidPath(error)
        }
        let record: TakeRecord
        if let take {
            guard let found = manifest.takes.first(where: { $0.id == take }) else {
                throw LoadedProjectError.takeNotFound(take)
            }
            record = found
        } else {
            guard let last = manifest.takes.last else { throw LoadedProjectError.noTakes }
            record = last
        }
        return (package, manifest, record)
    }

    /// Reads the take's events now if they were not read yet, and throws what reading them threw, each time it is
    /// asked: the error `load(_:take:)` throws for an event log that cannot be read.
    package func readEvents() throws {
        _ = try source.events()
    }

    /// Reads the events of the take with this ID in a package.
    package typealias EventsReader = @Sendable (ProjectPackage, _ take: String) throws -> [InputEvent]

    /// How `load(_:take:)` reads a take's events: `EventLogReader.read(take:of:)`'s. It throws `ENOENT` for a take
    /// without an event log, which the loads read as no events when they find none there.
    package static let takeEvents: EventsReader = { package, take in
        try EventLogReader.read(take: take, of: package).events
    }

    /// The events of a take, or what reads them the first time they are asked for: read at most once.
    private final class EventSource: Sendable {
        private enum State {
            case unread(@Sendable () throws -> [InputEvent])
            case read(Result<[InputEvent], any Error>)
        }

        private let state: Mutex<State>

        init(_ events: [InputEvent]) {
            state = Mutex(.read(.success(events)))
        }

        init(reading read: @escaping @Sendable () throws -> [InputEvent]) {
            state = Mutex(.unread(read))
        }

        /// The events; the first call reads them, and the ones at the same time wait for it.
        func events() throws -> [InputEvent] {
            try state.withLock { state in
                let result: Result<[InputEvent], any Error>
                switch state {
                case let .read(read):
                    result = read
                case let .unread(read):
                    result = Result(catching: read)
                    state = .read(result)
                }
                return try result.get()
            }
        }
    }
}

public enum LoadedProjectError: Error, Equatable {
    /// The manifest is of a version of the format outside `Manifest.supportedFormatVersions`, for example a
    /// newer one, which this version cannot read safely.
    case unsupportedFormatVersion(Int)
    /// The manifest has no takes.
    case noTakes
    /// The manifest has no take with this ID.
    case takeNotFound(String)
    /// A path in the manifest could leave the package. Nothing was read through it.
    case invalidPath(PackagePathError)
}

extension Manifest {
    /// The `formatVersion` of an encoded manifest, decoded on its own: a manifest of a newer format,
    /// which this version may not be able to decode, is still recognized as newer.
    public static func formatVersion(of data: Data) throws -> Int {
        try ProjectJSON.decoder().decode(FormatVersion.self, from: data).formatVersion
    }

    private struct FormatVersion: Decodable {
        var formatVersion: Int
    }
}
