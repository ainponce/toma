// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices
import CoreFoundation
import CoreGraphics

/// Which way to move between a display's desktops: ⌃← or ⌃→.
public enum SpaceDirection: Equatable, Sendable {
    case left, right
}

/// How to go from one desktop to another of the same display, by their places in Mission Control's order.
public enum SpaceJump {
    /// The direction and how many presses; `nil` when they are the same desktop.
    public static func presses(from current: Int, to target: Int) -> (direction: SpaceDirection, count: Int)? {
        guard current != target else { return nil }
        return target > current ? (.right, target - current) : (.left, current - target)
    }
}

/// Moves between desktops the way the user does: macOS's own ⌃← and ⌃→ ("Move left a space", "Move right a
/// space"), posted as key presses (notch design §3). Posting needs the Accessibility permission, and the
/// shortcuts must be on: with them off or changed, the presses would reach the app in front (or another
/// shortcut, like the window tiling's ⌃fn-arrows) instead, so nothing is posted and the island explains
/// (plan decisions 27 and 32).
///
/// Whether they are on is read, fresh before every jump, from the preferences System Settings writes (the
/// public `CFPreferencesCopyAppValue`, `AppleSymbolicHotKeys` of `com.apple.symbolichotkeys`), entries 79
/// ("Move left a space") and 81 ("Move right a space"): a missing entry is macOS's default, on; an entry is
/// on only if it is enabled and, if it carries keys (`value.parameters`: character, key code, modifiers), they
/// are ← (123) or → (124) with control and no other of ⌘ ⇧ ⌥ (fn and the keypad allowed, as the arrows
/// have them). macOS writes an entry with only `enabled` once a shortcut is switched without new keys: it
/// keeps its default keys. Preferences that cannot be read, or of another shape, are unknown: nothing is
/// posted either. `CopySymbolicHotKeys` cannot say which shortcut an entry is: other ⌃fn-arrow shortcuts are
/// listed there with the same keys.
@MainActor
public final class SpaceJumper {
    /// Between two presses of one jump (plan decision 32: the owner confirms it).
    public static let pressInterval: Duration = .milliseconds(150)

    public enum Outcome: Equatable, Sendable {
        case jumped(presses: Int)
        /// Nothing posted: the app is not trusted for Accessibility.
        case needsAccessibility
        /// Nothing posted: ⌃← or ⌃→ is off or changed in System Settings.
        case shortcutsOff
        /// Nothing posted: that desktop is the one in front.
        case alreadyThere
    }

