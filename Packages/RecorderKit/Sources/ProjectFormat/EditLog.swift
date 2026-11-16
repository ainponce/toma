// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

private let newline = UInt8(ascii: "\n")

/// One line of `edit-log.jsonl` (design §6.3), the truth about the edits of a project after a crash. Every entry has
/// its `seq`, which grows from line to line (with gaps), and a `type`.
///
/// Written with the rules of `events.jsonl`: compact JSON, keys in alphabetical order, one line each, only appended.
/// `at` follows `ProjectJSON`'s rule for dates, ISO 8601 in whole seconds: a `Date` with a fraction does not come back
/// equal, so whoever builds a `do` truncates it first (`roundedToWholeSeconds`).
public enum EditLogEntry: Equatable, Sendable {
    /// The whole initial document (the legacy one, or a new project's). The first line, and only there.
    case create(seq: Int, document: EditDocument, app: AppInfo)
    /// A change. `label` names the action for the menus (`split`, `style.padding`…); `group` is the undo step it
    /// belongs to.
    case `do`(seq: Int, group: Int, label: String, changes: [EditChange], at: Date)
    /// Undoes every `do` of `group`, from the last to the first.
    case undo(seq: Int, group: Int)
    /// Redoes them, in order.
    case redo(seq: Int, group: Int)
    /// The document went from one `documentVersion` to another, with the app's migration.
    case migrate(seq: Int, from: Int, to: Int)

    public var seq: Int {
        switch self {
        case let .create(seq, _, _), let .do(seq, _, _, _, _), let .undo(seq, _), let .redo(seq, _), let .migrate(seq, _, _): seq
        }
    }

    /// The line, without its line break.
    public func jsonLine() throws -> String {
        String(decoding: try ProjectJSON.compactEncoder().encode(Line(entry: self)), as: UTF8.self)
    }

    /// The line with the document of a `create` written in `version` (`DocumentMigration.reverted`): a log's `create`
    /// stays in the version it was written in, also when it is written again (1c design §13.2). Throws
    /// `EncodingError.invalidValue` for a document that has no `version` (it holds what that version cannot). Any other
    /// entry is its `jsonLine()`.
    public func jsonLine(writingDocumentAt version: Int) throws -> String {
        guard case let .create(_, document, _) = self, version != document.documentVersion else { return try jsonLine() }
        guard let written = DocumentMigration.reverted(try JSONValue(encoding: document), to: version) else {
            throw EncodingError.invalidValue(
                document, EncodingError.Context(codingPath: [], debugDescription: "The document has no version \(version)."))
        }
        return String(decoding: try ProjectJSON.compactEncoder().encode(Line(entry: self, document: written)), as: UTF8.self)
    }

    /// Throws `EditDocumentError.newerVersion` for a `create` of a document newer than this app's, and the
    /// `DecodingError` for anything else that is not an entry.
    public init(jsonLine: String) throws {
        try self.init(jsonLineData: Data(jsonLine.utf8))
    }

    init(jsonLineData: Data) throws {
        self = try Self.parsed(jsonLineData).entry
    }

