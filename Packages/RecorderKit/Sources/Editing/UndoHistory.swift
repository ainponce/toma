// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The undo and redo stacks of a project (design §6.4), from walking its edit log without applying it: `EditReplay`
/// applies the lines, this says which groups can be undone and redone, and by what name.
///
/// It follows the lines as the replay does. A `do` of a new group goes on top of `done` and empties `undone` (history is
/// linear: what was undone can no longer come back); an `undo` moves an applied group to the top of `undone`, and a
/// `redo` moves an undone one back to the top of `done`. A `create`, where a log starts, empties both, and so does a
/// `migrate`, unless it keeps the history (1c design §13.2, `DocumentMigration.LogWalk`): it follows
/// (`DocumentMigration.follows(from:to:atVersion:)`, from the version of the `create`) and no `do` line before it writes
/// inside of what it adds, so a step of before is undone on the migrated document. A line the replay refuses (a `do` of a
/// group that is undone or was emptied away, an `undo` of one that is not applied, a `redo` of one that is not undone)
/// changes nothing.
public struct UndoHistory: Equatable, Sendable {
    /// The applied groups, in the order they were done or redone: the last one is the next undo.
    public private(set) var done: [Int] = []
    /// The undone groups, in the order they were undone: the last one is the next redo.
    public private(set) var undone: [Int] = []
    /// The `seq` of the next line: past every `seq` and every group recorded, so that a new group, numbered with the
    /// `seq` of its first `do`, is never one the log already has.
    public var nextSeq = 1

    private var groups: [Int: Group] = [:]
    /// The grouping key of the last entry recorded, if it is a `do` that `groupForNext` asked for. Only in memory (plan
    /// decision 19): after reading the log again, the first change starts a new group.
    private var lastDo: Burst?
    /// What `groupForNext` gave, until the next entry is recorded.
    private var asked: Burst?
    /// The version of the document along the lines recorded, for each `migrate`.
    private var walk: DocumentMigration.LogWalk

    /// A burst of steps with the same key, each less than this after the one before, is one undo group.
    private static let burstGap: TimeInterval = 1.0

    private struct Group: Equatable, Sendable {
        /// The `label` of its first `do`.
        var label: String
        var state: State
    }

    private enum State: Equatable, Sendable {
        case applied, undone
        /// Undone before a `do` of a new group, or before a `migrate` that cuts the history: it can't come back.
        case closed
    }

    private struct Burst: Equatable, Sendable {
        var group: Int
        var label: EditLabel
        var target: String
        var at: Date
    }

    /// The stacks after `entries`, as `EditLogReader.read` gives them, whose `create` holds a document written in
    /// `createVersion` (`EditLogRead.createVersion`).
    public init(entries: [EditLogEntry], createVersion: Int = EditDocument.currentVersion) {
        walk = DocumentMigration.LogWalk(createVersion: createVersion)
        for entry in entries {
            record(entry)
        }
    }

    /// The label of the next undo; `nil` if there is none, or if its label is not one this app knows.
    public var undoLabel: EditLabel? { label(of: done.last) }

    /// The label of the next redo; `nil` if there is none, or if its label is not one this app knows.
    public var redoLabel: EditLabel? { label(of: undone.last) }

    /// The group for the `do` that records `step`, done at `at` (the exact moment, not the one the line keeps in whole
    /// seconds): the group on top of `done` if the last entry recorded is a `do` of it with the same label and target,
    /// less than 1.0 s before `at` (design §6.4); otherwise a new group, numbered `nextSeq`, the `seq` its first `do`
    /// takes. The key is kept for the `do` that `record` gets next.
    public mutating func groupForNext(_ step: EditStep, at: Date) -> Int {
        let group: Int
        if let lastDo, lastDo.group == done.last, lastDo.label == step.label, lastDo.target == step.target,
            (0..<Self.burstGap).contains(at.timeIntervalSince(lastDo.at))
        {
            group = lastDo.group
        } else {
            group = nextSeq
        }
        asked = Burst(group: group, label: step.label, target: step.target, at: at)
        return group
    }

    /// Follows one more line of the log.
    public mutating func record(_ entry: EditLogEntry) {
        let asked = asked
        self.asked = nil
        lastDo = nil
        nextSeq = max(nextSeq, entry.seq + 1)
        switch entry {
        case .create:
            clear()
        case let .migrate(_, from, to):
            if !walk.walkMigrate(from: from, to: to) { clear() }
        case let .do(_, group, label, changes, _):
            walk.walkDo(changes)
            nextSeq = max(nextSeq, group + 1)
            switch groups[group]?.state {
            case nil:
                close(undone)
                undone = []
                groups[group] = Group(label: label, state: .applied)
                done.append(group)
            case .applied:
                break
            case .undone, .closed:
                return
            }
            if let asked, asked.group == group, asked.label.rawValue == label {
                lastDo = asked
            }
        case let .undo(_, group):
            guard groups[group]?.state == .applied else { return }
            groups[group]?.state = .undone
            Self.remove(group, from: &done)
            undone.append(group)
        case let .redo(_, group):
            guard groups[group]?.state == .undone else { return }
            groups[group]?.state = .applied
            Self.remove(group, from: &undone)
            done.append(group)
        }
    }

    private func label(of group: Int?) -> EditLabel? {
        group.flatMap { groups[$0] }.flatMap { EditLabel(rawValue: $0.label) }
    }

    /// Empties both stacks: nothing in them can be undone or redone again.
    private mutating func clear() {
        close(done + undone)
        done = []
        undone = []
    }

    private mutating func close(_ closing: [Int]) {
        for group in closing {
            groups[group]?.state = .closed
        }
    }

    /// Takes `group` out of `stack`: from the top, as the session always undoes and redoes.
    private static func remove(_ group: Int, from stack: inout [Int]) {
        if stack.last == group {
            stack.removeLast()
        } else {
            stack.removeAll { $0 == group }
        }
    }
}
