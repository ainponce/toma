// SPDX-License-Identifier: GPL-3.0-or-later

/// What quitting does first, from what is in progress. Nothing in progress is lost to a quit: a take being
/// recorded is closed first, a copy the library is making is waited for (it is never left half done, design §6.8),
/// and an export is cancelled (its partial file removed) only once the user says so, or without asking when the Mac
/// is logging out, restarting or shutting down. Whenever the quit waits, no new action of the library starts.
public enum TerminationDecision: Sendable, Equatable {
    /// Nothing is in progress: quit now.
    case now
    /// A take is being recorded: close it, wait for the library's copies (one the take paused goes on once it is
    /// closed), then quit.
    case closeTakeFirst
    /// An export is in progress: ask whether to quit and cancel it. If so, cancel it and wait for it to end,
    /// close the take too when `alsoClosingTake`, wait for the library's copies, then quit; if not, keep running.
    case confirmCancelExport(alsoClosingTake: Bool)
    /// An export is in progress and the Mac is powering off: cancel it and wait for it to end, close the take
    /// too when `alsoClosingTake`, wait for the library's copies, then quit.
    case cancelExportFirst(alsoClosingTake: Bool)
    /// Only a copy of the library is in progress: wait for it, then quit.
    case finishCopiesFirst

    public static func decide(isRecording: Bool, isExporting: Bool, isPoweringOff: Bool, isCopying: Bool) -> TerminationDecision {
        switch (isRecording, isExporting) {
        case (false, false): isCopying ? .finishCopiesFirst : .now
        case (true, false): .closeTakeFirst
        case (_, true):
            isPoweringOff ? .cancelExportFirst(alsoClosingTake: isRecording) : .confirmCancelExport(alsoClosingTake: isRecording)
        }
    }
}
