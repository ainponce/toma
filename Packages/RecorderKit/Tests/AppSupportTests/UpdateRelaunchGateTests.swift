// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

@MainActor @Test func anUpdateRelaunchesRightAwayWhenNothingIsRecorded() {
    let gate = UpdateRelaunchGate()
    var relaunches = 0
    #expect(!gate.shouldPostpone(isRecording: false) { relaunches += 1 })
    #expect(!gate.isHoldingRelaunch)
    gate.recordingChanged(isRecording: false)
    #expect(relaunches == 0, "Sparkle relaunches by itself when it is not postponed")
}

@MainActor @Test func anUpdateWaitsForTheTakeToCloseAndRelaunchesOnce() {
    let gate = UpdateRelaunchGate()
    var relaunches = 0
    #expect(gate.shouldPostpone(isRecording: true) { relaunches += 1 })
    #expect(gate.isHoldingRelaunch)
    gate.recordingChanged(isRecording: true)
    #expect(relaunches == 0)
    gate.recordingChanged(isRecording: false)
    #expect(relaunches == 1)
    #expect(!gate.isHoldingRelaunch)
    gate.recordingChanged(isRecording: true)
    gate.recordingChanged(isRecording: false)
    #expect(relaunches == 1)
}

@MainActor @Test func onlyTheLatestPostponedRelaunchGoesAhead() {
    let gate = UpdateRelaunchGate()
    var calls: [String] = []
    #expect(gate.shouldPostpone(isRecording: true) { calls.append("first") })
    #expect(gate.shouldPostpone(isRecording: true) { calls.append("second") })
    gate.recordingChanged(isRecording: false)
    #expect(calls == ["second"])
}
