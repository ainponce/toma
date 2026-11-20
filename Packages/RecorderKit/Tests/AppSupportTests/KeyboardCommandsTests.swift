// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import Testing

@Suite struct KeyboardCommandsTests {
    private static let focuses: [EditorFocus] = [.toolbar, .preview, .panel, .timeline, .textField]

    private func command(_ key: String, _ modifiers: KeyModifiers = [], focus: EditorFocus = .timeline) -> EditorCommand? {
        var commands = KeyboardCommands()
        return commands.command(for: EditorKey(key: key, modifiers: modifiers), focus: focus)
    }

    @Test func shuttleSpeedsUp() {
        var commands = KeyboardCommands()
        let l = EditorKey(key: "l"), j = EditorKey(key: "j"), k = EditorKey(key: "k")
        #expect(commands.command(for: l, focus: .timeline) == .shuttle(1))
        #expect(commands.command(for: l, focus: .timeline) == .shuttle(2))
        #expect(commands.command(for: l, focus: .preview) == .shuttle(4))
        #expect(commands.command(for: l, focus: .timeline) == .shuttle(8))
        // 8× is the fastest.
        #expect(commands.command(for: l, focus: .timeline) == .shuttle(8))
        #expect(commands.command(for: k, focus: .timeline) == .stop)
        #expect(commands.shuttle == 0)
        #expect(commands.command(for: j, focus: .timeline) == .shuttle(-1))
        #expect(commands.command(for: j, focus: .timeline) == .shuttle(-2))
        #expect(commands.command(for: j, focus: .timeline) == .shuttle(-4))
        #expect(commands.command(for: j, focus: .timeline) == .shuttle(-8))
        #expect(commands.command(for: j, focus: .timeline) == .shuttle(-8))
        // The other way starts again at 1×.
        #expect(commands.command(for: l, focus: .timeline) == .shuttle(1))
        #expect(commands.command(for: j, focus: .timeline) == .shuttle(-1))
    }

    @Test func shuttleFollowsThePlaybackItIsGiven() {
        var commands = KeyboardCommands()
        // Playing at 1× (Space, or the ▶ button): L is 2×.
        commands.shuttle = 1
        #expect(commands.command(for: EditorKey(key: "l"), focus: .timeline) == .shuttle(2))
        // Playback stopped by itself at the end: L plays at 1× again.
        commands.shuttle = 0
        #expect(commands.command(for: EditorKey(key: "l"), focus: .timeline) == .shuttle(1))
        // Space pauses what plays, and plays what is paused.
        #expect(commands.command(for: EditorKey(key: "space"), focus: .timeline) == .playPause)
        #expect(commands.shuttle == 0)
        #expect(commands.command(for: EditorKey(key: "space"), focus: .timeline) == .playPause)
        #expect(commands.shuttle == 1)
        // Letters ignored leave the shuttle as it was.
        #expect(commands.command(for: EditorKey(key: "l"), focus: .textField) == nil)
        #expect(commands.shuttle == 1)
    }

    @Test func arrowsStepFramesAndSeconds() {
        #expect(command("←") == .step(frames: -1))
        #expect(command("→") == .step(frames: 1))
        #expect(command("←", [.shift]) == .stepSeconds(-1))
        #expect(command("→", [.shift]) == .stepSeconds(1))
        #expect(command("↑") == .previousEditPoint)
        #expect(command("↓") == .nextEditPoint)
        #expect(command("home") == .start)
        #expect(command("end") == .end)
        // Other modifiers are not the table's.
        #expect(command("←", [.option]) == nil)
        #expect(command("→", [.command]) == nil)
        #expect(command("↑", [.shift]) == nil)
    }

    @Test func nudgeWithShiftIsTenFrames() {
        #expect(command(",") == .nudge(frames: -1))
        #expect(command(".") == .nudge(frames: 1))
        #expect(command(",", [.shift]) == .nudge(frames: -10))
        #expect(command(".", [.shift]) == .nudge(frames: 10))
        #expect(command(",", [.option]) == nil)
    }

