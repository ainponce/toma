// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os

/// Quits without losing what is in progress (`TerminationDecision`), within `quitTimeLimit`. Its questions come first
/// (edits an editor couldn't save, then an export to cancel), and the first "no" keeps the app running. A take being
/// recorded is closed first: the quit goes ahead once it is closed (even if closing failed: the take can still be
/// recovered), or once `quitTimeLimit` has passed if it is not closed by then. An export in progress is cancelled once
/// the user says so (without asking while powering off), and the quit goes ahead only once it has ended and removed its
/// partial file; then the take is closed as above (also one started meanwhile), but the quit goes ahead at once if the
/// time limit has already passed. Powering off starts closing the take before the system asks the app to quit, and that
/// quit waits for the same close and the same time limit. Last, with editors open, their edit sessions are closed (the
/// lines on their way to the disk get their last attempt) and waited for, within `editorsTimeLimit`, before the quit goes
/// ahead.
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

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "App")

    /// `closeTake` closes the take, if any, and returns once it is closed; `cancelExports` cancels the
    /// exports in progress and returns once they have ended, their partial files removed; `closeEditors` closes the
    /// editors' edit sessions (those of windows closed just before too) and returns once they are closed; `reply` lets a
    /// quit answered `.terminateLater` go ahead, saying whether the take was closed (true without one); `sleep` waits out
    /// a time limit, and may end early once cancelled (what it waited for ended first).
    public init(
        closeTake: @escaping @MainActor () async -> Void, cancelExports: @escaping @MainActor () async -> Void,
        closeEditors: @escaping @MainActor () async -> Void = {},
        reply: @escaping @MainActor (_ takeClosed: Bool) -> Void, sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.closeTake = closeTake
        self.cancelExports = cancelExports
        self.closeEditors = closeEditors
        self.reply = reply
        self.sleep = sleep
    }

    /// The answer to `applicationShouldTerminate` for `decision`: `ask` asks the user each of its questions, in order,
    /// and the first `false` keeps the app running (`.terminateCancel`) with nothing done. Answered "no" while powering
    /// off, the app cancels the logout, restart or shutdown: it is not powering off any more, so a later quit asks again
    /// before it cancels an export. After `.terminateLater`, `reply` is called once.
    public func shouldTerminate(_ decision: TerminationDecision, ask: (TerminationQuestion) -> Bool) -> NSApplication.TerminateReply {
        for question in decision.questions where !ask(question) {
            isPoweringOff = false
            return .terminateCancel
        }
        if decision.closesEditors { closesEditors = true }
        if decision.cancelsExports {
            cancelExportsThenQuit()
            return .terminateLater
        }
        if decision.closesTake {
            if quitTimeLimitPassed {
                // Closing for a power off already took too long: only the editors are waited for.
                guard closesEditors else {
                    logQuittingBeforeTheTakeClosed()
                    return .terminateNow
                }
                terminationPending = true
                replyToTermination(takeClosed: false)
                return .terminateLater
            }
            Self.logger.notice("Quitting while recording: closing the take first")
            terminationPending = true
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

    /// Lets a pending quit go ahead, once the editors are closed if it closes them; only the first call does.
    private func replyToTermination(takeClosed: Bool) {
        guard terminationPending, !terminationReplied else { return }
        terminationReplied = true
        if !takeClosed { logQuittingBeforeTheTakeClosed() }
        guard closesEditors else { return reply(takeClosed) }
        Task {
            await closeEditorsWithinTimeLimit()
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
