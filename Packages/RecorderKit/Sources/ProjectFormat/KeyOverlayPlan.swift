// SPDX-License-Identifier: GPL-3.0-or-later

/// The keys pressed during the take, drawn over the output (phase 2 design §7.4): `EditDocument.keys`. The look is defined
/// in code (`keyOverlay-1`). A value that is not one of these makes the document invalid, not newer.
public struct KeyOverlayPlan: Codable, Equatable, Sendable {
    public var mode: KeyOverlayMode
    public var position: KeyOverlayPosition
    public var size: OverlaySize

    /// What a document of phase 1 has once migrated, and a new one: off, at the bottom in the middle, medium.
    public static let legacy = KeyOverlayPlan(mode: .off, position: .bottomCenter, size: .medium)

    public init(mode: KeyOverlayMode, position: KeyOverlayPosition, size: OverlaySize) {
        self.mode = mode
        self.position = position
        self.size = size
    }
}

public enum KeyOverlayMode: String, Codable, Sendable, CaseIterable {
    case off
    /// Only the shortcuts: a key with ⌘ or ⌃, or with any modifier on a special key.
    case shortcuts
    /// The shortcuts, and what is typed.
    case all
}

public enum KeyOverlayPosition: String, Codable, Sendable, CaseIterable {
    case bottomCenter, bottomLeading, bottomTrailing, top
}
