// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Carbon
import Observation
import SwiftUI
import os

/// The app's global shortcuts, registered with Carbon's `RegisterEventHotKey` (no Accessibility
/// permission, no global event monitor): at rest only the island's, during a take all of them
/// (`HotKeyBindings.activeActions`). Each is registered exclusively, so a combination another app holds
/// that way is refused (`eventHotKeyExistsErr`); macOS's own shortcuts are compared with the active
/// ones of `CopySymbolicHotKeys` first, because the ordinary registration lets several apps have the
/// same combination without an error. A shortcut that cannot be had is listed in `busy`.
@MainActor @Observable
final class HotKeyCenter {
    private(set) var bindings: HotKeyBindings
    /// The active actions whose shortcut macOS or another app uses: pressing it does nothing for Toma.
    private(set) var busy: Set<HotKeyAction> = []

    /// A registered shortcut was pressed.
    @ObservationIgnored var perform: (HotKeyAction) -> Void = { _ in }

    @ObservationIgnored private var registered: [HotKeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var isRecording = false
    /// While a shortcut is being typed in the settings, none is registered, so it reaches the settings.
    @ObservationIgnored private var isSuspended = false

    /// "Toma", in the ID of every shortcut the app registers.
    private static let signature: OSType = 0x546F_6D61
    /// The modifiers a symbolic hot key is compared by (⌘, ⇧, ⌥, ⌃); its others say which keys are on
    /// the keypad or need fn.
    private static let comparedModifiers: Int = 0x1B00

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Shortcuts")

    init(bindings: HotKeyBindings) {
        self.bindings = bindings
        installHandler()
        register()
    }

    /// New shortcuts, from the settings.
    func update(bindings: HotKeyBindings) {
        guard bindings != self.bindings else { return }
        self.bindings = bindings
        register()
    }

    /// A take started (its countdown) or ended.
    func update(isRecording: Bool) {
        guard isRecording != self.isRecording else { return }
        self.isRecording = isRecording
        register()
    }

    /// Takes every shortcut away while the settings record one, and gives them back after.
    func suspend(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        register()
    }

    /// Whether `combo` is free: none of macOS's active shortcuts, and no other app holds it. Ask while
    /// suspended, so none of Toma's own is in the way.
    func isAvailable(_ combo: KeyCombo) -> Bool {
        guard !Self.isSystemShortcut(combo) else { return false }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: Self.signature, id: 0), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        if status == noErr, let reference { UnregisterEventHotKey(reference) }
        return status != eventHotKeyExistsErr
    }

    // MARK: - Registering

    private func register() {
        for reference in registered.values { UnregisterEventHotKey(reference) }
        registered = [:]
        var busy: Set<HotKeyAction> = []
        if !isSuspended {
            for action in HotKeyBindings.activeActions(isRecording: isRecording) {
                guard let combo = bindings.combos[action] else { continue }
                guard !Self.isSystemShortcut(combo) else {
                    busy.insert(action)
                    continue
                }
                var reference: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: Self.signature, id: Self.id(of: action)),
                    GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
                if status == noErr, let reference {
                    registered[action] = reference
                } else {
                    busy.insert(action)
                    if status != eventHotKeyExistsErr {
                        Self.logger.error("Cannot register \(combo.displayString, privacy: .public): \(status)")
                    }
                }
            }
        }
        if busy != self.busy { self.busy = busy }
    }

    /// Whether `combo` is one of macOS's shortcuts that are on (System Settings → Keyboard → Keyboard
    /// Shortcuts).
    private static func isSystemShortcut(_ combo: KeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let shortcuts = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        let modifiers = Int(combo.carbonModifiers) & comparedModifiers
        return shortcuts.contains { shortcut in
            guard shortcut[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                let code = shortcut[kHISymbolicHotKeyCode as String] as? Int,
                let flags = shortcut[kHISymbolicHotKeyModifiers as String] as? Int
            else { return false }
            return code == Int(combo.keyCode) && flags & comparedModifiers == modifiers
        }
    }

    /// 1-based, in `HotKeyAction.allCases` order: 0 is the probe of `isAvailable`.
    private static func id(of action: HotKeyAction) -> UInt32 {
        UInt32((HotKeyAction.allCases.firstIndex(of: action) ?? 0) + 1)
    }

    // MARK: - Pressed

    private func installHandler() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
                // Carbon delivers hot keys on the main thread, with the app's events.
                MainActor.assumeIsolated { center.pressed(id: id.id) }
                return noErr
            },
            1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { Self.logger.error("Cannot listen to the shortcuts: \(status)") }
    }

    private func pressed(id: UInt32) {
        guard let action = registered.keys.first(where: { Self.id(of: $0) == id }) else { return }
        perform(action)
    }
}

extension KeyCombo {
    /// The same shortcut for a menu item, which shows it; `nil` for a key a menu cannot name with one character.
    var menuShortcut: KeyboardShortcut? {
        guard key.count == 1, let character = key.lowercased().first else { return nil }
        var flags: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: flags)
    }

    /// The shortcut a key press makes: its key code, its modifiers and the key as the current layout
    /// labels it without modifiers (so ⇧⌘2 is "2", not "@").
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: Self.keyName(event))
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_F20: "F20",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        let plain = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        return plain.isEmpty ? "#\(event.keyCode)" : plain
    }
}