    @Test func lettersAreIgnoredInTextFields() {
        #expect(command("c", focus: .textField) == nil)
        #expect(command("c", focus: .timeline) == .split)
        #expect(command("b", [.command], focus: .textField) == .split)
        // Neither in the panel's controls nor in the bar's: their keys are theirs.
        for focus in [EditorFocus.panel, .toolbar, .textField] {
            for key in ["space", "j", "k", "l", "←", "→", "↑", "↓", "home", "end", "c", "delete", "forwardDelete", "i", "o", ",", ".", "z", "n", "escape"] {
                #expect(command(key, focus: focus) == nil, "\(key) in \(focus)")
            }
            #expect(command("x", [.option], focus: focus) == nil)
            #expect(command("[", [.option], focus: focus) == nil)
            #expect(command("]", [.option], focus: focus) == nil)
            #expect(command("z", [.shift], focus: focus) == nil)
            #expect(command("→", [.shift], focus: focus) == nil)
        }
    }

    @Test func everyRowOfTheDesignTableMaps() {
        // Design §5.7, row by row; the letters with the focus on the preview and on the timeline.
        let letters: [(String, KeyModifiers, EditorCommand)] = [
            ("space", [], .playPause),
            ("k", [], .stop),
            ("←", [], .step(frames: -1)), ("→", [], .step(frames: 1)),
            ("←", [.shift], .stepSeconds(-1)), ("→", [.shift], .stepSeconds(1)),
            ("↑", [], .previousEditPoint), ("↓", [], .nextEditPoint),
            ("home", [], .start), ("end", [], .end),
            ("c", [], .split),
            ("delete", [], .delete), ("forwardDelete", [], .delete),
            ("i", [], .markIn), ("o", [], .markOut), ("x", [.option], .clearMarks),
            ("[", [.option], .trimStartToPlayhead), ("]", [.option], .trimEndToPlayhead),
            (",", [], .nudge(frames: -1)), (".", [], .nudge(frames: 1)),
            (",", [.shift], .nudge(frames: -10)), (".", [.shift], .nudge(frames: 10)),
            ("z", [], .addZoom),
            ("n", [], .toggleSnapping),
            ("z", [.shift], .fitTimeline),
            ("escape", [], .deselect),
        ]
        for focus in [EditorFocus.preview, .timeline] {
            for (key, modifiers, expected) in letters {
                #expect(command(key, modifiers, focus: focus) == expected, "\(key) \(modifiers) in \(focus)")
            }
            #expect(command("j", focus: focus) == .shuttle(-1))
            #expect(command("l", focus: focus) == .shuttle(1))
        }
        // With ⌘, whatever has the focus, a text field too.
        let commands: [(String, KeyModifiers, EditorCommand)] = [
            ("b", [.command], .split),
            ("+", [.command], .zoomIn), ("-", [.command], .zoomOut),
            ("1", [.command], .tab(1)), ("2", [.command], .tab(2)), ("3", [.command], .tab(3)),
            ("4", [.command], .tab(4)), ("5", [.command], .tab(5)), ("6", [.command], .tab(6)),
            ("7", [.command], .tab(7)), ("8", [.command], .tab(8)), ("9", [.command], .tab(9)),
            ("i", [.command, .option], .togglePanel),
            ("e", [.command], .export),
            ("o", [.command], .open),
        ]
        for focus in Self.focuses {
            for (key, modifiers, expected) in commands {
                #expect(command(key, modifiers, focus: focus) == expected, "\(key) \(modifiers) in \(focus)")
            }
        }
        // ⌘Z and ⇧⌘Z go through the Edit menu, and Tab and ⇧Tab move the system's focus.
        for focus in Self.focuses {
            #expect(command("z", [.command], focus: focus) == nil)
            #expect(command("z", [.command, .shift], focus: focus) == nil)
            #expect(command("tab", focus: focus) == nil)
            #expect(command("tab", [.shift], focus: focus) == nil)
        }
    }

    @Test func zoomInTakesTheKeyThatTypesPlus() {
        // "=" is the key that types "+" with ⇧ on many layouts; ⌘= and ⌘⇧= scale as ⌘+ does.
        #expect(command("=", [.command]) == .zoomIn)
        #expect(command("=", [.command, .shift]) == .zoomIn)
        #expect(command("+", [.command, .shift]) == .zoomIn)
        #expect(command("-", [.command, .option]) == nil)
        #expect(command("+") == nil)
        // Only the panel's nine tabs.
        #expect(command("0", [.command]) == nil)
    }

