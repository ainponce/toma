// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Foundation
import ProjectFormat
import Synchronization

/// Where a project of the trash came from, to restore it there (design §6.3).
public struct TrashOrigin: Codable, Equatable, Sendable {
    /// A bookmark (`URL.bookmarkData()`) of the folder, which follows it if it is moved or renamed.
    public var bookmark: Data?
    /// The folder's path when the project left it.
    public var path: String

    public init(bookmark: Data? = nil, path: String) {
        self.bookmark = bookmark
        self.path = path
    }
}

/// A project out of the projects folder that the library shows (design §6.5).
public struct OtherPlace: Codable, Equatable, Sendable {
    /// When it was added to the library.
    public var added: Date
    /// A bookmark (`URL.bookmarkData()`) of the package, which follows it if it is moved or renamed; resolved only on
    /// an action of the user.
    public var bookmark: Data
    /// The package's last known path.
    public var path: String

    public init(added: Date, bookmark: Data, path: String) {
        self.added = added
        self.bookmark = bookmark
        self.path = path
    }
}

/// `library.json` (design §13.4): what the user told the library, by the identity of each project (a
/// `PackageIdentity.string`). If it is lost, those are lost, never a project. Dates are written in whole seconds.
public struct LibraryRecords: Codable, Equatable, Sendable {
    /// The version this app writes and reads.
    public static let currentVersion = 1

    public var version: Int
    public var favorites: Set<String>
    public var lastOpened: [String: Date]
    public var places: [OtherPlace]
    public var trashOrigins: [String: TrashOrigin]

    public init(
        version: Int = LibraryRecords.currentVersion, favorites: Set<String> = [], lastOpened: [String: Date] = [:],
        places: [OtherPlace] = [], trashOrigins: [String: TrashOrigin] = [:]
    ) {
        self.version = version
        self.favorites = favorites
        self.lastOpened = lastOpened
        self.places = places
        self.trashOrigins = trashOrigins
    }

    /// `~/Library/Application Support/Toma/Library/library.json`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Toma", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "library.json", directoryHint: .notDirectory)
    }

    /// The records at `url`; empty ones if there is no file. A file that is damaged or of a newer version is first
    /// copied aside to `<name>.damaged-<yyyyMMdd-HHmmss>` (`-2`, `-3`… while that name is taken), as the edit log is,
    /// once for the same bytes, and gives empty records; a newer one's carry its `version`, and `LibraryRecordsStore`
    /// never writes over it.
    public static func load(from url: URL) -> LibraryRecords {
        loaded(from: url).records
    }

    /// The records at `url`, and whether they may be written over it: when there is no file, it is this version's, or
    /// it was damaged and is copied aside. Never over a newer one, nor one that cannot be read (a link or a FIFO, which
    /// are not followed nor waited on, a disk that fails).
    static func loaded(from url: URL, now: Date = Date()) -> (records: LibraryRecords, mayWrite: Bool) {
        let data: Data
        do {
            data = try SafeRead.regularFile(at: url)
        } catch let error as POSIXError where error.code == .ENOENT {
            return (LibraryRecords(), true)
        } catch {
            return (LibraryRecords(), false)
        }
        struct Written: Decodable {
            var version: Int
        }
        let version = try? ProjectJSON.decoder().decode(Written.self, from: data).version
        if let version, version > currentVersion {
            setAside(data, next: url, now: now)
            return (LibraryRecords(version: version), false)
        }
        if version == currentVersion, let records = try? ProjectJSON.decoder().decode(LibraryRecords.self, from: data) {
            return (records, true)
        }
        return (LibraryRecords(), setAside(data, next: url, now: now))
    }

    /// Writes `data` to a free `<name>.damaged-<stamp>` next to `url`, unless such a file already holds it. Whether
    /// `data` is there now.
    @discardableResult
    private static func setAside(_ data: Data, next url: URL, now: Date) -> Bool {
        let folder = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".damaged-"
        func copy(named name: String) -> URL { folder.appending(path: name, directoryHint: .notDirectory) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let isAside = names.contains { name in
            name.hasPrefix(prefix) && (try? SafeRead.regularFile(at: copy(named: name), maxBytes: data.count)) == data
        }
        if isAside { return true }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = prefix + formatter.string(from: now)
        for attempt in 1...1000 {
            do {
                try DurableFile.writeNew(data, to: copy(named: attempt == 1 ? stem : stem + "-\(attempt)"))
                return true
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            } catch {
                return false
            }
        }
        return false
    }

    /// The JSON of design §13.4, with `ProjectJSON.encoder()`'s rules and the favorites in order: the same records are
    /// the same bytes.
    public func encoded() throws -> Data {
        try ProjectJSON.encoder().encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case version, favorites, lastOpened, places, trashOrigins
    }

    /// `version` is required; a member that is not there is empty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decode(Int.self, forKey: .version),
            favorites: try container.decodeIfPresent(Set<String>.self, forKey: .favorites) ?? [],
            lastOpened: try container.decodeIfPresent([String: Date].self, forKey: .lastOpened) ?? [:],
            places: try container.decodeIfPresent([OtherPlace].self, forKey: .places) ?? [],
            trashOrigins: try container.decodeIfPresent([String: TrashOrigin].self, forKey: .trashOrigins) ?? [:])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(favorites.sorted(), forKey: .favorites)
        try container.encode(lastOpened, forKey: .lastOpened)
        try container.encode(places, forKey: .places)
        try container.encode(trashOrigins, forKey: .trashOrigins)
    }
}

