// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The compaction of `edit-log.jsonl` (design §6.5): a shorter log that replays to the same document, with the same undo
/// and redo stacks and the same last `seq`. It only computes the lines; the session writes them (a temporary file,
/// `F_FULLFSYNC`, `rename(2)` and a sync of the folder) after the snapshot of the current state, and only while no
/// `EditJournal` has the log open: at opening, after reading and replaying it and before opening the journal; at
/// closing, after the journal closed with every line on disk. A `rename` over a log the journal holds would leave its
/// `O_APPEND` descriptor on the old file, by then without a name, and every later line would go to a file that is gone.
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

    /// `entries`, a log as `EditLogReader.read` gives it that replays without a mismatch, compacted: the same `create`;
    /// each group of `done` as one `do`, in the order of the stack, where the `set`s that follow each other on one path
    /// are fused into one (the first `before`, the last `after`); the groups of `undone` as their `do` lines in the order
    /// they were done, then their `undo` lines in reverse (plan decision 4: as "each `do` followed by its `undo`", the
    /// `before` of the second group would not match). Each group keeps its id, its label and the `at` of its last `do`;
    /// the groups that were undone and then emptied away by a new one, and every `redo`, are gone. The `seq`s grow and
    /// the last one is the original last one, so a snapshot of the current state still names the last line.
    ///
    /// Only a log made the way the session makes it with `UndoHistory` has stacks to compact: a `do` of a group the log
    /// already has comes right after a `do` of that group (a burst), an `undo` is of the top of `done` and a `redo` of
    /// the top of `undone`. Any other log is returned as it is, since its groups might not replay in the order of the
    /// stacks: one that does not start with a `create`, has a `migrate` (documentVersion 1 has none, so the replay
    /// stops there) or adds to, undoes or redoes a group out of that order.
    public static func compact(_ entries: [EditLogEntry]) -> [EditLogEntry] {
        guard case .create? = entries.first, let last = entries.last, let stacks = Stacks(entries.dropFirst()) else {
            return entries
        }
        var seq = last.seq - (stacks.done.count + 2 * stacks.undone.count)
        func nextSeq() -> Int {
            seq += 1
            return seq
        }
        var compacted = [entries[0]]
        compacted.reserveCapacity(1 + stacks.done.count + 2 * stacks.undone.count)
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

    /// The stacks the lines after a log's `create` leave, with what each group holds.
    private struct Stacks {
        var done: [Group] = []
        var undone: [Group] = []

        /// `nil` if the lines are not ones the session writes in that order.
        init?(_ entries: ArraySlice<EditLogEntry>) {
            var seen: Set<Int> = []
            // The group of the line before, if it is a `do`.
            var burst: Int?
            for entry in entries {
                switch entry {
                case .create, .migrate:
                    return nil
                case let .do(_, group, label, changes, at):
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
