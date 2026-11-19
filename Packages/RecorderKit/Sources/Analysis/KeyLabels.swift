// SPDX-License-Identifier: GPL-3.0-or-later

/// What the keys pressed are called on screen, and which of them are shortcuts (`keyOverlay-1`, phase 2 design §7.4,
/// plan decision 13). Pure: the recorder's codes and flags (`KeyPressRecorder.modifierMask`) in, text out.
public enum KeyLabels {
    /// The modifier bits of `InputEvent.Kind.keyPress`' `mods`: the same as `CGEventFlags.maskShift`, `.maskControl`,
    /// `.maskAlternate`, `.maskCommand` and `.maskSecondaryFn`, repeated here so `Analysis` does not read CoreGraphics.
    public static let shiftBit: UInt32 = 0x0002_0000
    public static let controlBit: UInt32 = 0x0004_0000
    public static let optionBit: UInt32 = 0x0008_0000
    public static let commandBit: UInt32 = 0x0010_0000
    public static let functionBit: UInt32 = 0x0080_0000

    /// The modifiers drawn, in the order ⌘ ⇧ ⌥ ⌃. fn is never drawn: the arrows and the function keys carry it.
    public static func modifiers(_ mods: UInt32) -> [String] {
        var labels: [String] = []
        if mods & commandBit != 0 { labels.append("⌘") }
        if mods & shiftBit != 0 { labels.append("⇧") }
        if mods & optionBit != 0 { labels.append("⌥") }
        if mods & controlBit != 0 { labels.append("⌃") }
        return labels
    }

    /// The label of a key, by its virtual key code for the special ones (`␣` for the space) and by what it types for the
    /// rest, a letter in capitals; `nil` for one that is neither. See `key(code:chars:mods:)` for a shifted key.
    public static func key(code: UInt16, chars: String?) -> String? {
        key(code: code, chars: chars, mods: 0)
    }

    /// As `key(code:chars:)`, for a key pressed with `mods`: `chars` is what it types with only ⇧ applied, so with ⇧ held
    /// a symbol is taken back to the key's own one on a US keyboard (`$` is "4" in "⌘ ⇧ 4").
    public static func key(code: UInt16, chars: String?, mods: UInt32) -> String? {
        if code == spaceCode { return "␣" }
        if let label = specialLabels[code] { return label }
        guard var text = chars, !text.isEmpty else { return nil }
        if mods & shiftBit != 0, text.count == 1, let own = unshifted[text.first!] { text = String(own) }
        let upper = text.uppercased()
        return upper.count == text.count ? upper : text
    }

    /// Whether the key is one that does not type text: the arrows, ↩, ⌫, ⌦, ⇥, esc, F1 to F20, ⇞ ⇟ ↖ ↘. Not the space.
    public static func isSpecial(code: UInt16) -> Bool {
        specialLabels[code] != nil
    }

    /// Whether a key pressed with `mods` is a shortcut: ⌘ or ⌃ on any key, or any of ⇧ ⌥ ⌃ ⌘ on a special key. fn does
    /// not count (a bare arrow carries it).
    public static func isShortcut(code: UInt16, mods: UInt32) -> Bool {
        if mods & (commandBit | controlBit) != 0 { return true }
        return mods & (shiftBit | optionBit) != 0 && isSpecial(code: code)
    }

    static func specialLabel(code: UInt16) -> String? { specialLabels[code] }

    static let returnCodes: Set<UInt16> = [36, 76]
    static let deleteCode: UInt16 = 51
    static let spaceCode: UInt16 = 49

    private static let specialLabels: [UInt16: String] = [
        36: "↩", 76: "↩", 48: "⇥", 51: "⌫", 53: "esc", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let unshifted: [Character: Character] = {
        let shifted = Array("!@#$%^&*()_+{}|:\"<>?~")
        let own = Array("1234567890-=[]\\;',./`")
        return Dictionary(uniqueKeysWithValues: zip(shifted, own))
    }()
}