/// Writes a file whole, with `DurableFile.writeAtomically` on a queue of its own (never the caller's thread), at most
/// once every `interval`: a `write` is written `interval` after the first one that is not on disk yet, and the last
/// `write` wins. The folder is made if it is not there. A write that fails is tried again after `interval`, unless a
/// newer one came meanwhile. Use one writer per file.
public final class DebouncedWriter: Sendable {
    public let url: URL
    private let interval: Duration
    private let queue = DispatchQueue(label: "dev.toma.Toma.DebouncedWriter", qos: .utility)

    private struct State {
        /// What is not on disk yet.
        var pending: Data?
        /// A write is scheduled.
        var isScheduled = false
        /// The number of the scheduled write; a write that `flush` made needless finds another one.
        var generation = 0
    }

    private let state = Mutex(State())

    public init(url: URL, interval: Duration = .seconds(2)) {
        self.url = url
        self.interval = interval
    }

    /// Keeps `data` to be written; returns at once.
    public func write(_ data: Data) {
        keep(data, replacing: true)
    }

    /// Writes what is pending now, after any write under way, and returns once it is on disk (or failed).
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.state.withLock { state in
                    state.isScheduled = false
                    state.generation += 1
                }
                self.writePending()
                continuation.resume()
            }
        }
    }

    /// Keeps `data` (or, without `replacing`, only if nothing newer is pending) and schedules a write if none is.
    private func keep(_ data: Data, replacing: Bool) {
        let generation = state.withLock { state -> Int? in
            if replacing || state.pending == nil { state.pending = data }
            guard !state.isScheduled else { return nil }
            state.isScheduled = true
            state.generation += 1
            return state.generation
        }
        guard let generation else { return }
        queue.asyncAfter(deadline: .now() + interval.dispatchInterval) { self.fire(generation) }
    }

    /// The scheduled write `generation`, on the queue, unless `flush` wrote it already.
    private func fire(_ generation: Int) {
        let isCurrent = state.withLock { state -> Bool in
            guard state.isScheduled, state.generation == generation else { return false }
            state.isScheduled = false
            return true
        }
        if isCurrent { writePending() }
    }

    /// On the queue.
    private func writePending() {
        let data = state.withLock { state -> Data? in
            defer { state.pending = nil }
            return state.pending
        }
        guard let data else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DurableFile.writeAtomically(data, to: url)
        } catch {
            keep(data, replacing: false)
        }
    }
}

/// `library.json` in memory: read when the store is made (so, not on the main thread), changed with `update` and
/// written with a `DebouncedWriter`, at most every 2 s; `flush` writes what is pending. Over a file that
/// `LibraryRecords.load` would not write over (a newer one), it changes only what is in memory.
public actor LibraryRecordsStore {
    public private(set) var records: LibraryRecords
    private let writer: DebouncedWriter
    private let mayWrite: Bool

    public init(url: URL) {
        (records, mayWrite) = LibraryRecords.loaded(from: url)
        writer = DebouncedWriter(url: url)
    }

    public func update(_ change: @Sendable (inout LibraryRecords) -> Void) {
        change(&records)
        guard mayWrite, let data = try? records.encoded() else { return }
        writer.write(data)
    }

    public func flush() async {
        await writer.flush()
    }
}
