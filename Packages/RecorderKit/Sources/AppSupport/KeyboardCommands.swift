// SPDX-License-Identifier: GPL-3.0-or-later

/// A key pressed in the editor, as the app reads it from an `NSEvent`: `key` is the letter or the sign the key types
/// without modifiers, in lowercase (`"c"`, `","`, `"+"`, `"1"`), or a key without one: `"←"`, `"→"`, `"↑"`, `"↓"`,
/// `"home"`, `"end"`, `"delete"` (⌫), `"forwardDelete"` (⌦), `"escape"`, `"space"`, `"tab"`.
public struct EditorKey: Equatable, Sendable {
    public var key: String
    public var modifiers: KeyModifiers
    /// The key's virtual key code (`NSEvent.keyCode`), for the keys found by where they are rather than by what they
    /// type: ⌥[ and ⌥] on a layout where "[" and "]" need ⌥ themselves (Spanish, Latin American).
    public var keyCode: UInt16?

    public init(key: String, modifiers: KeyModifiers = [], keyCode: UInt16? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.keyCode = keyCode
    }
}

extension EditorKey {
    /// The key of an event that types `characters` ignoring the modifiers but ⇧ (`NSEvent.charactersIgnoringModifiers`)
    /// and `unmodified` without any (`characters(byApplyingModifiers: [])`): a key without a sign by its name, a letter
    /// or a sign in lowercase, and with ⇧ the one the key types without it (⇧, is "," whatever the layout types with ⇧).
    /// `nil` if it types nothing (a dead key) and has no `keyCode`; with one, a key that types nothing is found by it
    /// alone.
    public init?(characters: String, unmodified: String?, modifiers: KeyModifiers, keyCode: UInt16? = nil) {
        guard let scalar = characters.unicodeScalars.first else {
            guard let keyCode else { return nil }
            self.init(key: "", modifiers: modifiers, keyCode: keyCode)
            return
        }
        if let name = Self.names[scalar.value] {
            self.init(key: name, modifiers: modifiers, keyCode: keyCode)
            return
        }
        let typed = modifiers.contains(.shift) ? unmodified.flatMap { $0.isEmpty ? nil : $0 } ?? characters : characters
        self.init(key: typed.lowercased(), modifiers: modifiers, keyCode: keyCode)
    }

    /// The ANSI keys "[" and "]" (`kVK_ANSI_LeftBracket`, `kVK_ANSI_RightBracket`): ⌥[ and ⌥] where the layout types
    /// something else there.
    public static let leftBracketKeyCode: UInt16 = 0x21
    public static let rightBracketKeyCode: UInt16 = 0x1E

    /// The keys without a sign: AppKit's function keys (`NSUpArrowFunctionKey`…) and the characters some keys type.
    private static let names: [UInt32: String] = [
        0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→", 0xF729: "home", 0xF72B: "end", 0xF728: "forwardDelete",
        0x7F: "delete", 0x08: "delete", 0x1B: "escape", 0x20: "space", 0x09: "tab", 0x19: "tab",
    ]
}

/// What has the keyboard's focus in the editor's window.
public enum EditorFocus: Sendable {
    /// A control of the window's bar or of the timeline's track bar.
    case toolbar
    /// The preview, or nothing in particular (the window itself).
    case preview
    /// A control of the panel.
    case panel
    case timeline
    /// A field being typed in.
    case textField
}

/// What a key does in the editor (design §5.7).
public enum EditorCommand: Equatable, Sendable {
    case playPause
    /// J and L: plays at that speed, signed (−1 is backwards at 1×).
    case shuttle(Int)
    /// K.
    case stop
    case step(frames: Int)
    case stepSeconds(Int)
    case previousEditPoint, nextEditPoint
    /// The start and the end of the output.
    case start, end
    case split
    /// What is selected, or the marked range.
    case delete
    case markIn, markOut, clearMarks
    case trimStartToPlayhead, trimEndToPlayhead
    /// Moves what is selected by that many frames.
    case nudge(frames: Int)
    case addZoom
    case toggleSnapping
    /// The timeline's scale.
    case zoomIn, zoomOut, fitTimeline
    case deselect
    /// The panel's tab: 1 is the first (Background), 6 the last (Audio).
    case tab(Int)
    case togglePanel
    case export
    case open
    /// ⌘A on the timeline: every item of the track with the focus (design §5.5).
    case selectAll

