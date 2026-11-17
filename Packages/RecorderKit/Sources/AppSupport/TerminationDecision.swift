// SPDX-License-Identifier: GPL-3.0-or-later

/// What the user is asked before the app quits; the first "no" keeps it running and nothing is done.
public enum TerminationQuestion: Sendable, Equatable {
    /// An editor has edits that couldn't be saved (design §5.9's amber banner): quitting loses them. Asked as closing that
    /// editor's window asks (`EditorClosing`), "Cancel" by default.
    case unsavedEdits
    /// An export is in progress: quit and cancel it?
    case cancelExport
}

/// What quitting does first, from what is in progress. Nothing in progress is lost to a quit:
/// - edits an editor couldn't save are lost only once the user says so, also when the Mac logs out, restarts or shuts
///   down (`TerminationQuestion.unsavedEdits`, asked first);
/// - an export is cancelled (its partial file removed) only once the user says so, or without asking when the Mac is
///   logging out, restarting or shutting down;
/// - a take being recorded is closed first;
/// - every editor's edit session is closed (the lines on their way to the disk get their last attempt, the snapshot and
///   the lock) before the app quits;
/// - a copy the library is making is waited for, last: it is never left half done (design §6.8).
///
/// `QuitSequencer` asks the `questions` in order; then, once the quit goes ahead and waits, no new action of the library
/// starts, and it cancels the exports, closes the take, closes the editors and waits for the library's copies, in that
/// order, each step waited for (the take and the editors within their time limits, the copies without one, and only once
/// the take is closed: a take pauses a copy without clones).
public struct TerminationDecision: Sendable, Equatable {
    /// Asked in this order before anything is done.
    public var questions: [TerminationQuestion]
    /// The exports in progress are cancelled, and waited for until they have removed their partial files. The take is
    /// closed after them even without `closesTake`: one may have started meanwhile.
    public var cancelsExports: Bool
    /// A take is being recorded: it is closed, within `QuitSequencer.quitTimeLimit`.
    public var closesTake: Bool
    /// Editors are open, or their sessions are closing: they are closed and waited for, within
    /// `QuitSequencer.editorsTimeLimit`.
    public var closesEditors: Bool
    /// Only a copy of the library is in progress (nothing to cancel, no take, no editor): the quit waits for it all the
    /// same, instead of quitting now. It is not "whether the copies are waited for": every quit that waits waits for them,
    /// as its last step once the take is closed, from what `LibraryWork` says then (`QuitSequencer`).
    public var waitsOnlyForCopies: Bool

    public init(
        questions: [TerminationQuestion], cancelsExports: Bool, closesTake: Bool, closesEditors: Bool,
        waitsOnlyForCopies: Bool = false
    ) {
        self.questions = questions
        self.cancelsExports = cancelsExports
        self.closesTake = closesTake
        self.closesEditors = closesEditors
        self.waitsOnlyForCopies = waitsOnlyForCopies
    }

    /// Nothing is in progress: quit now.
    public static let now = TerminationDecision(questions: [], cancelsExports: false, closesTake: false, closesEditors: false)
    /// A take is being recorded: close it, wait for the library's copies (one the take paused goes on once it is closed),
    /// then quit.
    public static let closeTakeFirst = TerminationDecision(
        questions: [], cancelsExports: false, closesTake: true, closesEditors: false)
    /// Only a copy of the library is in progress: wait for it, then quit.
    public static let finishCopiesFirst = TerminationDecision(
        questions: [], cancelsExports: false, closesTake: false, closesEditors: false, waitsOnlyForCopies: true)

    /// An export is in progress: ask whether to quit and cancel it. If so, cancel it and wait for it to end, close the
    /// take too, wait for the library's copies, then quit; if not, keep running.
    public static func confirmCancelExport(alsoClosingTake: Bool) -> TerminationDecision {
        TerminationDecision(questions: [.cancelExport], cancelsExports: true, closesTake: alsoClosingTake, closesEditors: false)
    }

    /// An export is in progress and the Mac is powering off: cancel it and wait for it to end, close the take too, wait
    /// for the library's copies, then quit.
    public static func cancelExportFirst(alsoClosingTake: Bool) -> TerminationDecision {
        TerminationDecision(questions: [], cancelsExports: true, closesTake: alsoClosingTake, closesEditors: false)
    }

    /// Whether nothing is asked nor waited for: the app quits at once.
    public var quitsNow: Bool { self == .now }

    /// `isCopying`: the library is making a copy (`LibraryWork.isCopying`); a quit never leaves one half done.
    /// `hasEditSessions`: an editor is open, or one whose window closed is still closing its session. `hasUnsavedEdits`:
    /// one of them would lose edits that couldn't be saved (`EditorClosing.losesEdits`).
    public static func decide(
        isRecording: Bool, isExporting: Bool, isPoweringOff: Bool, isCopying: Bool, hasEditSessions: Bool = false,
        hasUnsavedEdits: Bool = false
    ) -> TerminationDecision {
        var questions: [TerminationQuestion] = []
        // Asked even while powering off: nothing else gets those edits back.
        if hasUnsavedEdits { questions.append(.unsavedEdits) }
        if isExporting, !isPoweringOff { questions.append(.cancelExport) }
        let closesEditors = hasEditSessions || hasUnsavedEdits
        return TerminationDecision(
            questions: questions, cancelsExports: isExporting, closesTake: isRecording, closesEditors: closesEditors,
            waitsOnlyForCopies: isCopying && !isExporting && !isRecording && !closesEditors)
    }
}
