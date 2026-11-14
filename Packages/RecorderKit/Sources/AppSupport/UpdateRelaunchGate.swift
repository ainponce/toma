// SPDX-License-Identifier: GPL-3.0-or-later

/// Installing an update relaunches the app. While the app is busy (a take is being recorded, or an export is
/// in progress) the relaunch waits, and it goes ahead once neither is.
@MainActor
public final class UpdateRelaunchGate {
    private var postponedRelaunch: (() -> Void)?

    public init() {}

    /// A relaunch is waiting for the app to be idle.
    public var isHoldingRelaunch: Bool { postponedRelaunch != nil }

    /// Whether to postpone the relaunch the updater is about to do. While busy, `relaunch` is kept, replacing
    /// any kept before, and called once the app is no longer busy; otherwise the updater relaunches now.
    public func shouldPostpone(isBusy: Bool, relaunch: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        postponedRelaunch = relaunch
        return true
    }

    /// Called whenever recording or an export starts or ends, with whether either still runs. Once neither
    /// does, a postponed relaunch goes ahead, once.
    public func busyChanged(isBusy: Bool) {
        guard !isBusy, let relaunch = postponedRelaunch else { return }
        postponedRelaunch = nil
        relaunch()
    }
}