    /// The entry on a line and, for a `create`, the `documentVersion` its document is written in. The line is parsed
    /// once, with `JSONValue(parsing:)`, and its fields read from that, only those of its `type`; the document of a
    /// `create` is decoded from it too (`EditDocument.decode(json:)`), migrated there if it is of an older version.
    static func parsed(_ data: Data) throws -> (entry: EditLogEntry, createVersion: Int?) {
        let members = try JSONMembers(JSONValue(parsing: data))
        let seq = try members.int("seq")
        switch try members.string("type") {
        case Line.Kind.create.rawValue:
            let document = try members.value("document")
            let entry = EditLogEntry.create(
                seq: seq, document: try EditDocument.decode(json: document), app: try members.decoded("app", as: AppInfo.self))
            return (entry, try? JSONMembers(document).int("documentVersion"))
        case Line.Kind.do.rawValue:
            let entry = EditLogEntry.do(
                seq: seq, group: try members.int("group"), label: try members.string("label"),
                changes: try members.array("changes").map(EditChange.init(json:)), at: try members.decoded("at", as: Date.self))
            return (entry, nil)
        case Line.Kind.undo.rawValue:
            return (.undo(seq: seq, group: try members.int("group")), nil)
        case Line.Kind.redo.rawValue:
            return (.redo(seq: seq, group: try members.int("group")), nil)
        case Line.Kind.migrate.rawValue:
            return (.migrate(seq: seq, from: try members.int("from"), to: try members.int("to")), nil)
        case let type:
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "No entry type \"\(type)\"."))
        }
    }

    /// The encoding of an entry, with the fields of its `type`.
    private struct Line: Encodable {
        var entry: EditLogEntry
        /// The document of a `create` as it is written, when it is not the document's own encoding.
        var document: JSONValue?

        init(entry: EditLogEntry, document: JSONValue? = nil) {
            self.entry = entry
            self.document = document
        }

        private enum CodingKeys: String, CodingKey {
            case type, seq, document, app, group, label, changes, at, from, to
        }

        fileprivate enum Kind: String, Encodable {
            case create, `do`, undo, redo, migrate
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(entry.seq, forKey: .seq)
            switch entry {
            case let .create(_, document, app):
                try container.encode(Kind.create, forKey: .type)
                if let written = self.document {
                    try container.encode(written, forKey: .document)
                } else {
                    try container.encode(document, forKey: .document)
                }
                try container.encode(app, forKey: .app)
            case let .do(_, group, label, changes, at):
                try container.encode(Kind.do, forKey: .type)
                try container.encode(group, forKey: .group)
                try container.encode(label, forKey: .label)
                try container.encode(changes, forKey: .changes)
                try container.encode(at, forKey: .at)
            case let .undo(_, group):
                try container.encode(Kind.undo, forKey: .type)
                try container.encode(group, forKey: .group)
            case let .redo(_, group):
                try container.encode(Kind.redo, forKey: .type)
                try container.encode(group, forKey: .group)
            case let .migrate(_, from, to):
                try container.encode(Kind.migrate, forKey: .type)
                try container.encode(from, forKey: .from)
                try container.encode(to, forKey: .to)
            }
        }
    }
}

/// What `EditLogReader.read` found in an `edit-log.jsonl`.
public struct EditLogRead: Sendable {
    /// The entries up to the first line that is not one, in file order: a `create` first, then growing `seq`s.
    public var entries: [EditLogEntry]
    /// The file ended inside a line that is not a whole JSON object: a write cut short by a crash. It was ignored.
    public var droppedTruncatedTail: Bool
    /// The number (from 0) of the first whole line that is not an entry that can follow the ones before it: not an
    /// entry at all, a first line that is not a `create`, a `create` after the first line or a `seq` that does not
    /// grow. Nothing after it was read.
    public var damagedLine: Int?
    /// The entries ended with a `migrate`, and it was left out of them (1c plan decision 6): the first edit of a 1b
    /// project in 1c writes its `migrate` together with its step, so a `migrate` without a step after it (the last
    /// whole line, or one followed only by a line cut short or a damaged one) is that write cut short, as if the edit
    /// had not happened. `entries` never ends with a `migrate`.
    public var droppedTrailingMigrate: Bool
    /// The `documentVersion` the document of the `create` is written in, before it is read migrated: the version the
    /// replay starts at (`EditReplay.replay(snapshot:snapshotVersion:entries:createVersion:)`). `nil` without a `create`.
    public var createVersion: Int?

    public init(
        entries: [EditLogEntry], droppedTruncatedTail: Bool, damagedLine: Int? = nil, droppedTrailingMigrate: Bool = false,
        createVersion: Int? = nil
    ) {
        self.entries = entries
        self.droppedTruncatedTail = droppedTruncatedTail
        self.damagedLine = damagedLine
        self.droppedTrailingMigrate = droppedTrailingMigrate
        self.createVersion = createVersion
    }
}

