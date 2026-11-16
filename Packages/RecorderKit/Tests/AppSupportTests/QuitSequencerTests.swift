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
        #expect(rig.calls.closesEnded == 1)
        await settle()
        #expect(rig.calls.replies.isEmpty, "the export has not removed its partial file yet")

        rig.exports.open()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [true])
        #expect(rig.calls.closeCalls == 2, "closed again once the exports end; without a take it returns at once")
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
        #expect(rig.calls.closeCalls == 1, "closed anyway: a take may have started meanwhile")
    }

    /// A take started from the island or a shortcut while the export was being cancelled (AppKit still handles
    /// events while a quit waits) is closed before the quit goes ahead.
    @Test func aTakeStartedDuringTheExportCancelIsClosedBeforeTheQuit() async {
        let rig = QuitRig(timeLimit: .never)
        rig.exports.close()
        #expect(rig.sequencer.shouldTerminate(.confirmCancelExport(alsoClosingTake: false)) { true } == .terminateLater)
        await waitUntil { rig.calls.exportCancels == 1 }
        rig.take.close()  // the take started meanwhile, and takes a while to close

        rig.exports.open()
        await waitUntil { rig.calls.closeCalls == 1 }
        await settle()
        #expect(rig.calls.replies.isEmpty, "the take is still closing")

        rig.take.open()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [true])
        #expect(rig.calls.closesEnded == 1)
    }

    /// The same take, and then a power off whose close passes the time limit while the export is still being
    /// cancelled: in the order of `.closeTakeFirst`, the quit goes ahead as soon as the exports end.
    @Test func aTakeStartedDuringTheExportCancelKeepsTheTimeLimit() async {
        let rig = QuitRig(timeLimit: .alreadyPassed)
        rig.exports.close()
        rig.take.close()
        #expect(rig.sequencer.shouldTerminate(.confirmCancelExport(alsoClosingTake: false)) { true } == .terminateLater)
        await waitUntil { rig.calls.exportCancels == 1 }
        rig.sequencer.powerOff(isRecording: true)
        await waitUntil { rig.sequencer.quitTimeLimitPassed }

        rig.exports.open()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [false])
        #expect(rig.calls.closeCalls == 1 && rig.calls.closesEnded == 0, "the quit did not wait for the take")

        rig.take.open()
        await waitUntil { rig.calls.closesEnded == 1 }
        await settle()
        #expect(rig.calls.replies == [false])
    }

    // MARK: - The library's copies (design §6.8)

    /// Stop new library actions, close the take (a copy does not hold it up: a take pauses a copy without clones), then
    /// wait for the copies, then reply: a copy is never left half done.
    @Test func aQuitWhileRecordingWaitsForTheCopiesOnceTheTakeIsClosed() async {
        let rig = QuitRig(timeLimit: .never)
        rig.take.close()
        rig.work.beginCopy()
        #expect(rig.sequencer.shouldTerminate(.closeTakeFirst, confirmCancelExport: nobodyIsAsked) == .terminateLater)
        #expect(rig.work.isStopped)
        await waitUntil { rig.calls.closeCalls == 1 }
        await settle()
        #expect(rig.calls.events == ["close"], "closing the take does not wait for the copy")

        rig.take.open()
        await waitUntil { rig.calls.closesEnded == 1 }
        await settle()
        #expect(rig.calls.replies.isEmpty, "a copy is under way")

        rig.copyEnds()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [true])
        #expect(rig.calls.events == ["close", "closed", "copy ended", "close", "closed", "reply"])
    }

    @Test func aCopyAloneIsWaitedFor() async {
        let rig = QuitRig(timeLimit: .never)
        rig.work.beginCopy()
        #expect(rig.sequencer.shouldTerminate(.finishCopiesFirst, confirmCancelExport: nobodyIsAsked) == .terminateLater)
        #expect(rig.work.isStopped)
        await waitUntil { rig.calls.closesEnded == 1 }
        await settle()
        #expect(rig.calls.replies.isEmpty)

        rig.copyEnds()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [true])
    }

    /// A take started while the copies were waited for (during a copy's last step) is closed before the reply.
    @Test func aTakeStartedWhileTheCopiesAreWaitedForIsClosedFirst() async {
        let rig = QuitRig(timeLimit: .never)
        rig.work.beginCopy()
        #expect(rig.sequencer.shouldTerminate(.finishCopiesFirst, confirmCancelExport: nobodyIsAsked) == .terminateLater)
        await waitUntil { rig.calls.closesEnded == 1 }
        rig.take.close()  // a take starts, and takes a while to close

        rig.copyEnds()
        await waitUntil { rig.calls.closeCalls == 2 }
        await settle()
        #expect(rig.calls.replies.isEmpty, "the take started meanwhile is still closing")

        rig.take.open()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [true])
        #expect(rig.calls.closesEnded == 2)
    }

    /// The take did not close within the time limit: the quit goes ahead without waiting for a copy it keeps paused (its
    /// hidden folder is removed at the next launch).
    @Test func copiesAreNotWaitedForOnceTheTimeLimitPasses() async {
        let rig = QuitRig(timeLimit: .alreadyPassed)
        rig.take.close()
        rig.work.beginCopy()
        #expect(rig.sequencer.shouldTerminate(.closeTakeFirst, confirmCancelExport: nobodyIsAsked) == .terminateLater)
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.replies == [false])
        #expect(rig.work.isCopying, "the copy was not waited for")

        rig.take.open()
        await waitUntil { rig.calls.closesEnded == 1 }
        await settle()
        #expect(rig.calls.replies == [false], "only the first answer replies")
    }

    /// An export first, once the user says so: nothing stops while the app keeps running; then stop, cancel the
    /// export, close the take, wait for the copies, reply.
    @Test func anExportQuitStopsTheLibraryOnlyOnceConfirmedAndWaitsForTheCopiesLast() async {
        let rig = QuitRig(timeLimit: .never)
        #expect(rig.sequencer.shouldTerminate(.confirmCancelExport(alsoClosingTake: false)) { false } == .terminateCancel)
        await settle()
        #expect(!rig.work.isStopped && rig.calls.events.isEmpty, "the app keeps running: its library too")

        rig.exports.close()
        rig.work.beginCopy()
        #expect(rig.sequencer.shouldTerminate(.confirmCancelExport(alsoClosingTake: false)) { true } == .terminateLater)
        #expect(rig.work.isStopped)
        await waitUntil { rig.calls.exportCancels == 1 }
        await settle()
        #expect(rig.calls.events == ["cancel"])

        rig.exports.open()
        await waitUntil { rig.calls.closesEnded == 1 }
        await settle()
        #expect(rig.calls.replies.isEmpty, "a copy is under way")

        rig.copyEnds()
        await waitUntil { !rig.calls.replies.isEmpty }
        #expect(rig.calls.events == ["cancel", "close", "closed", "copy ended", "close", "closed", "reply"])
    }
}

