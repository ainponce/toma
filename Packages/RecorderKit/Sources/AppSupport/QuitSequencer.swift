// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os

/// Quits without losing what is in progress (`TerminationDecision`), within `quitTimeLimit`. Once a quit is
/// going ahead (an export's, once the user says so), no new action of the library starts. A take being recorded
/// is closed first: the quit goes ahead once it is closed (even if closing failed: the take can still be
/// recovered) and the library's copies are done, or once `quitTimeLimit` has passed if the take is not closed by
/// then. The copies are waited for only after the take is closed, since a take pauses a copy without clones
/// (design §6.8), and without a time limit: a copy is never left half done. An export in progress is cancelled
/// once the user says so (without asking while powering off), and the quit goes ahead only once it has ended and
/// removed its partial file; then the take is closed and the copies waited for as above (also a take started
/// meanwhile), but the quit goes ahead at once if the time limit has already passed. A take started while the copies
/// are waited for is closed before the quit goes ahead. Powering off starts closing the take before the system asks
/// the app to quit, and that quit waits for the same close and the same time limit. The library's copies and its gate
/// are `LibraryWork`'s.
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
    private let libraryWork: LibraryWork

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "App")

    /// `closeTake` closes the take, if any, and returns once it is closed; `cancelExports` cancels the
    /// exports in progress and returns once they have ended, their partial files removed; `reply` lets a quit
    /// answered `.terminateLater` go ahead, saying whether the take was closed; `sleep` waits out the time
    /// limit, and may end early once cancelled (the take closed first); `libraryWork` (the app's, by default) has the
    /// library's copies and the gate that keeps a new action of the library from starting.
    public init(
        closeTake: @escaping @MainActor () async -> Void, cancelExports: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor (_ takeClosed: Bool) -> Void, sleep: @escaping @Sendable (Duration) async throws -> Void,
        libraryWork: LibraryWork = .shared
    ) {
        self.closeTake = closeTake
        self.cancelExports = cancelExports
        self.reply = reply
        self.sleep = sleep
        self.libraryWork = libraryWork
    }

    /// The answer to `applicationShouldTerminate` for `decision`; `confirmCancelExport` asks the user whether
    /// to quit and cancel the export. After `.terminateLater`, `reply` is called once.
    public func shouldTerminate(_ decision: TerminationDecision, confirmCancelExport: () -> Bool) -> NSApplication.TerminateReply {
        switch decision {
        case .now:
            return .terminateNow
        case .closeTakeFirst, .finishCopiesFirst:
            if quitTimeLimitPassed {
                // Closing for a power off already took too long.
                logQuittingBeforeTheTakeClosed()
                return .terminateNow
            }
            if decision == .closeTakeFirst {
                Self.logger.notice("Quitting while recording: closing the take first")
            } else {
                Self.logger.notice("Quitting while the library copies a project: waiting for the copy")
            }
            libraryWork.stopNewOperations()
            terminationPending = true
            // Without a take, closing returns at once: a take started meanwhile is closed all the same.
            closeTakeWithinTimeLimit()
            return .terminateLater
        case .confirmCancelExport:
            guard confirmCancelExport() else { return .terminateCancel }
            libraryWork.stopNewOperations()
            cancelExportsThenQuit()
            return .terminateLater
        case .cancelExportFirst:
            libraryWork.stopNewOperations()
            cancelExportsThenQuit()
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
    /// close nor the time limit lets it go ahead before. Then, in the order of `.closeTakeFirst`: the quit goes
    /// ahead at once if the time limit has passed, or once the take is closed or the limit passes. The take is
    /// closed also when the decision had none (`alsoClosingTake` false): one may have started from the island
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

    /// Starts closing the take, once, with `quitTimeLimit`; whichever ends first answers a pending quit. Once the take
    /// is closed, a pending quit also waits for the library's copies, without a time limit.
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
            // A copy the take paused goes on now; it is never left half done (design §6.8). A take started while it is
            // waited for (a copy's last step, "Duplicar como"'s first edit) is closed before the quit goes ahead. Without
            // a quit pending (a power off the system has not followed with a quit yet) nothing replies.
            while libraryWork.isCopying {
                await libraryWork.waitForCopies()
                await closeTake()
            }
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
