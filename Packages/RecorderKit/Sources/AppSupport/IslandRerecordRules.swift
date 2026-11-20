// SPDX-License-Identifier: GPL-3.0-or-later

/// How the island carries a "Re-record from Here" (phase 3 design §8.2, 3d plan decisions 9 and 10) between the recorder
/// (`RecordingController.startRerecord`, `cancelRerecord`, `rerecordEnded`) and the editor hidden for it, which comes back
/// once, when the re-record is over for good.
public enum IslandRerecordRules {
    /// What the app does with an end the recorder told.
    public enum End: Equatable, Sendable {
        /// The editor hears it: it comes back, and applies a take recorded.
        case tellEditor
        /// The island holds the re-record: its start failed and the open island says why, still recording into the
        /// editor's package (Record tries again, with `startRerecord`); the editor stays hidden until the island records it
        /// or is closed, which cancels it (`closesWithoutRecording`) and then tells the editor.
        case holdForRetry
    }

    /// What to do with `outcome`, told while the open island does (`islandShowsStartFailure`) or doesn't say why the take
    /// could not start: nothing recorded because the start failed is held for the user to try again; any other end goes
    /// to the editor.
    public static func end(_ outcome: RerecordOutcome, islandShowsStartFailure: Bool) -> End {
        outcome == .nothing && islandShowsStartFailure ? .holdForRetry : .tellEditor
    }

    /// Whether the open island says why the last take could not start (`IslandMachine.hasStartFailure`).
    public static func showsStartFailure(_ machine: IslandMachine) -> Bool {
        machine.state == .open && machine.hasStartFailure
    }

    /// Whether the island going from `before` to `after` closes the open island (or its choosing on the screen) without
    /// recording: Esc, ✕, a click outside, the island's shortcut, the system's own UI. The re-record it holds is then
    /// cancelled. Its countdown starting is not one; a countdown that ends without a take is the recorder's to tell.
    public static func closesWithoutRecording(from before: IslandState, to after: IslandState) -> Bool {
        (before == .open || before == .choosing) && (after == .rest || after == .peek)
    }
}
