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

    /// Throws `EditDocumentError.newerVersion` for a `create` of a document newer than this app's, and the
    /// `DecodingError` for anything else that is not an entry.
    public init(jsonLine: String) throws {
        try self.init(jsonLineData: Data(jsonLine.utf8))
    }

    /// The line is parsed once, with `JSONValue(parsing:)`, and its fields read from that, only those of its `type`.
    init(jsonLineData: Data) throws {
        let members = try JSONMembers(JSONValue(parsing: jsonLineData))
        let seq = try members.int("seq")
        switch try members.string("type") {
        case Line.Kind.create.rawValue:
            self = .create(
                seq: seq, document: try members.decoded("document", as: EditDocument.self),
                app: try members.decoded("app", as: AppInfo.self))
        case Line.Kind.do.rawValue:
            self = .do(
                seq: seq, group: try members.int("group"), label: try members.string("label"),
                changes: try members.array("changes").map(EditChange.init(json:)), at: try members.decoded("at", as: Date.self))
        case Line.Kind.undo.rawValue:
            self = .undo(seq: seq, group: try members.int("group"))
        case Line.Kind.redo.rawValue:
            self = .redo(seq: seq, group: try members.int("group"))
        case Line.Kind.migrate.rawValue:
            self = .migrate(seq: seq, from: try members.int("from"), to: try members.int("to"))
        case let type:
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "No entry type \"\(type)\"."))
        }
    }

    /// The encoding of an entry, with the fields of its `type`.
    private struct Line: Encodable {
        var entry: EditLogEntry

        init(entry: EditLogEntry) {
            self.entry = entry
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
                try container.encode(document, forKey: .document)
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

    public init(entries: [EditLogEntry], droppedTruncatedTail: Bool, damagedLine: Int? = nil) {
        self.entries = entries
        self.droppedTruncatedTail = droppedTruncatedTail
        self.damagedLine = damagedLine
    }
}

/// Reads `edit-log.jsonl` the way it can be after a crash, with the line rules of `EventLogReader`: a line is whole
/// when it ends with a line break, or when it is the last one and a complete JSON object, which a write cut short never
/// is; any other last line is a write cut short and is dropped. Unlike `events.jsonl`, the log stops at its first
/// damaged line: every line depends on the ones before it.
public enum EditLogReader {
    /// Reads from a descriptor opened with `SafeRead.regularFile(at:)`: never through a symlink (`ELOOP`) and never
    /// stuck on a FIFO or anything else that is not a regular file (`EFTYPE`). Throws if the file cannot be read, and
    /// `EditDocumentError.newerVersion` if its `create` holds a document newer than this app's or a `migrate` goes to
    /// one: a newer app wrote it, so it is not damage.
    public static func read(_ url: URL) throws -> EditLogRead {
        let data = try SafeRead.regularFile(at: url)
        var read = EditLogRead(entries: [], droppedTruncatedTail: false)
        var lineNumber = 0
        for (line, isLast) in lines(of: data) {
            if let entry = try entry(line, after: read.entries.last) {
                read.entries.append(entry)
            } else if isLast, !isWholeObject(line) {
                read.droppedTruncatedTail = true
            } else {
                read.damagedLine = lineNumber
                break
            }
            lineNumber += 1
        }
        return read
    }

    /// Makes the file end at a line break before more lines are appended to it, as `EventLogReader.truncateIncompleteTail`
    /// does but with `read`'s own rule for a whole object (`JSONValue`), so what `read` dropped as cut short is what goes:
    /// a last line without its line break that is a complete JSON object gets one, and any other is truncated away; then
    /// the file is full-synced. Returns `true` if the file changed. Opens it
    /// without following a symlink (`ELOOP`) and refuses what is not a regular file (`EFTYPE`) without blocking.
    public static func truncateIncompleteTail(_ url: URL) throws -> Bool {
        let (fd, _) = try SafeRead.openRegularFile(url, flags: O_RDWR | O_APPEND)
        let changed: Bool
        do {
            changed = try EventLogReader.endAtLineBoundary(fd, isWholeObject: isWholeObject)
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw POSIXError.current() }
        return changed
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

    /// The entry on `line`, if it is one that can follow `previous`: the first is the `create`, and `seq`s grow.
    private static func entry(_ line: Data, after previous: EditLogEntry?) throws -> EditLogEntry? {
        let entry: EditLogEntry
        do {
            entry = try EditLogEntry(jsonLineData: line)
        } catch let error as EditDocumentError {
            throw error
        } catch {
            return nil
        }
        if case let .migrate(_, _, to) = entry, to > EditDocument.currentVersion {
            throw EditDocumentError.newerVersion(to)
        }
        let isCreate = if case .create = entry { true } else { false }
        guard let previous else { return isCreate ? entry : nil }
        return !isCreate && entry.seq > previous.seq ? entry : nil
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
        var data = Data(capacity: Int(size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError.current()
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[..<count])
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
    /// The document after `lastAppliedSeq`, which is its `logSequence`.
    public var document: EditDocument
    /// The `seq` of the last line `document` includes.
    public var lastAppliedSeq: Int
    /// The `seq` of the first line that could not be applied, where the replay stopped; `nil` if every line was.
    public var mismatchSeq: Int?

    public init(document: EditDocument, lastAppliedSeq: Int, mismatchSeq: Int? = nil) {
        self.document = document
        self.lastAppliedSeq = lastAppliedSeq
        self.mismatchSeq = mismatchSeq
    }

    /// Replays `entries` (as `EditLogReader.read` gives them): from `snapshot` if its `logSequence` is the `seq` of
    /// one of them, otherwise from the `create` they start with, applying each `do`, `undo` (the `do` lines of its
    /// group, inverted, from the last to the first) and `redo` after that point; the lines before it say only what each
    /// group holds. `nil` if there is nothing to start from: no such snapshot and no `create` first.
    ///
    /// Stops at the first line that does not match the document (`EditChangeError`) or does not follow the lines
    /// before it: a `create` after the first line, a `do` of a group that is undone, an `undo` of a group that is not
    /// applied, a `redo` of one that is not undone (a `do` of a new group ends what could be redone: history is
    /// linear) and a `migrate`, since documentVersion 1 has no migrations, so every one names a version this app does
    /// not know. Nothing before a `migrate` can be undone or redone.
    ///
    /// The lines are applied to the document's JSON, each change checking what it replaces, and the document is
    /// decoded once, at the end: a replay costs one decoding, not one per line. If the end is no document, or one
    /// without something a line wrote (`EditDocument.applying` refuses both), the first line that leaves it so is found
    /// and the replay stops there; a line whose damage a later line undoes is not found.
    public static func replay(snapshot: EditDocument?, entries: [EditLogEntry]) -> EditReplay? {
        let start: Int
        let document: EditDocument
        if let snapshot, let index = entries.firstIndex(where: { $0.seq == snapshot.logSequence }) {
            (start, document) = (index, snapshot)
        } else if case let .create(_, created, _)? = entries.first {
            (start, document) = (0, created)
        } else {
            return nil
        }
        let (steps, unfollowed) = steps(of: entries, after: start)
        var replay = apply(steps, to: document, from: entries[start].seq)
        if replay.mismatchSeq == nil {
            replay.mismatchSeq = unfollowed
        }
        replay.document.logSequence = replay.lastAppliedSeq
        return replay
    }

    /// A line after the start: its `seq` and what it applies.
    private typealias Step = (seq: Int, changes: [EditChange])

    /// What each line after `start` applies, up to the first one that does not follow the lines before it, whose `seq`
    /// is `unfollowed`.
    private static func steps(of entries: [EditLogEntry], after start: Int) -> (steps: [Step], unfollowed: Int?) {
        var groups = Groups()
        var steps: [Step] = []
        for (index, entry) in entries.enumerated() {
            if index > start {
                guard let changes = groups.changes(for: entry) else { return (steps, entry.seq) }
                steps.append((entry.seq, changes))
            }
            groups.record(entry)
        }
        return (steps, nil)
    }

    /// `steps` applied to `document`, whose line is `seq`, until one does not match.
    private static func apply(_ steps: [Step], to document: EditDocument, from seq: Int) -> EditReplay {
        guard let start = try? document.jsonValue() else {
            // Nothing can be applied to a document that cannot be encoded (a non-finite number).
            return EditReplay(document: document, lastAppliedSeq: seq, mismatchSeq: steps.first?.seq)
        }
        var json = start
        var applied = 0
        var mismatch: Int?
        for step in steps {
            guard let next = try? json.applying(step.changes) else {
                mismatch = step.seq
                break
            }
            json = next
            applied += 1
        }
        guard applied > 0 else { return EditReplay(document: document, lastAppliedSeq: seq, mismatchSeq: mismatch) }
        if let end = try? EditDocument.holding(json) {
            return EditReplay(document: end.document, lastAppliedSeq: steps[applied - 1].seq, mismatchSeq: mismatch)
        }
        return firstInvalidStep(in: steps[..<applied], after: (document, start, seq), else: mismatch)
    }

    /// The replay up to the first of `steps` that leaves no document, when after the last one there is none: each of
    /// them matched, and the state before the first one, `good`, is a document. It decodes about 2√n times: at every
    /// √nth step until one is no document, then at each step after the last good one. `mismatch` is the line after
    /// `steps` that did not match, if every step turned out to leave a document.
    private static func firstInvalidStep(
        in steps: ArraySlice<Step>, after good: (document: EditDocument, json: JSONValue, seq: Int), else mismatch: Int?
    ) -> EditReplay {
        var good = good
        let stride = max(1, Int(Double(steps.count).squareRoot().rounded(.up)))
        var chunkStart = steps.startIndex
        while chunkStart < steps.endIndex {
            let chunk = steps[chunkStart..<min(chunkStart + stride, steps.endIndex)]
            if let end = try? EditDocument.holding(reapplied(chunk, to: good.json)) {
                good = (end.document, end.json, chunk.last?.seq ?? good.seq)
            } else {
                for step in chunk {
                    guard let next = try? EditDocument.holding(reapplied([step], to: good.json)) else {
                        return EditReplay(document: good.document, lastAppliedSeq: good.seq, mismatchSeq: step.seq)
                    }
                    good = (next.document, next.json, step.seq)
                }
            }
            chunkStart = chunk.endIndex
        }
        // Not reached, since the last step leaves no document; if it were, the replay is as if it had checked out.
        return EditReplay(document: good.document, lastAppliedSeq: good.seq, mismatchSeq: mismatch)
    }

    /// `steps`, which all matched before, applied to `json` again.
    private static func reapplied(_ steps: some Sequence<Step>, to json: JSONValue) -> JSONValue {
        steps.reduce(json) { json, step in (try? json.applying(step.changes)) ?? json }
    }

    /// The `do` lines of each group and whether they are applied, as the replay goes through the log.
    private struct Groups {
        private enum State {
            case applied, undone
            /// Undone before a `do` of a new group, or before a `migrate`: it can't come back.
            case closed
        }

        private struct Group {
            var state: State
            var changes: [EditChange]
        }

        private var groups: [Int: Group] = [:]
        /// The groups that are `undone`: a `do` of a new group closes them, without looking at every group (a replay
        /// stays linear in the lines however many groups it has).
        private var undone: Set<Int> = []

        /// What `entry` applies to the document, or `nil` if it does not follow what came before.
        func changes(for entry: EditLogEntry) -> [EditChange]? {
            switch entry {
            case .create, .migrate:
                return nil
            case let .do(_, group, _, changes, _):
                if let existing = groups[group], existing.state != .applied { return nil }
                return changes
            case let .undo(_, group):
                guard let group = groups[group], group.state == .applied else { return nil }
                return group.changes.reversed().map(\.inverse)
            case let .redo(_, group):
                guard let group = groups[group], group.state == .undone else { return nil }
                return group.changes
            }
        }

        mutating func record(_ entry: EditLogEntry) {
            switch entry {
            case .create:
                break
            // Before the start, lines are not checked: one that does not follow changes nothing.
            case let .do(_, group, _, changes, _):
                if let existing = groups[group] {
                    if existing.state == .applied { groups[group]?.changes += changes }
                } else {
                    for id in undone { groups[id] = Group(state: .closed, changes: []) }
                    undone.removeAll()
                    groups[group] = Group(state: .applied, changes: changes)
                }
            case let .undo(_, group):
                if groups[group]?.state == .applied {
                    groups[group]?.state = .undone
                    undone.insert(group)
                }
            case let .redo(_, group):
                if groups[group]?.state == .undone {
                    groups[group]?.state = .applied
                    undone.remove(group)
                }
            case .migrate:
                // Rare (one per change of the document's version): every group closes.
                for (id, group) in groups where group.state != .closed { groups[id] = Group(state: .closed, changes: []) }
                undone.removeAll()
            }
        }
    }
}
