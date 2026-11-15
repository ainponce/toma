// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os

/// Quits without losing what is in progress (`TerminationDecision`), within `quitTimeLimit`. A take being
/// recorded is closed first: the quit goes ahead once it is closed (even if closing failed: the take can
/// still be recovered), or once `quitTimeLimit` has passed if it is not closed by then. An export in progress
/// is cancelled once the user says so (without asking while powering off), and the quit goes ahead only once
/// it has ended and removed its partial file; then, when the take is being closed too, as above, but at once
/// if the time limit has already passed. Powering off starts closing the take before the system asks the app
/// to quit, and that quit waits for the same close and the same time limit.
@MainActor
public final class QuitSequencer {
    /// How long quitting waits for the take to close.
    public static let quitTimeLimit: Duration = .seconds(30)

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

    private let closeTake: @MainActor () async -> Void
    private let cancelExports: @MainActor () async -> Void
    private let reply: @MainActor (_ takeClosed: Bool) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "App")

    /// `closeTake` closes the take, if any, and returns once it is closed; `cancelExports` cancels the
    /// exports in progress and returns once they have ended, their partial files removed; `reply` lets a quit
    /// answered `.terminateLater` go ahead, saying whether the take was closed; `sleep` waits out the time
    /// limit, and may end early once cancelled (the take closed first).
    public init(
        closeTake: @escaping @MainActor () async -> Void, cancelExports: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor (_ takeClosed: Bool) -> Void, sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.closeTake = closeTake
        self.cancelExports = cancelExports
        self.reply = reply
        self.sleep = sleep
    }

    /// The answer to `applicationShouldTerminate` for `decision`; `confirmCancelExport` asks the user whether
    /// to quit and cancel the export. After `.terminateLater`, `reply` is called once.
    public func shouldTerminate(_ decision: TerminationDecision, confirmCancelExport: () -> Bool) -> NSApplication.TerminateReply {
        switch decision {
        case .now:
            return .terminateNow
        case .closeTakeFirst:
            if quitTimeLimitPassed {
                // Closing for a power off already took too long.
                logQuittingBeforeTheTakeClosed()
                return .terminateNow
            }
            Self.logger.notice("Quitting while recording: closing the take first")
            terminationPending = true
            closeTakeWithinTimeLimit()
            return .terminateLater
        case .confirmCancelExport(let alsoClosingTake):
            guard confirmCancelExport() else { return .terminateCancel }
            cancelExportsThenQuit(alsoClosingTake: alsoClosingTake)
            return .terminateLater
        case .cancelExportFirst(let alsoClosingTake):
            cancelExportsThenQuit(alsoClosingTake: alsoClosingTake)
            return .terminateLater
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
    /// close nor the time limit lets it go ahead before. Then, in the order of `.closeTakeFirst`: with a take
    /// to close too, the quit goes ahead at once if the time limit has passed, or once the take is closed or
    /// the limit passes; otherwise, now.
    private func cancelExportsThenQuit(alsoClosingTake: Bool) {
        Self.logger.notice("Quitting during an export: cancelling it first")
        Task {
            await cancelExports()
            terminationPending = true
            if !alsoClosingTake {
                replyToTermination(takeClosed: true)
            } else if quitTimeLimitPassed {
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

    /// Lets a pending quit go ahead; only the first call replies.
    private func replyToTermination(takeClosed: Bool) {
        guard terminationPending, !terminationReplied else { return }
        terminationReplied = true
        if !takeClosed { logQuittingBeforeTheTakeClosed() }
        reply(takeClosed)
    }

    /// Not "the take stays recoverable": a start still waiting for the answer to the microphone prompt has
    /// recorded nothing.
    private func logQuittingBeforeTheTakeClosed() {
        Self.logger.error("Quitting before the take closed; anything it recorded stays recoverable")
    }
}
