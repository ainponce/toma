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
    /// Saves the Replay's last seconds as a new project (fases 4 y 5 design §10.3): only while it records, never during
    /// a take.
    case saveReplay
}

/// The global shortcuts the user has set, by action; an action without one has none.
public struct HotKeyBindings: Codable, Equatable, Sendable {
    public var combos: [HotKeyAction: KeyCombo]

    public init(combos: [HotKeyAction: KeyCombo]) {
        self.combos = combos
    }

    /// ⇧⌘2 for the island and stopping, ⌥⌘P to pause and resume, ⌥⌘M for a marker, ⌃⌥⌘R to save the Replay; restarting
    /// has none.
    public static let defaults = HotKeyBindings(combos: [
        .islandOrStop: KeyCombo(keyCode: 19, modifiers: [.shift, .command], key: "2"),
        .pauseResume: KeyCombo(keyCode: 35, modifiers: [.option, .command], key: "P"),
        .marker: KeyCombo(keyCode: 46, modifiers: [.option, .command], key: "M"),
        .saveReplay: KeyCombo(keyCode: 15, modifiers: [.control, .option, .command], key: "R"),
    ])

    /// The actions a file without `cleared` (one written before the Replay) knew: the others came after it.
    private static let actionsBeforeCleared: Set<HotKeyAction> = [.islandOrStop, .pauseResume, .marker, .restartTake]

    /// The actions whose shortcuts are registered: at rest the island's, and saving the Replay while it records
    /// (`replayOn`); during a take (from the countdown on) the take's, never the Replay's (it is off while a take records).
    public static func activeActions(isRecording: Bool, replayOn: Bool = false) -> [HotKeyAction] {
        if isRecording { return HotKeyAction.allCases.filter { $0 != .saveReplay } }
        return replayOn ? [.islandOrStop, .saveReplay] : [.islandOrStop]
    }

    private enum CodingKeys: String, CodingKey {
        case combos
        /// The actions without a shortcut, by name (fases 4 y 5 plan 5c, decision 14).
        case cleared
    }

    /// Keyed by the action's name; `cleared` names the actions without a shortcut. An action this version does not know
    /// (saved by a later one) is left out. An action the file names in neither list came after the file was written
    /// (every action of a file with `cleared`, and the Replay's in a file of phase 3, which has no `cleared`) and gets its
    /// default shortcut, unless another action of the file has it: so a phase 3 file gets ⌃⌥⌘R, and an action whose
    /// shortcut the user removed stays without one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decode([String: KeyCombo].self, forKey: .combos)
        let cleared = try container.decodeIfPresent([String].self, forKey: .cleared)
        var combos = Dictionary(uniqueKeysWithValues: saved.compactMap { name, combo in
            HotKeyAction(rawValue: name).map { ($0, combo) }
        })
        let named = Set(saved.keys).union(cleared ?? [])
        for action in HotKeyAction.allCases where !named.contains(action.rawValue) {
            guard cleared != nil || !Self.actionsBeforeCleared.contains(action),
                  let combo = Self.defaults.combos[action], !combos.values.contains(combo)
            else { continue }
            combos[action] = combo
        }
        self.combos = combos
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: combos.map { ($0.key.rawValue, $0.value) }), forKey: .combos)
        try container.encode(HotKeyAction.allCases.filter { combos[$0] == nil }.map(\.rawValue), forKey: .cleared)
    }
}
