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
///   the lock), last, before the app quits.
///
/// `QuitSequencer` asks the `questions` in order, then cancels the exports, closes the take and closes the editors, in
/// that order, each step waited for (the take and the editors within their time limits).
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

    public init(questions: [TerminationQuestion], cancelsExports: Bool, closesTake: Bool, closesEditors: Bool) {
        self.questions = questions
        self.cancelsExports = cancelsExports
        self.closesTake = closesTake
        self.closesEditors = closesEditors
    }

    /// Nothing is in progress: quit now.
    public static let now = TerminationDecision(questions: [], cancelsExports: false, closesTake: false, closesEditors: false)
    /// A take is being recorded: close it, then quit.
    public static let closeTakeFirst = TerminationDecision(
        questions: [], cancelsExports: false, closesTake: true, closesEditors: false)

    /// An export is in progress: ask whether to quit and cancel it. If so, cancel it and wait for it to end, close the
    /// take too, then quit; if not, keep running.
    public static func confirmCancelExport(alsoClosingTake: Bool) -> TerminationDecision {
        TerminationDecision(questions: [.cancelExport], cancelsExports: true, closesTake: alsoClosingTake, closesEditors: false)
    }

    /// An export is in progress and the Mac is powering off: cancel it and wait for it to end, close the take too, then
    /// quit.
    public static func cancelExportFirst(alsoClosingTake: Bool) -> TerminationDecision {
        TerminationDecision(questions: [], cancelsExports: true, closesTake: alsoClosingTake, closesEditors: false)
    }

    /// Whether nothing is asked nor waited for: the app quits at once.
    public var quitsNow: Bool { self == .now }

    /// `hasEditSessions`: an editor is open, or one whose window closed is still closing its session. `hasUnsavedEdits`:
    /// one of them would lose edits that couldn't be saved (`EditorClosing.losesEdits`).
    public static func decide(
        isRecording: Bool, isExporting: Bool, isPoweringOff: Bool, hasEditSessions: Bool = false,
        hasUnsavedEdits: Bool = false
    ) -> TerminationDecision {
        var questions: [TerminationQuestion] = []
        // Asked even while powering off: nothing else gets those edits back.
        if hasUnsavedEdits { questions.append(.unsavedEdits) }
        if isExporting, !isPoweringOff { questions.append(.cancelExport) }
        return TerminationDecision(
            questions: questions, cancelsExports: isExporting, closesTake: isRecording,
            closesEditors: hasEditSessions || hasUnsavedEdits)
    }
}
