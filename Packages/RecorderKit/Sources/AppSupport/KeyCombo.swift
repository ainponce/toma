// SPDX-License-Identifier: GPL-3.0-or-later

/// The modifier keys of a shortcut.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// A global shortcut: a key and its modifiers. Saved as its key code, its modifiers and the key as the
/// user sees it; what is shown and what Carbon is given are worked out from them.
public struct KeyCombo: Codable, Hashable, Sendable {
    /// The virtual key code (`kVK_…`), the same on every keyboard layout.
    public var keyCode: UInt32
    public var modifiers: KeyModifiers
    /// The key as the user's layout labels it when the shortcut was set ("2", "P", "F5").
    public var key: String

    public init(keyCode: UInt32, modifiers: KeyModifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// The modifiers in macOS's order, ⌃⌥⇧⌘, then the key: "⇧⌘2".
    public var displayString: String {
        let symbols: [(KeyModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }

    /// The modifiers as `RegisterEventHotKey` takes them: `cmdKey` 0x100, `shiftKey` 0x200, `optionKey`
    /// 0x800 and `controlKey` 0x1000.
    public var carbonModifiers: UInt32 {
        let bits: [(KeyModifiers, UInt32)] = [(.command, 0x100), (.shift, 0x200), (.option, 0x800), (.control, 0x1000)]
        return bits.reduce(0) { modifiers.contains($1.0) ? $0 | $1.1 : $0 }
    }

    /// Whether it can be a global shortcut: it needs ⌘ or ⌃. Since macOS 15 the system refuses global
    /// shortcuts whose only modifier is ⌥ or ⌥⇧, and without modifiers, or with ⇧ alone, they would get in
    /// the way of typing.
    public var isAllowedAsGlobalHotKey: Bool {
        modifiers.contains(.command) || modifiers.contains(.control)
    }
}