/// Reads `edit-log.jsonl` the way it can be after a crash, with the line rules of `EventLogReader`: a line is whole
/// when it ends with a line break, or when it is the last one and a complete JSON object, which a write cut short never
/// is; any other last line is a write cut short and is dropped. Unlike `events.jsonl`, the log stops at its first
/// damaged line: every line depends on the ones before it. A `migrate` the entries would end with is the first edit of a
/// 1b project cut short (1c plan decision 6), and is dropped too.
public enum EditLogReader {
    /// Reads from a descriptor opened with `SafeRead.regularFile(at:)`: never through a symlink (`ELOOP`) and never
    /// stuck on a FIFO or anything else that is not a regular file (`EFTYPE`). Throws if the file cannot be read, and
    /// `EditDocumentError.newerVersion` if its `create` holds a document newer than this app's or a `migrate` goes to
    /// one: a newer app wrote it, so it is not damage.
    ///
    /// The `migrate` lines the entries end with are left out (`droppedTrailingMigrate`): a read that writes nothing,
    /// like the library's, sees the project as it was before that first edit.
    public static func read(_ url: URL) throws -> EditLogRead {
        let data = try SafeRead.regularFile(at: url)
        var read = EditLogRead(entries: [], droppedTruncatedTail: false)
        var lineNumber = 0
        for (line, isLast) in lines(of: data) {
            if case let (entry, createVersion)? = try entry(line, after: read.entries.last) {
                if read.entries.isEmpty { read.createVersion = createVersion }
                read.entries.append(entry)
            } else if isLast, !isWholeObject(line) {
                read.droppedTruncatedTail = true
            } else {
                read.damagedLine = lineNumber
                break
            }
            lineNumber += 1
        }
        while case .migrate? = read.entries.last {
            read.entries.removeLast()
            read.droppedTrailingMigrate = true
        }
        return read
    }

    /// Makes the file end at a line break before more lines are appended to it, with the rules of
    /// `EventLogReader.truncateIncompleteTail`: a last line without its line break that is a complete JSON object gets
    /// one, and any other is truncated away. Then the `migrate` lines it ends with, which `read` leaves out, are
    /// truncated away too (1c plan decision 6), except one to a version newer than this app's, which `read` refuses
    /// and this never touches. The file is full-synced after each change. Returns `true` if the file changed. Opens it
    /// without following a symlink (`ELOOP`) and refuses what is not a regular file (`EFTYPE`) without blocking.
    public static func truncateIncompleteTail(_ url: URL) throws -> Bool {
        let (fd, _) = try SafeRead.openRegularFile(url, flags: O_RDWR | O_APPEND)
        let changed: Bool
        do {
            let endedAtLineBreak = try EventLogReader.endAtLineBoundary(fd)
            let cutMigrates = try truncateTrailingMigrates(fd)
            changed = endedAtLineBreak || cutMigrates
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw POSIXError.current() }
        return changed
    }

    /// Truncates away the `migrate` lines that a file ending at a line break ends with, and full-syncs it; `true` if
    /// there was one.
    private static func truncateTrailingMigrates(_ fd: Int32) throws -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError.current() }
        // `end` is always right after a line break, or 0.
        var end = info.st_size
        while end > 0 {
            let start = try EventLogReader.startOfLastLine(fd, size: end - 1)
            guard isMigrate(try EventLogReader.readBytes(fd, at: start, count: Int(end - 1 - start))) else { break }
            end = start
        }
        guard end < info.st_size else { return false }
        guard ftruncate(fd, end) == 0 else { throw POSIXError.current() }
        try DurableFile.fullSync(fd)
        return true
    }

    /// Whether `line` is a `migrate` that `read` would take, to a version this app knows. Its `type` is read first, so a
    /// long `create` the file ends with is parsed but never decoded.
    private static func isMigrate(_ line: [UInt8]) -> Bool {
        let data = Data(line)
        guard let members = try? JSONMembers(JSONValue(parsing: data)), (try? members.string("type")) == "migrate",
            case let .migrate(_, _, to)? = try? EditLogEntry(jsonLineData: data)
        else { return false }
        return to <= EditDocument.currentVersion
    }

    /// Each line of `data` without its line break, and whether it is a last line without one. A file that ends with a
    /// line break has no such line.
    private static func lines(of data: Data) -> [(Data, isLast: Bool)] {
        var lines: [(Data, isLast: Bool)] = []
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count {
                guard let found = memchr(base + start, Int32(newline), buffer.count - start) else {
                    lines.append((data.subdata(in: start..<buffer.count), true))
                    return
                }
                let end = base.distance(to: UnsafeRawPointer(found))
                lines.append((data.subdata(in: start..<end), false))
                start = end + 1
            }
        }
        return lines
    }

    /// The entry on `line`, if it is one that can follow `previous` (the first is the `create`, and `seq`s grow), and
    /// for a `create` the version its document is written in.
    private static func entry(_ line: Data, after previous: EditLogEntry?) throws -> (entry: EditLogEntry, createVersion: Int?)? {
        let parsed: (entry: EditLogEntry, createVersion: Int?)
        do {
            parsed = try EditLogEntry.parsed(line)
        } catch let error as EditDocumentError {
            throw error
        } catch {
            return nil
        }
        let entry = parsed.entry
        if case let .migrate(_, _, to) = entry, to > EditDocument.currentVersion {
            throw EditDocumentError.newerVersion(to)
        }
        let isCreate = if case .create = entry { true } else { false }
        guard let previous else { return isCreate ? parsed : nil }
        return !isCreate && entry.seq > previous.seq ? parsed : nil
    }

    /// Whether `bytes` is one complete JSON object: no strict prefix of one is.
    private static func isWholeObject(_ bytes: Data) -> Bool {
        if case .object? = try? JSONValue(parsing: bytes) { true } else { false }
    }
}