    private let isTrusted: @MainActor () -> Bool
    private let shortcutsEnabled: @MainActor () -> Bool
    private let post: @MainActor (SpaceDirection) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        isTrusted: @escaping @MainActor () -> Bool,
        shortcutsEnabled: @escaping @MainActor () -> Bool,
        post: @escaping @MainActor (SpaceDirection) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.isTrusted = isTrusted
        self.shortcutsEnabled = shortcutsEnabled
        self.post = post
        self.sleep = sleep
    }

    /// From the desktop at `current` to the one at `target`, one press per desktop in between.
    public func jump(from current: Int, to target: Int) async -> Outcome {
        guard let plan = SpaceJump.presses(from: current, to: target) else { return .alreadyThere }
        return await press(plan.direction, times: plan.count)
    }

    /// One desktop to the left or the right: the island's ← and →, without a list of desktops.
    public func step(_ direction: SpaceDirection) async -> Outcome {
        await press(direction, times: 1)
    }

    /// The shortcuts first: with them off, the permission would not be enough.
    private func press(_ direction: SpaceDirection, times: Int) async -> Outcome {
        guard shortcutsEnabled() else { return .shortcutsOff }
        guard isTrusted() else { return .needsAccessibility }
        for press in 0..<times {
            if press > 0 {
                do { try await sleep(Self.pressInterval) } catch { return .jumped(presses: press) }
            }
            post(direction)
        }
        return .jumped(presses: times)
    }

    /// The jumper that posts to the system.
    public static func live() -> SpaceJumper {
        SpaceJumper(
            isTrusted: { AXIsProcessTrusted() },
            shortcutsEnabled: { readShortcuts() == .on },
            post: { postControlArrow($0) },
            sleep: { try await Task.sleep(for: $0) })
    }

    // MARK: - The system

    /// What macOS's preferences say about "Move left a space" and "Move right a space", both.
    enum ShortcutsState: Equatable, Sendable {
        case on, off
        /// The preferences cannot be read, or have another shape.
        case unknown
    }

    private nonisolated static let leftArrow: CGKeyCode = 123
    private nonisolated static let rightArrow: CGKeyCode = 124
    /// The entries of "Move left a space" and "Move right a space" in `AppleSymbolicHotKeys`.
    private nonisolated static let moveLeftASpace = "79"
    private nonisolated static let moveRightASpace = "81"
    /// ⇧ ⌃ ⌥ ⌘ as the preferences write them (`NSEvent.ModifierFlags`); the others say which keys need fn or
    /// are on the keypad.
    private nonisolated static let comparedModifiers = 0x1E_0000
    private nonisolated static let control = 0x4_0000

    /// The shortcuts' state now: System Settings writes them from another process.
    nonisolated static func readShortcuts() -> ShortcutsState {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        return shortcutsState(in: CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain))
    }

    /// `symbolicHotKeys` is the value of `AppleSymbolicHotKeys`: on when both shortcuts are, unknown when
    /// either cannot be told, off otherwise.
    nonisolated static func shortcutsState(in symbolicHotKeys: Any?) -> ShortcutsState {
        guard let hotKeys = symbolicHotKeys as? [String: Any] else { return .unknown }
        let states = [state(of: hotKeys[moveLeftASpace], key: leftArrow), state(of: hotKeys[moveRightASpace], key: rightArrow)]
        if states.contains(.unknown) { return .unknown }
        return states.allSatisfy { $0 == .on } ? .on : .off
    }

    private nonisolated static func state(of entry: Any?, key: CGKeyCode) -> ShortcutsState {
        // Never changed: macOS's default, on.
        guard let entry else { return .on }
        guard let entry = entry as? [String: Any], let enabled = entry["enabled"] as? Bool else { return .unknown }
        guard enabled else { return .off }
        // Switched without new keys: its default keys.
        guard let value = entry["value"] else { return .on }
        guard let value = value as? [String: Any], let parameters = value["parameters"] as? [Int], parameters.count >= 3 else {
            return .unknown
        }
        return parameters[1] == Int(key) && parameters[2] & comparedModifiers == control ? .on : .off
    }

    /// ⌃← or ⌃→ down and up, with the flags of the arrows of a real keyboard (fn and the keypad), into the
    /// system's stream of events.
    private static func postControlArrow(_ direction: SpaceDirection) {
        let source = CGEventSource(stateID: .hidSystemState)
        let key = direction == .left ? leftArrow : rightArrow
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown) else { continue }
            event.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Whether the open island losing the keyboard is the desktop changing under it, not a click elsewhere: on
/// the desktop it switches to, macOS makes another app's window key, which would close the island (it closes
/// when the keyboard goes to another app). It is while a jump posts its presses and for `switchWait` after
/// the last one (until its desktop is in front), and for `grace` after any change of the desktop in front
/// (`NSWorkspace.activeSpaceDidChangeNotification`, which may come before or after the keyboard leaves).
/// Only the first loss in that time is the desktop's: the next one is the user clicking elsewhere. `now` is
/// a monotonic time, as `IslandMachine`'s.
public struct SpaceSwitchGrace: Equatable, Sendable {
    public static let grace: Duration = .milliseconds(500)
    public static let switchWait: Duration = .seconds(1)

    private var isJumping = false
    /// Until when the last jump's desktop may still be coming.
    private var switchEnd: Duration?
    /// Until when the last change of desktop may still take the keyboard.
    private var graceEnd: Duration?
    /// The desktop already took the keyboard once since the last jump or change.
    private var forgave = false

    public init() {}

    public mutating func jumpBegan() {
        isJumping = true
        forgave = false
    }

    /// `posted`: the jump posted presses (`SpaceJumper.Outcome.jumped`); otherwise nothing switches.
    public mutating func jumpEnded(posted: Bool, at now: Duration) {
        isJumping = false
        switchEnd = posted ? now + Self.switchWait : nil
        if posted { forgave = false }
    }

    public mutating func spaceChanged(at now: Duration) {
        graceEnd = now + Self.grace
        forgave = false
    }

    /// The open island lost the keyboard: `true` if that is the desktop changing (the island stays open and
    /// takes the keyboard back), `false` if it is a click elsewhere.
    public mutating func keyboardLost(at now: Duration) -> Bool {
        let switching = isJumping || switchEnd.map { now < $0 } == true || graceEnd.map { now < $0 } == true
        guard switching, !forgave else { return false }
        forgave = true
        return true
    }
}
