// SPDX-License-Identifier: GPL-3.0-or-later

/// Installing an update relaunches the app. While a take is being recorded the relaunch waits, and it goes
/// ahead once the take is closed.
@MainActor
public final class UpdateRelaunchGate {
    private var postponedRelaunch: (() -> Void)?

    public init() {}

    /// A relaunch is waiting for the take to close.
    public var isHoldingRelaunch: Bool { postponedRelaunch != nil }

    /// Whether to postpone the relaunch the updater is about to do. While recording, `relaunch` is kept,
    /// replacing any kept before, and called once the take is closed; otherwise the updater relaunches now.
    public func shouldPostpone(isRecording: Bool, relaunch: @escaping () -> Void) -> Bool {
        guard isRecording else { return false }
        postponedRelaunch = relaunch
        return true
    }

    /// Called whenever recording starts or stops. Once nothing is recorded, a postponed relaunch goes
    /// ahead, once.
    public func recordingChanged(isRecording: Bool) {
        guard !isRecording, let relaunch = postponedRelaunch else { return }
        postponedRelaunch = nil
        relaunch()
    }
}