/// Reads the files of the package that must never be followed through a symlink nor block on a FIFO: `edit.json`,
/// `edit-log.jsonl` and the manifest that is read again before the package moves to v3.
public enum SafeRead {
    /// The bytes of the regular file at `url`, read from a descriptor opened with `O_RDONLY | O_NOFOLLOW | O_NONBLOCK |
    /// O_CLOEXEC` and checked with `fstat`: a symlink throws `ELOOP`, and a FIFO or anything else that is not a regular
    /// file throws `EFTYPE`, at once. Never `Data(contentsOf:)`, which follows symlinks and blocks on a FIFO.
    public static func regularFile(at url: URL) throws -> Data {
        let (fd, size) = try openRegularFile(url, flags: O_RDONLY)
        defer { close(fd) }
        return try readToEnd(fd, capacity: Int(size), limit: nil)
    }

    /// The bytes of the regular file at `url`, read as `regularFile(at:)` reads them, if there are no more than
    /// `maxBytes`: `EFBIG` if `fstat` says the file is larger, before anything is read, and `EFBIG` if it grew past
    /// `maxBytes` since, as soon as one byte past the limit is read. Never more than that byte.
    public static func regularFile(at url: URL, maxBytes: Int) throws -> Data {
        let (fd, size) = try openRegularFile(url, flags: O_RDONLY)
        defer { close(fd) }
        guard size <= maxBytes else { throw POSIXError(.EFBIG) }
        return try readToEnd(fd, capacity: Int(size), limit: maxBytes)
    }

    /// Everything from `fd` to its end; with a `limit`, `EFBIG` once more than `limit` bytes were read.
    static func readToEnd(_ fd: Int32, capacity: Int, limit: Int?) throws -> Data {
        var data = Data(capacity: capacity)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // With a limit, at most one byte past it: the byte that tells a file that grew past it from one that ends
            // there. `data` never holds more than `limit`, so what is left is never negative; `limit` may be `Int.max`.
            let wanted = limit.map { limit in
                let left = limit - data.count
                return left >= buffer.count ? buffer.count : left + 1
            } ?? buffer.count
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError.current()
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[..<count])
            if let limit, data.count > limit { throw POSIXError(.EFBIG) }
        }
    }

    /// Opens the regular file at `url` with `flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`, and gives its descriptor and
    /// its size: `O_NONBLOCK` changes nothing for a regular file and keeps a FIFO from blocking the open before `fstat`
    /// refuses it.
    static func openRegularFile(_ url: URL, flags: Int32) throws -> (fd: Int32, size: off_t) {
        let fd = open(url.path, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current() }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = POSIXError.current()
            close(fd)
            throw error
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw POSIXError(.EFTYPE)
        }
        return (fd, info.st_size)
    }
}

