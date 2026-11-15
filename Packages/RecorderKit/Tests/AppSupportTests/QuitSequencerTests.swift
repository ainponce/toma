// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import AppSupport
import Testing

/// When a quit answered `.terminateLater` goes ahead: once the exports have ended (their partial files
/// removed), and once the take is closed or the time limit has passed, whichever comes first, only once.
@MainActor @Suite struct QuitSequencerTests {
    @Test func exportCancelRepliesOnlyAfterExportsEnd() async {
        let rig = QuitRig(timeLimit: .never)
        rig.exports.close()
        // Powering off while recording: the take starts closing now, and is closed while the export that the
        // quit then cancels has not ended yet.
        rig.sequencer.powerOff(isRecording: true)
        #expect(rig.sequencer.isPoweringOff)
        #expect(rig.sequencer.shouldTerminate(.cancelExportFirst(alsoClosingTake: true), confirmCancelExport: nobodyIsAsked) == .terminateLater)
        await waitUntil { rig.calls.closesEnded == 1 && rig.calls.exportCancels == 1 }
        await settle()
        #expect(rig.calls.replies.isEmpty, "the export has not removed its partial file yet")

        rig.exports.open()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [true])
    }

    @Test func quitAfterTimeLimitDuringExportRepliesOnceExportsEnd() async {
        let rig = QuitRig(timeLimit: .alreadyPassed)
        rig.take.close()  // the take takes longer than the time limit to close
        rig.exports.close()
        rig.sequencer.powerOff(isRecording: true)
        await waitUntil { rig.sequencer.quitTimeLimitPassed }
        #expect(rig.sequencer.quitTimeLimitPassed)
        #expect(rig.sequencer.shouldTerminate(.cancelExportFirst(alsoClosingTake: true), confirmCancelExport: nobodyIsAsked) == .terminateLater)
        await waitUntil { rig.calls.exportCancels == 1 }
        await settle()
        #expect(rig.calls.replies.isEmpty, "the export has not removed its partial file yet")

        rig.exports.open()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [false])
        #expect(rig.calls.closesEnded == 0, "the quit did not wait for the take")
        #expect(rig.calls.closeCalls == 1, "the take is closed once")

        rig.take.open()
        await waitUntil { rig.calls.closesEnded == 1 }
        await settle()
        #expect(rig.calls.replies == [false])
    }

    @Test func closeTakeRepliesOnceEvenIfDeadlinePasses() async {
        let rig = QuitRig(timeLimit: .alreadyPassed)
        rig.take.close()
        #expect(rig.sequencer.shouldTerminate(.closeTakeFirst, confirmCancelExport: nobodyIsAsked) == .terminateLater)
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [false])

        rig.take.open()
        await waitUntil { rig.calls.closesEnded == 1 }
        await settle()
        #expect(rig.calls.replies == [false], "only the first answer replies")
    }

    @Test func aTakeClosedInTimeLetsTheQuitGoAhead() async {
        let rig = QuitRig(timeLimit: .never)
        rig.take.close()
        #expect(rig.sequencer.shouldTerminate(.closeTakeFirst, confirmCancelExport: nobodyIsAsked) == .terminateLater)
        await waitUntil { rig.calls.closeCalls == 1 }
        await settle()
        #expect(rig.calls.replies.isEmpty, "the take is still closing")

        rig.take.open()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [true])
        #expect(rig.calls.exportCancels == 0)
    }

    /// The quit that follows a power off waits for the close the power off started, and does not start another.
    @Test func poweringOffStartsClosingTheTakeTheQuitWaitsFor() async {
        let idle = QuitRig(timeLimit: .never)
        idle.sequencer.powerOff(isRecording: false)
        #expect(idle.sequencer.isPoweringOff)
        await settle()
        #expect(idle.calls.closeCalls == 0, "nothing to close")

        let rig = QuitRig(timeLimit: .never)
        rig.take.close()
        #expect(!rig.sequencer.isPoweringOff)
        rig.sequencer.powerOff(isRecording: true)
        await waitUntil { rig.calls.closeCalls == 1 }
        #expect(rig.sequencer.shouldTerminate(.closeTakeFirst, confirmCancelExport: nobodyIsAsked) == .terminateLater)
        await settle()
        #expect(rig.calls.closeCalls == 1)
        #expect(rig.calls.replies.isEmpty)

        rig.take.open()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [true])
    }

    /// Closing for a power off already took longer than the time limit when the system asks to quit.
    @Test func quitAfterTheTimeLimitWhileRecordingQuitsNow() async {
        let rig = QuitRig(timeLimit: .alreadyPassed)
        rig.take.close()
        rig.sequencer.powerOff(isRecording: true)
        await waitUntil { rig.sequencer.quitTimeLimitPassed }
        #expect(rig.sequencer.shouldTerminate(.closeTakeFirst, confirmCancelExport: nobodyIsAsked) == .terminateNow)
        await settle()
        #expect(rig.calls.replies.isEmpty, "a quit answered now is not replied to")

        rig.take.open()
        await waitUntil { rig.calls.closesEnded == 1 }
        await settle()
        #expect(rig.calls.replies.isEmpty)
    }

    @Test func theUserIsAskedBeforeAnExportIsCancelled() async {
        let rig = QuitRig(timeLimit: .never)
        var asked = 0
        #expect(rig.sequencer.shouldTerminate(.confirmCancelExport(alsoClosingTake: true)) { asked += 1; return false } == .terminateCancel)
        #expect(asked == 1)
        await settle()
        #expect(rig.calls.exportCancels == 0 && rig.calls.closeCalls == 0 && rig.calls.replies.isEmpty, "the app keeps running")

        rig.exports.close()
        #expect(rig.sequencer.shouldTerminate(.confirmCancelExport(alsoClosingTake: false)) { asked += 1; return true } == .terminateLater)
        #expect(asked == 2)
        await waitUntil { rig.calls.exportCancels == 1 }
        await settle()
        #expect(rig.calls.replies.isEmpty, "the export has not removed its partial file yet")

        rig.exports.open()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [true])
        #expect(rig.calls.closeCalls == 0, "no take to close")
    }
}

