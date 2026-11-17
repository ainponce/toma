// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os

/// Quits without losing what is in progress (`TerminationDecision`), within `quitTimeLimit`. Its questions come first
/// (edits an editor couldn't save, then an export to cancel), and the first "no" keeps the app running with nothing done.
/// Once a quit is going ahead and waits (an export's, once the user says so), no new action of the library starts. A take
/// being recorded is closed first: the quit goes ahead once it is closed (even if closing failed: the take can still be
/// recovered), or once `quitTimeLimit` has passed if it is not closed by then. An export in progress is cancelled once
/// the user says so (without asking while powering off), and the quit goes ahead only once it has ended and removed its
/// partial file; then the take is closed as above (also one started meanwhile), but the quit goes ahead at once if the
/// time limit has already passed. Powering off starts closing the take before the system asks the app to quit, and that
/// quit waits for the same close and the same time limit. Then, with editors open, their edit sessions are closed (the
/// lines on their way to the disk get their last attempt) and waited for, within `editorsTimeLimit`. Last, once the take
/// is closed, the library's copies are waited for, without a time limit: a copy is never left half done (design §6.8),
/// and a take pauses a copy without clones, so they are not waited for when the take did not close in time. A take
/// started while the copies are waited for is closed before the quit goes ahead. The library's copies and its gate are
/// `LibraryWork`'s.
@MainActor
public final class QuitSequencer {
    /// How long quitting waits for the take to close.
    public nonisolated static let quitTimeLimit: Duration = .seconds(30)
    /// How long quitting waits for the editors' sessions to close, after the take.
    public nonisolated static let editorsTimeLimit: Duration = .seconds(10)

    /// Logging out, restarting or shutting down: nobody is asked before an export is cancelled.
    public private(set) var isPoweringOff = false
    /// Closing the take to quit or power off has taken longer than `quitTimeLimit`.
    private(set) var quitTimeLimitPassed = false
    /// The take is being closed to quit or power off.
    private var closingTake = false
    /// A quit answered `.terminateLater` waits only for the take now: whichever of its close or the time
    /// limit ends first replies. Set once the exports have ended, never before.
    private var terminationPending = false
    private var terminationReplied = false
    /// The quit closes the editors before it replies.
    private var closesEditors = false

