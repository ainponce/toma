// SPDX-License-Identifier: GPL-3.0-or-later

/// What a global shortcut does.
public enum HotKeyAction: String, Codable, CaseIterable, Sendable {
    /// Opens the island at rest (and closes it if it is open), cancels the countdown and stops the take.
    case islandOrStop
    /// Pauses the take, or resumes it.
    case pauseResume
    /// Marks this moment of the take.
    case marker
    /// Restarts the take: it goes to the trash and a new one starts.
    case restartTake
}

/// The global shortcuts the user has set, by action; an action without one has none.
public struct HotKeyBindings: Codable, Equatable, Sendable {
    public var combos: [HotKeyAction: KeyCombo]

    public init(combos: [HotKeyAction: KeyCombo]) {
        self.combos = combos
    }

    /// ⇧⌘2 for the island and stopping, ⌥⌘P to pause and resume, ⌥⌘M for a marker; restarting has none.
    public static let defaults = HotKeyBindings(combos: [
        .islandOrStop: KeyCombo(keyCode: 19, modifiers: [.shift, .command], key: "2"),
        .pauseResume: KeyCombo(keyCode: 35, modifiers: [.option, .command], key: "P"),
        .marker: KeyCombo(keyCode: 46, modifiers: [.option, .command], key: "M"),
    ])

    /// The actions whose shortcuts are registered: at rest only the island's; during a take (from the
    /// countdown on) all of them.
    public static func activeActions(isRecording: Bool) -> [HotKeyAction] {
        isRecording ? HotKeyAction.allCases : [.islandOrStop]
    }

    private enum CodingKeys: String, CodingKey {
        case combos
    }

    /// Keyed by the action's name. An action this version does not know (saved by a later one) is left out.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decode([String: KeyCombo].self, forKey: .combos)
        combos = Dictionary(uniqueKeysWithValues: saved.compactMap { name, combo in
            HotKeyAction(rawValue: name).map { ($0, combo) }
        })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: combos.map { ($0.key.rawValue, $0.value) }), forKey: .combos)
    }
}