    /// Whether holding the key does it again with each repeat: only what moves the playhead, the selection or the scale
    /// by a step. The rest happens once a press (held L does not run up to 8×).
    public var repeats: Bool {
        switch self {
        case .step, .stepSeconds, .previousEditPoint, .nextEditPoint, .nudge, .zoomIn, .zoomOut: true
        default: false
        }
    }

    /// Whether it changes the document: refused while a drag is under way (its end is an edit of its own, built from the
    /// document as the drag found it), as Undo is.
    public var edits: Bool {
        switch self {
        case .split, .delete, .trimStartToPlayhead, .trimEndToPlayhead, .nudge, .addZoom: true
        default: false
        }
    }
}

/// The editor's keys (design §5.7): which command each one is, given what has the focus. The keys without ⌘ (letters,
/// arrows, Space, ⌫, Esc and those with ⇧ or ⌥) count only with the focus on the preview or on the timeline, never in a
/// text field nor on a control of the panel or of a bar, whose keys are theirs; those with ⌘ count wherever the focus
/// is. ⌘Z and ⇧⌘Z are Edit ▸ Undo and Redo, and Tab and ⇧Tab move the system's focus: neither is here.
///
/// J and L play backwards and forwards; pressed again, 2×, 4× and 8× (`shuttleSpeeds`); K stops. `shuttle` is the
/// speed playing now, which each J, K, L and Space changes; playback also stops by itself (at the end) or from the
/// transport's buttons, so the app sets it from the playback before asking for a key's command.
public struct KeyboardCommands {
    /// The speeds of J and L, one after another.
    public static let shuttleSpeeds = [1, 2, 4, 8]

    /// The speed playing now, signed: 0 stopped, 1 playing forwards at 1×, −2 backwards at 2×.
    public var shuttle = 0

    public init() {}

    /// The command of `key` with the focus on `focus`; `nil` if it has none there. ⌘A is the timeline's only: anywhere
    /// else it is the system's Select All (a field's text).
    public mutating func command(for key: EditorKey, focus: EditorFocus) -> EditorCommand? {
        if key.modifiers.contains(.command) {
            if key.key == "a", key.modifiers == [.command] { return focus == .timeline ? .selectAll : nil }
            return Self.commandKey(key)
        }
        guard focus == .preview || focus == .timeline else { return nil }
        switch (key.key, key.modifiers) {
        case ("space", []):
            shuttle = shuttle == 0 ? 1 : 0
            return .playPause
        case ("l", []):
            shuttle = shuttle > 0 ? Self.faster(shuttle) : 1
            return .shuttle(shuttle)
        case ("j", []):
            shuttle = shuttle < 0 ? -Self.faster(-shuttle) : -1
            return .shuttle(shuttle)
        case ("k", []):
            shuttle = 0
            return .stop
        default:
            return Self.letterKey(key)
        }
    }

    /// The speed after `speed` (positive) in `shuttleSpeeds`; the last one stays.
    private static func faster(_ speed: Int) -> Int {
        shuttleSpeeds.first { $0 > speed } ?? shuttleSpeeds[shuttleSpeeds.count - 1]
    }