    private let closeTake: @MainActor () async -> Void
    private let cancelExports: @MainActor () async -> Void
    private let closeEditors: @MainActor () async -> Void
    private let reply: @MainActor (_ takeClosed: Bool) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private let libraryWork: LibraryWork

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "App")

    /// `closeTake` closes the take, if any, and returns once it is closed; `cancelExports` cancels the
    /// exports in progress and returns once they have ended, their partial files removed; `closeEditors` closes the
    /// editors' edit sessions (those of windows closed just before too) and returns once they are closed; `reply` lets a
    /// quit answered `.terminateLater` go ahead, saying whether the take was closed (true without one); `sleep` waits out
    /// a time limit, and may end early once cancelled (what it waited for ended first); `libraryWork` (the app's, by
    /// default) has the library's copies and the gate that keeps a new action of the library from starting.
    public init(
        closeTake: @escaping @MainActor () async -> Void, cancelExports: @escaping @MainActor () async -> Void,
        closeEditors: @escaping @MainActor () async -> Void = {},
        reply: @escaping @MainActor (_ takeClosed: Bool) -> Void, sleep: @escaping @Sendable (Duration) async throws -> Void,
        libraryWork: LibraryWork = .shared
    ) {
        self.closeTake = closeTake
        self.cancelExports = cancelExports
        self.closeEditors = closeEditors
        self.reply = reply
        self.sleep = sleep
        self.libraryWork = libraryWork
    }

    /// The answer to `applicationShouldTerminate` for `decision`: `ask` asks the user each of its questions, in order,
    /// and the first `false` keeps the app running (`.terminateCancel`) with nothing done, the library included. Answered
    /// "no" while powering off, the app cancels the logout, restart or shutdown: it is not powering off any more, so a
    /// later quit asks again before it cancels an export. After `.terminateLater`, `reply` is called once.
    public func shouldTerminate(_ decision: TerminationDecision, ask: (TerminationQuestion) -> Bool) -> NSApplication.TerminateReply {
        for question in decision.questions where !ask(question) {
            isPoweringOff = false
            return .terminateCancel
        }
        guard !decision.quitsNow else { return .terminateNow }
        // The quit goes ahead, and waits: no new action of the library starts from now on.
        libraryWork.stopNewOperations()
        if decision.closesEditors { closesEditors = true }
        if decision.cancelsExports {
            cancelExportsThenQuit()
            return .terminateLater
        }
        if decision.closesTake || decision.waitsOnlyForCopies {
            if quitTimeLimitPassed {
                // Closing for a power off already took too long: only the editors are waited for (a copy the take keeps
                // paused is not: its hidden folder is removed at the next launch).
                guard closesEditors else {
                    logQuittingBeforeTheTakeClosed()
                    return .terminateNow
                }
                terminationPending = true
                replyToTermination(takeClosed: false)
                return .terminateLater
            }
            if decision.closesTake {
                Self.logger.notice("Quitting while recording: closing the take first")
            } else {
                Self.logger.notice("Quitting while the library copies a project: waiting for the copy")
            }
            terminationPending = true
            // Without a take, closing returns at once: a take started meanwhile is closed all the same.
            closeTakeWithinTimeLimit()
            return .terminateLater
        }
        guard closesEditors else { return .terminateNow }
        terminationPending = true
        replyToTermination(takeClosed: true)
        return .terminateLater
    }

    /// `shouldTerminate(_:ask:)` for a decision that asks at most whether to cancel the export: `confirmCancelExport`
    /// answers that, and any other question is answered "no" (the app keeps running).
    public func shouldTerminate(_ decision: TerminationDecision, confirmCancelExport: () -> Bool) -> NSApplication.TerminateReply {
        shouldTerminate(decision) { question in
            switch question {
            case .cancelExport: confirmCancelExport()
            case .unsavedEdits: false
            }
        }
    }

    /// Logging out, restarting or shutting down: from now on nobody is asked before an export is cancelled,
    /// and a take being recorded starts closing now, with the time limit.
    public func powerOff(isRecording: Bool) {
        isPoweringOff = true
        guard isRecording else { return }
        Self.logger.notice("Powering off while recording: closing the take")
        closeTakeWithinTimeLimit()
    }

    /// Cancels the exports and waits for them to end; only then is the quit pending, so neither the take's
    /// close nor the time limit lets it go ahead before. Then, in the order of `.closeTakeFirst`: the quit goes
    /// ahead at once if the time limit has passed, or once the take is closed or the limit passes. The take is
    /// closed also when the decision had none (`closesTake` false): one may have started from the island
    /// or a shortcut while the exports were cancelled, and closing costs nothing without one.
    private func cancelExportsThenQuit() {
        Self.logger.notice("Quitting during an export: cancelling it first")
        Task {
            await cancelExports()
            terminationPending = true
            if quitTimeLimitPassed {
                replyToTermination(takeClosed: false)
            } else {
                closeTakeWithinTimeLimit()  // a close in progress replies when it ends, or its time limit does
            }
        }
    }

    /// Starts closing the take, once, with `quitTimeLimit`; whichever ends first answers a pending quit.
    private func closeTakeWithinTimeLimit() {
        guard !closingTake else { return }
        closingTake = true
        let deadline = Task {
            try? await sleep(Self.quitTimeLimit)
            guard !Task.isCancelled else { return }
            quitTimeLimitPassed = true
            replyToTermination(takeClosed: false)
        }
        Task {
            await closeTake()
            deadline.cancel()
            closingTake = false
            quitTimeLimitPassed = false
            replyToTermination(takeClosed: true)
        }
    }

    /// Lets a pending quit go ahead, once the editors are closed if it closes them and, when the take is closed, once the
    /// library's copies are done; only the first call does.
    private func replyToTermination(takeClosed: Bool) {
        guard terminationPending, !terminationReplied else { return }
        terminationReplied = true
        if !takeClosed { logQuittingBeforeTheTakeClosed() }
        // A take that did not close keeps a copy without clones paused: it is not waited for.
        let copying = takeClosed && libraryWork.isCopying
        guard closesEditors || copying else { return reply(takeClosed) }
        Task {
            if closesEditors { await closeEditorsWithinTimeLimit() }
            // Also a copy a command already under way began while the editors closed.
            if takeClosed, copying || libraryWork.isCopying { await finishCopies() }
            reply(takeClosed)
        }
    }

    /// Closes the editors and returns once they are closed, or once `editorsTimeLimit` has passed.
    private func closeEditorsWithinTimeLimit() async {
        Self.logger.notice("Quitting with editors open: closing their sessions first")
        let first = FirstOf()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let deadline = Task {
                try? await sleep(Self.editorsTimeLimit)
                guard !Task.isCancelled, first.take() else { return }
                Self.logger.error("Quitting before the editors' sessions closed; what they saved is on disk")
                continuation.resume()
            }
            Task {
                await closeEditors()
                deadline.cancel()
                if first.take() { continuation.resume() }
            }
        }
    }

    /// Returns once the library's copies are done (a copy the take paused goes on once it is closed; it is never left
    /// half done, design §6.8), without a time limit, and the take is closed after them: one started while they were
    /// waited for (a copy's last step, "Duplicar como"'s first edit, or since the take was closed) is closed before the
    /// quit goes ahead, and closing costs nothing without one.
    private func finishCopies() async {
        Self.logger.notice("Quitting while the library copies a project: waiting for the copy")
        repeat {
            await libraryWork.waitForCopies()
            await closeTake()
        } while libraryWork.isCopying
    }

    /// Not "the take stays recoverable": a start still waiting for the answer to the microphone prompt has
    /// recorded nothing.
    private func logQuittingBeforeTheTakeClosed() {
        Self.logger.error("Quitting before the take closed; anything it recorded stays recoverable")
    }
}

/// Which of two ends came first: only the first `take()` is true.
@MainActor private final class FirstOf {
    private var taken = false

    func take() -> Bool {
        defer { taken = true }
        return !taken
    }
}