/// The edit document a log gives (design §6.5).
public struct EditReplay: Sendable {
    /// The document after `lastAppliedSeq`, which is its `logSequence`: always of `EditDocument.currentVersion`.
    public var document: EditDocument
    /// The `seq` of the last line `document` includes.
    public var lastAppliedSeq: Int
    /// The `seq` of the first line that could not be applied, where the replay stopped; `nil` if every line was.
    public var mismatchSeq: Int?
    /// The same state as the disk holds it, before it is decoded (1c design §13.2): the JSON of `document` in `version`,
    /// with its `logSequence`, as `DocumentMigration.reverted` gives it. What is written while a 1b project has not been
    /// edited in 1c, so the app of 1b still opens it. `.null` only for a start document that cannot be encoded (a
    /// non-finite number), to which nothing applies.
    public var json: JSONValue
    /// The `documentVersion` of `json`: the one the `create` (or the snapshot) is written in, raised by each `migrate`
    /// the replay went through.
    public var version: Int

    /// Without `json`, it is `document`'s own, in the current version.
    public init(
        document: EditDocument, lastAppliedSeq: Int, mismatchSeq: Int? = nil, json: JSONValue? = nil,
        version: Int = EditDocument.currentVersion
    ) {
        self.document = document
        self.lastAppliedSeq = lastAppliedSeq
        self.mismatchSeq = mismatchSeq
        self.json = json ?? (try? JSONValue(encoding: document)) ?? .null
        self.version = version
    }

    /// Replays `entries` (as `EditLogReader.read` gives them): from `snapshot` if its `logSequence` is the `seq` of
    /// one of them, otherwise from the `create` they start with, applying each `do`, `undo` (the `do` lines of its
    /// group, inverted, from the last to the first), `redo` and `migrate` after that point; the lines before it say only
    /// what each group holds. `nil` if there is nothing to start from: no such snapshot and no `create` first.
    ///
    /// The start is in the version it is written in (1c design §13.2): `snapshotVersion` for the snapshot,
    /// `createVersion` (`EditLogRead.createVersion`) for the `create`, both read migrated, so their JSON is reverted to
    /// it (`DocumentMigration.reverted`; one that version cannot hold starts at its own). A `migrate` that follows
    /// (`DocumentMigration.follows(from:to:atVersion:)`: the next version, from the one the state is at, by an
    /// additive migration) migrates the state there and the replay goes on; with the default versions, a 1b log is read
    /// as before.
    ///
    /// Stops at the first line that does not match the document (`EditChangeError`) or does not follow the lines
    /// before it: a `create` after the first line, a `do` of a group that is undone, an `undo` of a group that is not
    /// applied, a `redo` of one that is not undone (a `do` of a new group ends what could be redone: history is
    /// linear) and a `migrate` that does not follow. Nothing before a `migrate` can be undone or redone after it, unless
    /// it follows and no `do` line before it writes inside of what it adds (`DocumentMigration.LogWalk`): an additive
    /// migration commutes with every other change, so a step of before is undone on the migrated document.
    ///
    /// The lines are applied to the JSON, each change checking what it replaces, and the document is decoded once, at
    /// the end (migrated first, if the JSON is of an older version): a replay costs one decoding, not one per line. If
    /// the end is no document, or one without something a line wrote (`EditDocument.applying` refuses both), the first
    /// line that leaves it so is found and the replay stops there; a line whose damage a later line undoes is not found.
    public static func replay(
        snapshot: EditDocument?, snapshotVersion: Int = EditDocument.currentVersion, entries: [EditLogEntry],
        createVersion: Int = EditDocument.currentVersion
    ) -> EditReplay? {
        let start: Int
        let document: EditDocument
        let version: Int
        if let snapshot, let index = entries.firstIndex(where: { $0.seq == snapshot.logSequence }) {
            (start, document, version) = (index, snapshot, snapshotVersion)
        } else if case let .create(_, created, _)? = entries.first {
            (start, document, version) = (0, created, createVersion)
        } else {
            return nil
        }
        let (steps, unfollowed) = steps(of: entries, after: start, createVersion: createVersion)
        var replay = apply(steps, to: document, writtenIn: version, from: entries[start].seq)
        if replay.mismatchSeq == nil {
            replay.mismatchSeq = unfollowed
        }
        replay.document.logSequence = replay.lastAppliedSeq
        if case var .object(members) = replay.json {
            members["logSequence"] = .integer(Int64(replay.lastAppliedSeq))
            replay.json = .object(members)
        }
        return replay
    }

