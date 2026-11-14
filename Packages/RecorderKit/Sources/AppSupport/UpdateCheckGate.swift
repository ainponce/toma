// SPDX-License-Identifier: GPL-3.0-or-later

/// No update check while a take is being recorded, so an update window never shows up in a recording. A
/// check refused meanwhile is owed: it runs once the take is closed, not a whole check interval later.
@MainActor
public final class UpdateCheckGate {
    /// A check was refused during the take and has not run since.
    public private(set) var owesCheck = false

    public init() {}

    /// Whether the updater may check for updates now: not while recording, and then one check is owed.
    public func mayCheck(isRecording: Bool) -> Bool {
        guard isRecording else { return true }
        owesCheck = true
        return false
    }

    /// Called whenever recording starts or stops. Returns whether to check for updates now: once nothing
    /// is recorded and a check is owed, once.
    public func recordingChanged(isRecording: Bool) -> Bool {
        guard !isRecording, owesCheck else { return false }
        owesCheck = false
        return true
    }
}