    /// A key with ⌘.
    private static func commandKey(_ key: EditorKey) -> EditorCommand? {
        switch (key.key, key.modifiers) {
        case ("b", [.command]): .split
        // "=" types "+" with ⇧ on many layouts: with or without ⇧, it is ⌘+.
        case ("+", [.command]), ("+", [.command, .shift]), ("=", [.command]), ("=", [.command, .shift]): .zoomIn
        case ("-", [.command]): .zoomOut
        case ("i", [.command, .option]): .togglePanel
        case ("e", [.command]): .export
        case ("o", [.command]): .open
        case let (digit, [.command]):
            Int(digit).flatMap { (1...6).contains($0) ? .tab($0) : nil }
        default: nil
        }
    }

    /// A key without ⌘, other than J, K, L and Space.
    private static func letterKey(_ key: EditorKey) -> EditorCommand? {
        switch (key.key, key.modifiers) {
        case ("←", []): .step(frames: -1)
        case ("→", []): .step(frames: 1)
        case ("←", [.shift]): .stepSeconds(-1)
        case ("→", [.shift]): .stepSeconds(1)
        case ("↑", []): .previousEditPoint
        case ("↓", []): .nextEditPoint
        case ("home", []): .start
        case ("end", []): .end
        case ("c", []): .split
        case ("delete", []), ("forwardDelete", []): .delete
        case ("i", []): .markIn
        case ("o", []): .markOut
        case ("x", [.option]): .clearMarks
        case ("[", [.option]): .trimStartToPlayhead
        case ("]", [.option]): .trimEndToPlayhead
        case (",", []): .nudge(frames: -1)
        case (".", []): .nudge(frames: 1)
        case (",", [.shift]): .nudge(frames: -10)
        case (".", [.shift]): .nudge(frames: 10)
        case ("z", []): .addZoom
        case ("n", []): .toggleSnapping
        case ("z", [.shift]): .fitTimeline
        case ("escape", []): .deselect
        default: byPlace(key)
        }
    }

    /// ⌥[ and ⌥] by the key's place, where the layout types something else there (or nothing, a dead key).
    private static func byPlace(_ key: EditorKey) -> EditorCommand? {
        guard key.modifiers == [.option] else { return nil }
        switch key.keyCode {
        case EditorKey.leftBracketKeyCode?: return .trimStartToPlayhead
        case EditorKey.rightBracketKeyCode?: return .trimEndToPlayhead
        default: return nil
        }
    }

    /// ↑ and ↓: the frame of the grid the playhead goes to from frame `frame`, that of the edit point before it (`forward`
    /// false) or after it. `points` are the edit points in output nanoseconds, in order (`EditPoints.all`); each one is at
    /// the frame nearest it of the `frameCount` frames at `frameRate`, and the first one whose frame is not `frame` is the
    /// one gone to: a point within half a frame of the playhead is where it is already. `nil` if there is none.
    public static func editPointFrame(from frame: Int, forward: Bool, points: [Int64], frameRate: Int, frameCount: Int) -> Int? {
        let frames = points.map { PlayheadRule.frame(nearest: Double($0) / 1e9, frameRate: frameRate, frameCount: frameCount) }
        return forward ? frames.first { $0 > frame } : frames.last { $0 < frame }
    }
}

/// The in and out marks of the timeline's ruler, in output nanoseconds (design §5.5): I and O put them at the playhead,
/// ⌥ and a drag on the ruler both at once, ⌥X takes them away.
public struct TimelineMarks: Equatable, Sendable {
    public var `in`: Int64?
    public var out: Int64?

    public init(in: Int64? = nil, out: Int64? = nil) {
        self.in = `in`
        self.out = out
    }

    /// The range marked, from the in to the out; `nil` without both, or with nothing between them.
    public var range: Range<Int64>? {
        guard let start = self.in, let end = out, start < end else { return nil }
        return start..<end
    }

    /// I: the in at `τ`; an out at or before it goes.
    public mutating func markIn(at τ: Int64) {
        self.in = τ
        if let end = out, end <= τ { out = nil }
    }

    /// O: the out at `τ`; an in at or after it goes.
    public mutating func markOut(at τ: Int64) {
        out = τ
        if let start = self.in, start >= τ { self.in = nil }
    }
}