    /// A state of the replay as the disk holds it: the document's JSON, in its `documentVersion`.
    private struct State {
        var json: JSONValue
        var version: Int

        /// `document` as `version` writes it, or as its own version does if `version` cannot hold it; `nil` if it
        /// cannot be encoded.
        init?(_ document: EditDocument, writtenIn version: Int) {
            guard let json = try? JSONValue(encoding: document) else { return nil }
            if let reverted = DocumentMigration.reverted(json, to: version) {
                (self.json, self.version) = (reverted, version)
            } else {
                (self.json, self.version) = (json, document.documentVersion)
            }
        }

        init(json: JSONValue, version: Int) {
            self.json = json
            self.version = version
        }

        /// The document of this state, if it holds all of it: the JSON is migrated to the current version, which is
        /// the one `EditDocument.holding` reads, and from an older one must come back reverted as it was (a line of
        /// that version wrote nothing the migration replaces).
        var document: EditDocument? {
            guard version <= EditDocument.currentVersion else { return nil }
            var current = json
            for from in version..<EditDocument.currentVersion {
                guard let migrated = try? DocumentMigration.migrate(current, from: from) else { return nil }
                current = migrated
            }
            guard let held = try? EditDocument.holding(current) else { return nil }
            guard version == EditDocument.currentVersion || DocumentMigration.reverted(held.json, to: version) == json else {
                return nil
            }
            return held.document
        }
    }

    /// A line after the start: its `seq` and what it does to the state.
    private struct Step {
        enum Action {
            case changes([EditChange])
            case migrate(from: Int, to: Int)
        }

        var seq: Int
        var action: Action

        /// `state` after this line; throws if the line does not match it. A `migrate` also throws if the state holds
        /// something the migration would write over (a line of the older version wrote a member it adds): reverted, the
        /// migrated state must be the state again, so that line is never lost in silence; the replay stops before the
        /// `migrate`, where the check of the end finds it.
        func applied(to state: State) throws -> State {
            switch action {
            case let .changes(changes):
                return State(json: try state.json.applying(changes), version: state.version)
            case let .migrate(from, to):
                guard DocumentMigration.follows(from: from, to: to, atVersion: state.version) else {
                    throw EditChangeError.invalidDocument("/documentVersion")
                }
                let migrated = try DocumentMigration.migrate(state.json, from: from)
                guard DocumentMigration.reverted(migrated, to: from) == state.json else {
                    throw EditChangeError.invalidDocument("")
                }
                return State(json: migrated, version: to)
            }
        }
    }

    /// What each line after `start` does, up to the first one that does not follow the lines before it, whose `seq` is
    /// `unfollowed`.
    private static func steps(
        of entries: [EditLogEntry], after start: Int, createVersion: Int
    ) -> (steps: [Step], unfollowed: Int?) {
        var groups = Groups(createVersion: createVersion)
        var steps: [Step] = []
        for (index, entry) in entries.enumerated() {
            if index > start {
                guard let action = groups.action(for: entry) else { return (steps, entry.seq) }
                steps.append(Step(seq: entry.seq, action: action))
            }
            groups.record(entry)
        }
        return (steps, nil)
    }

    /// `steps` applied to `document`, written in `version`, whose line is `seq`, until one does not match.
    private static func apply(_ steps: [Step], to document: EditDocument, writtenIn version: Int, from seq: Int) -> EditReplay {
        guard let start = State(document, writtenIn: version) else {
            // Nothing can be applied to a document that cannot be encoded (a non-finite number).
            return EditReplay(document: document, lastAppliedSeq: seq, mismatchSeq: steps.first?.seq)
        }
        var state = start
        var applied = 0
        var mismatch: Int?
        for step in steps {
            guard let next = try? step.applied(to: state) else {
                mismatch = step.seq
                break
            }
            state = next
            applied += 1
        }
        guard applied > 0 else {
            return EditReplay(document: document, lastAppliedSeq: seq, mismatchSeq: mismatch, json: start.json, version: start.version)
        }
        if let end = state.document {
            return EditReplay(
                document: end, lastAppliedSeq: steps[applied - 1].seq, mismatchSeq: mismatch, json: state.json,
                version: state.version)
        }
        return firstInvalidStep(in: steps[..<applied], after: (document, start, seq), else: mismatch)
    }

