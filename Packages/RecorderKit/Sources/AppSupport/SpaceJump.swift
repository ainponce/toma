// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices
import Carbon
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
/// shortcuts must be on: with them off or changed, the presses would reach the app in front instead, so
/// nothing is posted and the island explains (plan decisions 27 and 32).
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
            shortcutsEnabled: { controlArrowsAreOn() },
            post: { postControlArrow($0) },
            sleep: { try await Task.sleep(for: $0) })
    }

    // MARK: - The system

    private nonisolated static let leftArrow: CGKeyCode = 123
    private nonisolated static let rightArrow: CGKeyCode = 124
    /// The modifiers a symbolic hot key is compared by (⌘, ⇧, ⌥, ⌃); the others say which keys are on the
    /// keypad or need fn, as the arrows do.
    private nonisolated static let comparedModifiers = 0x1B00

    /// Whether macOS's shortcuts list has both "Move left a space" and "Move right a space" on, as ⌃← and ⌃→
    /// (`CopySymbolicHotKeys`).
    private static func controlArrowsAreOn() -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let hotKeys = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        return controlArrowsAreOn(in: hotKeys)
    }

    /// Whether `symbolicHotKeys` (as `CopySymbolicHotKeys` lists them) has an active ⌃← and an active ⌃→:
    /// control and no other of ⌘ ⇧ ⌥ (macOS 26.6.2 lists them as `controlKey` plus the arrows' fn,
    /// `0x21000`). Changed to another combination, they are not.
    nonisolated static func controlArrowsAreOn(in symbolicHotKeys: [[String: Any]]) -> Bool {
        func isOn(_ key: CGKeyCode) -> Bool {
            symbolicHotKeys.contains { hotKey in
                guard hotKey[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                    let code = hotKey[kHISymbolicHotKeyCode as String] as? Int,
                    let modifiers = hotKey[kHISymbolicHotKeyModifiers as String] as? Int
                else { return false }
                return code == Int(key) && modifiers & comparedModifiers == controlKey
            }
        }
        return isOn(leftArrow) && isOn(rightArrow)
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
