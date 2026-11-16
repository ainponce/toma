// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

// The editor's keys after the final review (area D's minors): ⌥[ and ⌥] by their place, ⌘A on the timeline, and no
// editing key during a drag.

/// D-M3: on a Spanish or Latin American layout "[" itself needs ⌥, so ⌥ and that key types something else, or nothing
/// (a dead key): it is still ⌥[.
@Test func trimToThePlayheadIsFoundByTheKeysPlace() throws {
    var commands = KeyboardCommands()
    let spanishLeft = try #require(EditorKey(characters: "´", unmodified: "´", modifiers: [.option], keyCode: EditorKey.leftBracketKeyCode))
    let deadRight = try #require(EditorKey(characters: "", unmodified: "", modifiers: [.option], keyCode: EditorKey.rightBracketKeyCode))
    #expect(command(&commands, spanishLeft, focus: .timeline) == .trimStartToPlayhead)
    #expect(command(&commands, deadRight, focus: .preview) == .trimEndToPlayhead)
    // As typed on a US layout, and never without ⌥, nor in a field.
    #expect(command(&commands, EditorKey(key: "[", modifiers: [.option]), focus: .timeline) == .trimStartToPlayhead)
    #expect(command(&commands, EditorKey(key: "´", modifiers: [], keyCode: EditorKey.leftBracketKeyCode), focus: .timeline) == nil)
    #expect(command(&commands, spanishLeft, focus: .textField) == nil)
    // A key typed by its character keeps its own command wherever it is.
    #expect(command(&commands, EditorKey(key: "x", modifiers: [.option], keyCode: EditorKey.leftBracketKeyCode), focus: .timeline) == .clearMarks)
    #expect(EditorKey(characters: "", unmodified: nil, modifiers: [.option]) == nil, "a dead key without its code types nothing")
}

/// D-M4: ⌘A selects every item of the track with the focus, on the timeline; elsewhere it is the system's.
@Test func commandASelectsAllOnTheTimelineOnly() {
    var commands = KeyboardCommands()
    let selectAll = EditorKey(key: "a", modifiers: [.command])
    #expect(command(&commands, selectAll, focus: .timeline) == .selectAll)
    for focus in [EditorFocus.textField, .panel, .toolbar, .preview] {
        #expect(command(&commands, selectAll, focus: focus) == nil, "\(focus)")
    }
    #expect(command(&commands, EditorKey(key: "a", modifiers: [.command, .shift]), focus: .timeline) == nil)
}

/// D-M5: what edits is refused during a drag; moving the playhead, playing and the rest are not.
@Test func editingKeysAreTheOnesADragRefuses() {
    let editing: [EditorCommand] = [.split, .delete, .trimStartToPlayhead, .trimEndToPlayhead, .nudge(frames: 1), .addZoom]
    #expect(editing.allSatisfy { $0.edits })
    let others: [EditorCommand] = [
        .playPause, .shuttle(2), .stop, .step(frames: 1), .stepSeconds(-1), .previousEditPoint, .nextEditPoint, .start, .end,
        .markIn, .markOut, .clearMarks, .toggleSnapping, .zoomIn, .zoomOut, .fitTimeline, .deselect, .tab(2), .togglePanel,
        .export, .open, .selectAll,
    ]
    #expect(!others.contains { $0.edits })
}

/// `commands.command(for:focus:)`, outside `#expect`, which cannot call a mutating method.
private func command(_ commands: inout KeyboardCommands, _ key: EditorKey, focus: EditorFocus) -> EditorCommand? {
    commands.command(for: key, focus: focus)
}
