// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the session uses only the public API.
import Editing
import ProjectFormat

/// A moment with a fraction of a second, as `now()` gives them.
private let start = Date(timeIntervalSince1970: 1_794_773_523.25)

/// A `do` line of `group`, without changes: the history walks the log without applying it.
private func doLine(_ seq: Int, group: Int, _ label: EditLabel = .padding) -> EditLogEntry {
    .do(seq: seq, group: group, label: label.rawValue, changes: [], at: start.roundedToWholeSeconds)
}

private let padding = EditStep(label: .padding, target: "/style/padding", changes: [])
private let corners = EditStep(label: .cornerRadius, target: "/style/cornerRadius", changes: [])

/// `step` the way the session records it, `seconds` after `start`: its group from `groupForNext` with the exact moment,
/// and a `do` at `nextSeq` with the moment in whole seconds. Returns the group.
@discardableResult
private func perform(_ step: EditStep, after seconds: Double, in history: inout UndoHistory) -> Int {
    let at = start + seconds
    let group = history.groupForNext(step, at: at)
    history.record(
        .do(seq: history.nextSeq, group: group, label: step.label.rawValue, changes: step.changes, at: at.roundedToWholeSeconds))
    return group
}

@Test func stacksFollowDoUndoRedo() {
    var history = UndoHistory(entries: [SmallDocument.create, doLine(2, group: 2), doLine(3, group: 3), .undo(seq: 4, group: 3)])
    #expect(history.done == [2])
    #expect(history.undone == [3])
    #expect(history.nextSeq == 5)
    history.record(.redo(seq: 5, group: 3))
    #expect(history.done == [2, 3])
    #expect(history.undone == [])
    #expect(history.nextSeq == 6)
    history.record(.undo(seq: 6, group: 3))
    history.record(.undo(seq: 7, group: 2))
    #expect(history.done == [])
    #expect(history.undone == [3, 2], "the next redo is g2, the last undone")
}

@Test func doAfterUndoClearsRedo() {
    var history = UndoHistory(entries: [SmallDocument.create, doLine(2, group: 2), doLine(3, group: 3), .undo(seq: 4, group: 3)])
    history.record(doLine(5, group: 5))
    #expect(history.done == [2, 5])
    #expect(history.undone == [])
    #expect(history.redoLabel == nil)
    // What was cleared can't come back, as the replay refuses it.
    history.record(.redo(seq: 6, group: 3))
    #expect(history.done == [2, 5])
    #expect(history.undone == [])
}

@Test func sameKeyWithinOneSecondJoinsTheGroup() {
    var history = UndoHistory(entries: [SmallDocument.create])
    // Each within 1.0 s of the one before, however long the burst.
    #expect(perform(padding, after: 0, in: &history) == 2)
    #expect(perform(padding, after: 0.5, in: &history) == 2)
    #expect(perform(padding, after: 1.2, in: &history) == 2)
    #expect(perform(padding, after: 2.3, in: &history) == 5, "1.1 s after the last one")
    #expect(perform(corners, after: 2.5, in: &history) == 6, "another label")
    #expect(perform(padding, after: 2.75, in: &history) == 7, "a corner in the middle")
    #expect(perform(padding, after: 3.75, in: &history) == 8, "exactly 1.0 s later")
    #expect(history.done == [2, 5, 6, 7, 8])
    #expect(history.nextSeq == 9)

    // The same label on another target is another group: the speed of two clips.
    let speed = EditStep(label: .speed, target: "c-00000001", changes: [])
    let otherSpeed = EditStep(label: .speed, target: "c-00000002", changes: [])
    #expect(perform(speed, after: 4, in: &history) == 9)
    #expect(perform(otherSpeed, after: 4.25, in: &history) == 10)
    #expect(perform(speed, after: 4.5, in: &history) == 11)
}

@Test func burstsEndWithAnyOtherEntryAndWithTheSession() {
    var history = UndoHistory(entries: [SmallDocument.create])
    perform(padding, after: 0, in: &history)
    history.record(.undo(seq: history.nextSeq, group: 2))
    history.record(.redo(seq: history.nextSeq, group: 2))
    #expect(perform(padding, after: 0.2, in: &history) == 5, "an undo and a redo in the middle")

    // A group asked for and then not recorded leaves the burst as it was.
    _ = history.groupForNext(corners, at: start + 0.3)
    #expect(perform(padding, after: 0.4, in: &history) == 5)

    // Decision 19: the key of the last do lives only in memory, so after reading the log the first change is a new group.
    let log: [EditLogEntry] = [SmallDocument.create, doLine(2, group: 2), doLine(3, group: 2)]
    var reopened = UndoHistory(entries: log)
    #expect(reopened.done == [2])
    #expect(perform(padding, after: 0.1, in: &reopened) == 4)
}

