// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The compaction of `edit-log.jsonl` (design §6.5): a shorter log that replays to the same document, with the same undo
/// and redo stacks and the same last `seq`. It only computes the lines; the session writes them after the snapshot of
/// the current state, through the journal that holds the log: `EditJournal.replaceLog(with:)` takes its turn after every
/// line appended before it, refuses while one of them is not on disk, puts the new log in place (a temporary file,
/// `F_FULLFSYNC`, `renameat` and a sync of the folder) and goes on appending to it. Nothing else renames a log over one
/// a journal holds: its `O_APPEND` descriptor would stay on the old file, by then without a name (the journal notices
/// and confirms no later line, but they stay in memory and the state stays `.failing`).
public enum LogCompaction {
    public static let maxBytes = 8 * 1_048_576
    public static let maxEntries = 20_000

    /// Whether a log of `bytes` bytes and `entries` lines is past one of the thresholds. They are passed in so the tests
    /// and `edit-stress --compact-every` compact after a few steps.
    public static func isNeeded(
        bytes: Int, entries: Int, maxBytes: Int = LogCompaction.maxBytes, maxEntries: Int = LogCompaction.maxEntries
    ) -> Bool {
        bytes > maxBytes || entries > maxEntries
    }

    /// `entries`, a log as `EditLogReader.read` gives it that replays without a mismatch, whose `create` holds a document
    /// written in `createVersion` (`EditLogRead.createVersion`), compacted: the same `create`; its `migrate` lines, in
    /// order; each group of `done` as one `do`, in the order of the stack, where the `set`s that follow each other on one
    /// path are fused into one (the first `before`, the last `after`); the groups of `undone` as their `do` lines in the
    /// order they were done, then their `undo` lines in reverse (plan decision 4: as "each `do` followed by its `undo`",
    /// the `before` of the second group would not match). Each group keeps its id, its label and the `at` of its last
    /// `do`; the groups that were undone and then emptied away by a new one, and every `redo`, are gone. The `seq`s grow
    /// and the last one is the original last one, so a snapshot of the current state still names the last line.
    ///
    /// The `create` stays in its version and every group goes after the `migrate` lines (1c design §13.2): that is the
    /// same document only because each `migrate` keeps the history (`DocumentMigration.LogWalk`), an additive migration
    /// no line before it writes inside of, which commutes with every group.
    ///
    /// Only a log made the way the session makes it with `UndoHistory` has stacks to compact: a `do` of a group the log
    /// already has comes right after a `do` of that group (a burst), an `undo` is of the top of `done` and a `redo` of
    /// the top of `undone`. Any other log is returned as it is, since its groups might not replay in the order of the
    /// stacks: one that does not start with a `create`, has a `migrate` that cuts the history (it does not follow, or a
    /// line before it writes inside of what it adds) or adds to, undoes or redoes a group out of that order.
    public static func compact(_ entries: [EditLogEntry], createVersion: Int = EditDocument.currentVersion) -> [EditLogEntry] {
        guard case .create? = entries.first, let last = entries.last,
            let stacks = Stacks(entries.dropFirst(), createVersion: createVersion)
        else {
            return entries
        }
        let count = stacks.migrations.count + stacks.done.count + 2 * stacks.undone.count
        var seq = last.seq - count
        func nextSeq() -> Int {
            seq += 1
            return seq
        }
        var compacted = [entries[0]]
        compacted.reserveCapacity(1 + count)
        for migration in stacks.migrations {
            compacted.append(.migrate(seq: nextSeq(), from: migration.from, to: migration.to))
        }
        for group in stacks.done + stacks.undone.reversed() {
            compacted.append(.do(seq: nextSeq(), group: group.id, label: group.label, changes: fused(group.changes), at: group.at))
        }
        for group in stacks.undone {
            compacted.append(.undo(seq: nextSeq(), group: group.id))
        }
        return compacted
    }

    /// `changes` with each run of `set`s on one path, each `before` the `after` of the one before it, as one `set`.
    private static func fused(_ changes: [EditChange]) -> [EditChange] {
        var fused: [EditChange] = []
        fused.reserveCapacity(changes.count)
        for change in changes {
            if case let .set(path, before, after) = change, case let .set(lastPath, first, lastAfter)? = fused.last,
                lastPath == path, lastAfter == before
            {
                fused[fused.count - 1] = .set(path: path, before: first, after: after)
            } else {
                fused.append(change)
            }
        }
        return fused
    }

    /// A group of the log: the changes of all its `do` lines, in order.
    private struct Group {
        var id: Int
        var label: String
        var changes: [EditChange]
        var at: Date
    }

    /// The stacks the lines after a log's `create` leave, with what each group holds, and its migrations.
    private struct Stacks {
        var migrations: [(from: Int, to: Int)] = []
        var done: [Group] = []
        var undone: [Group] = []

        /// `nil` if the lines are not ones the session writes in that order, or have a `migrate` that cuts the history.
        init?(_ entries: ArraySlice<EditLogEntry>, createVersion: Int) {
            var walk = DocumentMigration.LogWalk(createVersion: createVersion)
            var seen: Set<Int> = []
            // The group of the line before, if it is a `do`.
            var burst: Int?
            for entry in entries {
                switch entry {
                case .create:
                    return nil
                case let .migrate(_, from, to):
                    guard walk.walkMigrate(from: from, to: to) else { return nil }
                    migrations.append((from, to))
                case let .do(_, group, label, changes, at):
                    walk.walkDo(changes)
                    if group == burst {
                        done[done.count - 1].changes += changes
                        done[done.count - 1].at = at
                    } else {
                        guard seen.insert(group).inserted else { return nil }
                        undone = []
                        done.append(Group(id: group, label: label, changes: changes, at: at))
                    }
                    burst = group
                    continue
                case let .undo(_, group):
                    guard done.last?.id == group else { return nil }
                    undone.append(done.removeLast())
                case let .redo(_, group):
                    guard undone.last?.id == group else { return nil }
                    done.append(undone.removeLast())
                }
                burst = nil
            }
        }
    }
}