    /// The replay up to the first of `steps` that leaves no document, when after the last one there is none: each of
    /// them matched, and the state before the first one, `good`, is a document. It decodes about 2√n times: at every
    /// √nth step until one is no document, then at each step after the last good one. `mismatch` is the line after
    /// `steps` that did not match, if every step turned out to leave a document.
    private static func firstInvalidStep(
        in steps: ArraySlice<Step>, after good: (document: EditDocument, state: State, seq: Int), else mismatch: Int?
    ) -> EditReplay {
        var good = good
        func replay(mismatchSeq: Int?) -> EditReplay {
            EditReplay(
                document: good.document, lastAppliedSeq: good.seq, mismatchSeq: mismatchSeq, json: good.state.json,
                version: good.state.version)
        }
        let stride = max(1, Int(Double(steps.count).squareRoot().rounded(.up)))
        var chunkStart = steps.startIndex
        while chunkStart < steps.endIndex {
            let chunk = steps[chunkStart..<min(chunkStart + stride, steps.endIndex)]
            let end = reapplied(chunk, to: good.state)
            if let document = end.document {
                good = (document, end, chunk.last?.seq ?? good.seq)
            } else {
                for step in chunk {
                    let next = reapplied([step], to: good.state)
                    guard let document = next.document else { return replay(mismatchSeq: step.seq) }
                    good = (document, next, step.seq)
                }
            }
            chunkStart = chunk.endIndex
        }
        // Not reached, since the last step leaves no document; if it were, the replay is as if it had checked out.
        return replay(mismatchSeq: mismatch)
    }

    /// `steps`, which all matched before, applied to `state` again.
    private static func reapplied(_ steps: some Sequence<Step>, to state: State) -> State {
        steps.reduce(state) { state, step in (try? step.applied(to: state)) ?? state }
    }

    /// The `do` lines of each group and whether they are applied, and the version of the document, as the replay goes
    /// through the log.
    private struct Groups {
        private enum State {
            case applied, undone
            /// Undone before a `do` of a new group, or before a `migrate` that cuts the history: it can't come back.
            case closed
        }

        private struct Group {
            var state: State
            var changes: [EditChange]
        }

        private var groups: [Int: Group] = [:]
        private var walk: DocumentMigration.LogWalk

        init(createVersion: Int) {
            walk = DocumentMigration.LogWalk(createVersion: createVersion)
        }

        /// What `entry` does to the document, or `nil` if it does not follow what came before.
        func action(for entry: EditLogEntry) -> Step.Action? {
            switch entry {
            case .create:
                return nil
            case let .migrate(_, from, to):
                return walk.follows(from: from, to: to) ? .migrate(from: from, to: to) : nil
            case let .do(_, group, _, changes, _):
                if let existing = groups[group], existing.state != .applied { return nil }
                return .changes(changes)
            case let .undo(_, group):
                guard let group = groups[group], group.state == .applied else { return nil }
                return .changes(group.changes.reversed().map(\.inverse))
            case let .redo(_, group):
                guard let group = groups[group], group.state == .undone else { return nil }
                return .changes(group.changes)
            }
        }

        mutating func record(_ entry: EditLogEntry) {
            switch entry {
            case .create:
                break
            // Before the start, lines are not checked: one that does not follow changes nothing.
            case let .do(_, group, _, changes, _):
                walk.walkDo(changes)
                if let existing = groups[group] {
                    if existing.state == .applied { groups[group]?.changes += changes }
                } else {
                    close { $0 == .undone }
                    groups[group] = Group(state: .applied, changes: changes)
                }
            case let .undo(_, group):
                if groups[group]?.state == .applied { groups[group]?.state = .undone }
            case let .redo(_, group):
                if groups[group]?.state == .undone { groups[group]?.state = .applied }
            case let .migrate(_, from, to):
                if !walk.walkMigrate(from: from, to: to) {
                    close { _ in true }
                }
            }
        }

        private mutating func close(where shouldClose: (State) -> Bool) {
            for (id, group) in groups where group.state != .closed && shouldClose(group.state) {
                groups[id] = Group(state: .closed, changes: [])
            }
        }
    }
}
