// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

@MainActor @Test func updatesAreCheckedWhenNothingIsRecorded() {
    let gate = UpdateCheckGate()
    #expect(gate.mayCheck(isRecording: false))
    #expect(!gate.owesCheck)
    #expect(!gate.recordingChanged(isRecording: false), "nothing was refused, so nothing is owed")
}

@MainActor @Test func aCheckDuringATakeIsRefusedAndRunsOnceTheTakeCloses() {
    let gate = UpdateCheckGate()
    #expect(!gate.mayCheck(isRecording: true))
    #expect(gate.owesCheck)
    #expect(!gate.recordingChanged(isRecording: true), "still recording")
    #expect(gate.recordingChanged(isRecording: false))
    #expect(!gate.owesCheck)
    #expect(!gate.recordingChanged(isRecording: true))
    #expect(!gate.recordingChanged(isRecording: false), "only once")
}

@MainActor @Test func severalRefusedChecksAreOwedOnce() {
    let gate = UpdateCheckGate()
    #expect(!gate.mayCheck(isRecording: true))
    #expect(!gate.mayCheck(isRecording: true))
    #expect(gate.recordingChanged(isRecording: false))
    #expect(!gate.recordingChanged(isRecording: false))
}