@Test func migrateCutsTheHistory() {
    // A migrate that does not follow (`DocumentMigration.follows`): from 1, after a create of the current version.
    var history = UndoHistory(entries: [
        SmallDocument.create, doLine(2, group: 2), doLine(3, group: 3), .undo(seq: 4, group: 3), .migrate(seq: 5, from: 1, to: 2),
    ])
    #expect(history.done == [])
    #expect(history.undone == [])
    #expect(history.undoLabel == nil)
    #expect(history.redoLabel == nil)
    #expect(history.nextSeq == 6)
    // Nothing before it comes back.
    history.record(.undo(seq: 6, group: 2))
    history.record(.redo(seq: 7, group: 3))
    history.record(doLine(8, group: 2))
    #expect(history.done == [])
    #expect(history.undone == [])
    // A new group after it is history again.
    history.record(doLine(9, group: 9, .split))
    #expect(history.done == [9])
    #expect(history.undoLabel == .split)
}

@Test func labelsComeBackAfterReading() throws {
    let lines = try [
        SmallDocument.create, doLine(2, group: 2, .split), doLine(3, group: 3, .zoomRegenerate), .undo(seq: 4, group: 3),
    ].map { try $0.jsonLine() }
    let entries = try lines.map { try EditLogEntry(jsonLine: $0) }
    var history = UndoHistory(entries: entries)
    #expect(history.undoLabel == .split)
    #expect(history.redoLabel == .zoomRegenerate)
    history.record(.undo(seq: 5, group: 2))
    #expect(history.undoLabel == nil)
    #expect(history.redoLabel == .split)

    // A label this app does not know (written by a newer one) still undoes, without a name.
    var unknown = UndoHistory(entries: [
        SmallDocument.create, .do(seq: 2, group: 2, label: "style.sparkles", changes: [], at: start.roundedToWholeSeconds),
    ])
    #expect(unknown.done == [2])
    #expect(unknown.undoLabel == nil)
    unknown.record(.undo(seq: 3, group: 2))
    #expect(unknown.undone == [2])
}

@Test func newGroupsNeverReuseAnIDTheLogHas() {
    // A group is numbered with the seq of its first do; a log whose ids run ahead of its seqs can't make the next new
    // group join an old one.
    var history = UndoHistory(entries: [SmallDocument.create, doLine(2, group: 40)])
    #expect(history.nextSeq == 41)
    #expect(perform(corners, after: 0, in: &history) == 41)
    #expect(history.done == [40, 41])
}

@Test func labelsAreTheNamesTheLogKeeps() {
    // The 21 actions of design §5.11, the 12 of the 1c design §13.1 after them, the 25 of phase 2 design §8 after those,
    // the 25 of phase 3 design §10 after those and those of phases 4 and 5 last; their raw values are written in
    // edit-log.jsonl, so they never change.
    #expect(EditLabel.allCases.map(\.rawValue) == [
        "split", "delete", "trim", "speed", "zoom.add", "zoom.move", "zoom.change", "zoom.delete", "zoom.regenerate",
        "style.background", "style.padding", "style.cornerRadius", "style.shadow", "style.frame", "cursor", "camera", "screen",
        "audio.volume", "aspect", "frameRate", "style.applyDefault",
        "layout.add", "layout.change", "layout.move", "layout.trim", "layout.delete", "camera.layout", "camera.split",
        "camera.mirror", "camera.border", "camera.shadow", "camera.changes.deleteAll", "style.apply",
        "transcript.create", "transcript.cut", "transcript.restore", "transcript.word", "transcript.break", "transcript.fillers",
        "transcript.pauses", "captions.show", "captions.style", "camera.hideSilences", "camera.background", "camera.framing",
        "camera.look", "camera.sync", "audio.cleanup", "audio.normalize", "style.reframe", "privacy.add", "privacy.change",
        "privacy.move", "privacy.trim", "privacy.delete", "privacy.auto", "keys.overlay", "speed.typing",
        "annotation.add", "annotation.change", "annotation.move", "annotation.trim", "annotation.layer", "annotation.delete",
        "clip.freeze", "clip.card", "clip.media", "clip.content", "zoom.mode", "audio.range", "audio.shift", "music.add",
        "music.change", "music.move", "music.trim", "music.delete", "music.ducking", "take.rerecord", "take.use", "marker.add",
        "marker.rename", "marker.move", "marker.delete",
        "project.title", "project.summary", "marker.chapters",
    ])
}