/// The library's copies and its gate (`LibraryWork`).
@MainActor @Suite struct LibraryWorkTests {
    @Test func copiesAreCountedAndWaitedFor() async {
        let work = LibraryWork()
        #expect(!work.isCopying && !work.isStopped)
        await work.waitForCopies()  // none: at once

        work.beginCopy()
        work.beginCopy()
        var waited = false
        let waiting = Task {
            await work.waitForCopies()
            waited = true
        }
        await settle()
        work.endCopy()
        await settle()
        #expect(!waited && work.isCopying, "one copy is still under way")
        work.endCopy()
        await waiting.value
        #expect(waited && !work.isCopying)
        work.endCopy()
        #expect(work.copies == 0, "an end without a beginning counts nothing")

        work.stopNewOperations()
        #expect(work.isStopped)
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

/// Lets the sequencer's tasks run until `condition` holds; records an issue if it does not within a few seconds.
@MainActor private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let end = clock.now + .seconds(5)
    while !condition() {
        guard clock.now < end else {
            Issue.record("timed out waiting for the condition", sourceLocation: sourceLocation)
            return
        }
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
    /// What happened, in order: "cancel" (the exports), "close" and "closed" (the take), "copy ended" (the test ends the
    /// library's copy), "reply".
    var events: [String] = []
}

/// A sequencer whose take closes once `take` lets it, and whose exports end once `exports` does; both are open
/// unless a test closes them.
@MainActor private final class QuitRig {
    let take: Gate
    let exports: Gate
    /// The library's copies and gate, the rig's own.
    let work = LibraryWork()
    let calls: QuitCalls
    let sequencer: QuitSequencer

    /// The library's copy ends.
    func copyEnds() {
        calls.events.append("copy ended")
        work.endCopy()
    }

    init(timeLimit: TimeLimit) {
        let (take, exports, calls) = (Gate(), Gate(), QuitCalls())
        (self.take, self.exports, self.calls) = (take, exports, calls)
        sequencer = QuitSequencer(
            closeTake: {
                calls.closeCalls += 1
                calls.events.append("close")
                await take.pass()
                calls.closesEnded += 1
                calls.events.append("closed")
            },
            cancelExports: {
                calls.exportCancels += 1
                calls.events.append("cancel")
                await exports.pass()
            },
            reply: {
                calls.replies.append($0)
                calls.events.append("reply")
            },
            sleep: timeLimit.sleep, libraryWork: work)
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
