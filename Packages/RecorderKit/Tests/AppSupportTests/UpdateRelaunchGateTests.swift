// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

@MainActor @Test func anUpdateRelaunchesRightAwayWhenNothingIsInProgress() {
    let gate = UpdateRelaunchGate()
    var relaunches = 0
    #expect(!gate.shouldPostpone(isBusy: false) { relaunches += 1 })
    #expect(!gate.isHoldingRelaunch)
    gate.busyChanged(isBusy: false)
    #expect(relaunches == 0, "Sparkle relaunches by itself when it is not postponed")
}

@MainActor @Test func anUpdateWaitsForTheTakeToCloseAndRelaunchesOnce() {
    let gate = UpdateRelaunchGate()
    var relaunches = 0
    #expect(gate.shouldPostpone(isBusy: true) { relaunches += 1 })
    #expect(gate.isHoldingRelaunch)
    gate.busyChanged(isBusy: true)
    #expect(relaunches == 0)
    gate.busyChanged(isBusy: false)
    #expect(relaunches == 1)
    #expect(!gate.isHoldingRelaunch)
    gate.busyChanged(isBusy: true)
    gate.busyChanged(isBusy: false)
    #expect(relaunches == 1)
}

/// The app reports busy as recording or exporting: a relaunch held for a take does not fire at the take's end
/// while an export that started meanwhile runs, and fires exactly once when both have ended.
@MainActor @Test func noRelaunchWhileExportingAndOneOnceBothEnd() {
    let gate = UpdateRelaunchGate()
    var recording = true, exporting = false
    var isBusy: Bool { recording || exporting }
    var relaunches = 0
    #expect(gate.shouldPostpone(isBusy: isBusy) { relaunches += 1 })
    exporting = true
    gate.busyChanged(isBusy: isBusy)
    recording = false
    gate.busyChanged(isBusy: isBusy)
    #expect(relaunches == 0, "the export is still running")
    exporting = false
    gate.busyChanged(isBusy: isBusy)
    #expect(relaunches == 1)
    gate.busyChanged(isBusy: isBusy)
    #expect(relaunches == 1)

    // An update that comes during an export alone waits for it too.
    exporting = true
    #expect(gate.shouldPostpone(isBusy: isBusy) { relaunches += 1 })
    exporting = false
    gate.busyChanged(isBusy: isBusy)
    #expect(relaunches == 2)
}

@MainActor @Test func onlyTheLatestPostponedRelaunchGoesAhead() {
    let gate = UpdateRelaunchGate()
    var calls: [String] = []
    #expect(gate.shouldPostpone(isBusy: true) { calls.append("first") })
    #expect(gate.shouldPostpone(isBusy: true) { calls.append("second") })
    gate.busyChanged(isBusy: false)
    #expect(calls == ["second"])
}