/// Nobody is asked: the quit does not ask about the export.
@MainActor private func nobodyIsAsked() -> Bool {
    Issue.record("asked whether to cancel the export")
    return false
}

/// Lets the main-actor jobs already queued run up to their next wait.
@MainActor private func settle() async {
    for _ in 0..<10 { await Task.yield() }
}

/// Lets the sequencer's tasks run until `condition` holds, for at most a few seconds.
@MainActor private func waitUntil(_ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let end = clock.now + .seconds(5)
    while !condition(), clock.now < end {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// How the time limit's wait goes.
private enum TimeLimit {
    /// It does not pass while a test runs; cancelled, it ends at once.
    case never
    /// It has passed by the time it is waited for.
    case alreadyPassed

    var sleep: @Sendable (Duration) async throws -> Void {
        switch self {
        case .never: { _ in try await Task.sleep(for: .seconds(3600)) }
        case .alreadyPassed: { _ in }
        }
    }
}

/// What the sequencer asked for.
@MainActor private final class QuitCalls {
    var closeCalls = 0
    var closesEnded = 0
    var exportCancels = 0
    /// `takeClosed` of each reply.
    var replies: [Bool] = []
}

/// A sequencer whose take closes once `take` lets it, and whose exports end once `exports` does; both are open
/// unless a test closes them.
@MainActor private final class QuitRig {
    let take: Gate
    let exports: Gate
    let calls: QuitCalls
    let sequencer: QuitSequencer

    init(timeLimit: TimeLimit) {
        let (take, exports, calls) = (Gate(), Gate(), QuitCalls())
        (self.take, self.exports, self.calls) = (take, exports, calls)
        sequencer = QuitSequencer(
            closeTake: {
                calls.closeCalls += 1
                await take.pass()
                calls.closesEnded += 1
            },
            cancelExports: {
                calls.exportCancels += 1
                await exports.pass()
            },
            reply: { calls.replies.append($0) },
            sleep: timeLimit.sleep)
    }
}

/// Holds whoever passes it while it is closed.
@MainActor private final class Gate {
    private var isOpen = true
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func close() {
        isOpen = false
    }

    func open() {
        isOpen = true
        let waiting = waiting
        self.waiting = []
        for continuation in waiting { continuation.resume() }
    }

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}