    /// ⌘9 is the Annotations tab, the ninth (phase 3 design §5.6); ⌘0 is none.
    @Test func commandNineShowsTheAnnotationsTab() {
        for focus in Self.focuses {
            #expect(command("9", [.command], focus: focus) == .tab(9))
            #expect(command("0", [.command], focus: focus) == nil)
        }
        #expect(command("9", [.command, .shift]) == nil)
        #expect(command("9", [.option]) == nil)
    }

    @Test func keysWithOtherModifiersAreNotTheTables() {
        #expect(command("c", [.shift]) == nil)
        #expect(command("c", [.control]) == nil)
        #expect(command("space", [.command]) == nil)
        #expect(command("b", [.command, .shift]) == nil)
        #expect(command("e", [.command, .option]) == nil)
        #expect(command("x") == nil)
        #expect(command("[") == nil)
    }

    @Test func onlyMovesRepeatWhileTheKeyIsHeld() {
        let repeating: [EditorCommand] = [
            .step(frames: -1), .step(frames: 1), .stepSeconds(-1), .stepSeconds(1), .previousEditPoint, .nextEditPoint,
            .nudge(frames: -1), .nudge(frames: 10), .zoomIn, .zoomOut,
        ]
        let once: [EditorCommand] = [
            .playPause, .shuttle(1), .shuttle(-2), .stop, .start, .end, .split, .delete, .markIn, .markOut, .clearMarks,
            .trimStartToPlayhead, .trimEndToPlayhead, .addZoom, .toggleSnapping, .fitTimeline, .deselect, .tab(1), .togglePanel,
            .export, .open, .layout(.split),
        ]
        for command in repeating { #expect(command.repeats, "\(command)") }
        for command in once { #expect(!command.repeats, "\(command)") }
    }

    @Test func editPointsAreFramesOtherThanThePlayheads() {
        // 30 fps, 300 frames; points at 0, 0.51 s (frame 15), 0.52 s (frame 16), 2 s (frame 60) and the end.
        let points: [Int64] = [0, 510_000_000, 520_000_000, 2_000_000_000, 10_000_000_000]
        func next(_ frame: Int) -> Int? {
            KeyboardCommands.editPointFrame(from: frame, forward: true, points: points, frameRate: 30, frameCount: 300)
        }
        func previous(_ frame: Int) -> Int? {
            KeyboardCommands.editPointFrame(from: frame, forward: false, points: points, frameRate: 30, frameCount: 300)
        }
        #expect(next(0) == 15)
        #expect(next(15) == 16)
        #expect(next(16) == 60)
        // The end is the last frame of the grid.
        #expect(next(60) == 299)
        #expect(next(299) == nil)
        #expect(previous(299) == 60)
        #expect(previous(60) == 16)
        #expect(previous(30) == 16)
        #expect(previous(16) == 15)
        #expect(previous(15) == 0)
        #expect(previous(0) == nil)
        // A point within half a frame of the playhead is its own frame: the next one is the point after it.
        let near: [Int64] = [0, 1_010_000_000, 3_000_000_000]
        #expect(KeyboardCommands.editPointFrame(from: 30, forward: true, points: near, frameRate: 30, frameCount: 300) == 90)
        #expect(KeyboardCommands.editPointFrame(from: 30, forward: false, points: near, frameRate: 30, frameCount: 300) == 0)
        #expect(KeyboardCommands.editPointFrame(from: 0, forward: true, points: [], frameRate: 30, frameCount: 300) == nil)
    }

    @Test func eventsAreKeysOfTheTable() {
        func key(_ characters: String, _ unmodified: String?, _ modifiers: KeyModifiers = []) -> EditorKey? {
            EditorKey(characters: characters, unmodified: unmodified, modifiers: modifiers)
        }
        // The keys without a sign, by their names (AppKit's function keys, and what the layout types for some).
        #expect(key("\u{F702}", "\u{1C}") == EditorKey(key: "←"))
        #expect(key("\u{F703}", "\u{1D}", [.shift]) == EditorKey(key: "→", modifiers: [.shift]))
        #expect(key("\u{F700}", nil) == EditorKey(key: "↑"))
        #expect(key("\u{F701}", nil) == EditorKey(key: "↓"))
        #expect(key("\u{F729}", nil) == EditorKey(key: "home"))
        #expect(key("\u{F72B}", nil) == EditorKey(key: "end"))
        #expect(key("\u{7F}", "\u{7F}") == EditorKey(key: "delete"))
        #expect(key("\u{F728}", "\u{7F}") == EditorKey(key: "forwardDelete"))
        #expect(key("\u{1B}", "\u{1B}") == EditorKey(key: "escape"))
        #expect(key(" ", " ") == EditorKey(key: "space"))
        #expect(key("\u{19}", "\t", [.shift]) == EditorKey(key: "tab", modifiers: [.shift]))
        // Letters and signs in lowercase; with ⇧, what the key types without it.
        #expect(key("c", "c") == EditorKey(key: "c"))
        #expect(key("Z", "z", [.shift]) == EditorKey(key: "z", modifiers: [.shift]))
        #expect(key("<", ",", [.shift]) == EditorKey(key: ",", modifiers: [.shift]))
        #expect(key(";", ",", [.shift]) == EditorKey(key: ",", modifiers: [.shift]))
        #expect(key("+", "=", [.command, .shift]) == EditorKey(key: "=", modifiers: [.command, .shift]))
        // ⌥ is not in what AppKit types ignoring the modifiers.
        #expect(key("x", "x", [.option]) == EditorKey(key: "x", modifiers: [.option]))
        #expect(key("+", "+", [.command]) == EditorKey(key: "+", modifiers: [.command]))
        #expect(key("B", "b", [.command]) == EditorKey(key: "b", modifiers: [.command]))
        // A dead key types nothing.
        #expect(key("", "") == nil)
        #expect(key("", nil, [.shift]) == nil)
    }

    @Test func marksStayInOrder() {
        // I and O put a mark at the playhead; one at or past the other drops that one.
        func marked(_ marks: TimelineMarks, in τ: Int64) -> TimelineMarks {
            var marks = marks
            marks.markIn(at: τ)
            return marks
        }
        func marked(_ marks: TimelineMarks, out τ: Int64) -> TimelineMarks {
            var marks = marks
            marks.markOut(at: τ)
            return marks
        }
        #expect(marked(TimelineMarks(), in: 5) == TimelineMarks(in: 5))
        #expect(marked(TimelineMarks(in: 5), out: 9) == TimelineMarks(in: 5, out: 9))
        #expect(marked(TimelineMarks(in: 5, out: 9), in: 7) == TimelineMarks(in: 7, out: 9))
        #expect(marked(TimelineMarks(in: 5, out: 9), in: 9) == TimelineMarks(in: 9))
        #expect(marked(TimelineMarks(in: 5, out: 9), in: 12) == TimelineMarks(in: 12))
        #expect(marked(TimelineMarks(in: 5, out: 9), out: 2) == TimelineMarks(out: 2))
        #expect(marked(TimelineMarks(in: 5, out: 9), out: 5) == TimelineMarks(out: 5))
        #expect(marked(TimelineMarks(out: 9), in: 3) == TimelineMarks(in: 3, out: 9))
        // A range is both marks, the in before the out.
        #expect(TimelineMarks(in: 3, out: 9).range == 3..<9)
        #expect(TimelineMarks(in: 3).range == nil)
        #expect(TimelineMarks(out: 9).range == nil)
        #expect(TimelineMarks(in: 9, out: 9).range == nil)
    }

    @Test func optionDigitsPickLayouts() {
        let picks: [(String, LayoutKind)] = [
            ("1", .bubble), ("2", .screenOnly), ("3", .split), ("4", .cameraOnly), ("5", .cameraFull),
        ]
        for (digit, kind) in picks {
            #expect(command(digit, [.option], focus: .preview) == .layout(kind))
            #expect(command(digit, [.option], focus: .timeline) == .layout(kind))
            // Never in a text field, nor on a control of the panel or of a bar.
            for focus in [EditorFocus.textField, .panel, .toolbar] { #expect(command(digit, [.option], focus: focus) == nil) }
            // Without ⌥ it is a digit (typed), and with ⌘ it is the panel's tab, as before.
            #expect(command(digit, [], focus: .preview) == nil)
            #expect(command(digit, [.option, .shift], focus: .preview) == nil)
            #expect(command(digit, [.option, .command], focus: .preview) == nil)
        }
        #expect(command("6", [.option], focus: .preview) == nil)
        #expect(command("0", [.option], focus: .preview) == nil)
        // The key an event with ⌥ gives (`charactersIgnoringModifiers`).
        #expect(EditorKey(characters: "3", unmodified: "3", modifiers: [.option]) == EditorKey(key: "3", modifiers: [.option]))
    }
}
