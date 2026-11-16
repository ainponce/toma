// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import AppSupport
import Editing
import Testing

/// Quitting with editors open (final review A-I1, D-C1): the edits that couldn't be saved are asked about first, as
/// closing their window asks, also while powering off; then the exports are cancelled, the take closed and, last, the
/// editors' sessions closed and waited for, within their own time limit, before the quit goes ahead.
@Test func quittingWithUnsavedEditsAsksFirstEvenWhilePoweringOff() {
    for poweringOff in [false, true] {
        let decision = TerminationDecision.decide(
            isRecording: false, isExporting: false, isPoweringOff: poweringOff, hasEditSessions: true, hasUnsavedEdits: true)
        #expect(decision.questions == [.unsavedEdits])
        #expect(decision.closesEditors && !decision.closesTake && !decision.cancelsExports)
    }
    // The edits first, then the export; powering off, only the edits are asked about.
    let exporting = TerminationDecision.decide(
        isRecording: true, isExporting: true, isPoweringOff: false, hasEditSessions: true, hasUnsavedEdits: true)
    #expect(exporting.questions == [.unsavedEdits, .cancelExport])
    #expect(exporting.cancelsExports && exporting.closesTake && exporting.closesEditors)
    let poweringOff = TerminationDecision.decide(
        isRecording: true, isExporting: true, isPoweringOff: true, hasEditSessions: true, hasUnsavedEdits: true)
    #expect(poweringOff.questions == [.unsavedEdits])
    #expect(poweringOff.cancelsExports && poweringOff.closesTake)
}

@Test func editorsOpenAreClosedBeforeTheQuitAndNothingIsAskedWithoutFailedSaves() {
    let decision = TerminationDecision.decide(isRecording: false, isExporting: false, isPoweringOff: false, hasEditSessions: true)
    #expect(decision.questions.isEmpty)
    #expect(decision.closesEditors)
    #expect(!decision.quitsNow, "the sessions' lines on their way to the disk get their last attempt")
    // Without editors, as before.
    #expect(TerminationDecision.decide(isRecording: false, isExporting: false, isPoweringOff: false).quitsNow)
    #expect(TerminationDecision.decide(isRecording: true, isExporting: false, isPoweringOff: false) == .closeTakeFirst)
}

/// The same rule as closing the window: only a change that couldn't be saved and still isn't is asked about.
@Test func quittingAsksAboutTheSameEditsClosingTheWindowAsksAbout() {
    let failed: [EditNotice] = [.saveFailed(.ENOSPC)]
    #expect(EditorClosing.losesEdits(hasUnsavedChanges: true, notices: failed))
    #expect(!EditorClosing.losesEdits(hasUnsavedChanges: true, notices: []), "a line on its way to the disk is saved as it closes")
    #expect(!EditorClosing.losesEdits(hasUnsavedChanges: false, notices: failed))
    #expect(EditorClosing.decide(hasUnsavedChanges: true, notices: failed, isAsking: false) == .ask)
}

/// Closing a window while its export runs asks first, as quitting does (final review D-I2, C-M2): never a silent cancel.
@Test func closingAWindowWithItsExportRunningAsksFirst() {
    #expect(EditorClosing.decide(hasUnsavedChanges: false, notices: [], isExporting: true, isAsking: false) == .ask)
    #expect(EditorClosing.questions(hasUnsavedChanges: false, notices: [], isExporting: true) == [.cancelExport])
    #expect(EditorClosing.questions(hasUnsavedChanges: true, notices: [.saveFailed(.EIO)], isExporting: true)
        == [.unsavedChanges, .cancelExport])
    #expect(EditorClosing.decide(hasUnsavedChanges: false, notices: [], isExporting: false, isAsking: false) == .close)
    #expect(EditorClosing.decide(hasUnsavedChanges: false, notices: [], isExporting: true, isAsking: true) == .keepOpen)
    #expect(ExportClosingAnswer.allCases.first == .cancel, "the default keeps the export")
    #expect(ExportClosingAnswer.allCases.filter(\.closesTheWindow) == [.close])
}

@MainActor @Suite struct QuitWithEditorsTests {
    @Test func answeringNoToTheUnsavedEditsKeepsTheAppRunning() async {
        let rig = EditorsQuitRig(timeLimit: .never)
        var asked: [TerminationQuestion] = []
        let decision = TerminationDecision.decide(
            isRecording: true, isExporting: true, isPoweringOff: false, hasEditSessions: true, hasUnsavedEdits: true)
        #expect(rig.sequencer.shouldTerminate(decision) { asked.append($0); return false } == .terminateCancel)
        #expect(asked == [.unsavedEdits], "the export is not asked about once the user said no")
        await settle()
        #expect(rig.events.isEmpty, "nothing is cancelled, closed or replied")
    }

    /// «Cancelar» to the unsaved edits during a logout cancels it: the app stays, and is not powering off any more, so a
    /// later ⌘Q during an export asks before it cancels it (final fix wave re-review).
    @Test func answeringNoWhilePoweringOffEndsThePowerOff() async {
        let rig = EditorsQuitRig(timeLimit: .never)
        rig.sequencer.powerOff(isRecording: false)
        #expect(rig.sequencer.isPoweringOff)
        let logout = TerminationDecision.decide(
            isRecording: false, isExporting: true, isPoweringOff: rig.sequencer.isPoweringOff, hasEditSessions: true,
            hasUnsavedEdits: true)
        #expect(logout.questions == [.unsavedEdits])
        #expect(rig.sequencer.shouldTerminate(logout) { _ in false } == .terminateCancel)
        #expect(!rig.sequencer.isPoweringOff)
        await settle()
        #expect(rig.events.isEmpty, "nothing cancelled, closed or replied")

        // ⌘Q later, the edits saved by then, the export still running: it is asked about.
        let quit = TerminationDecision.decide(
            isRecording: false, isExporting: true, isPoweringOff: rig.sequencer.isPoweringOff, hasEditSessions: true)
        #expect(quit.questions == [.cancelExport])
        var asked: [TerminationQuestion] = []
        #expect(rig.sequencer.shouldTerminate(quit) { asked.append($0); return false } == .terminateCancel)
        #expect(asked == [.cancelExport])
        await settle()
        #expect(rig.events.isEmpty)
    }

    @Test func theOldEntryPointNeverQuitsLosingEdits() async {
        let rig = EditorsQuitRig(timeLimit: .never)
        let decision = TerminationDecision.decide(
            isRecording: false, isExporting: false, isPoweringOff: false, hasEditSessions: true, hasUnsavedEdits: true)
        #expect(rig.sequencer.shouldTerminate(decision, confirmCancelExport: { true }) == .terminateCancel)
        await settle()
        #expect(rig.events.isEmpty)
    }

    /// The order: the exports end, then the take is closed, then the editors, and only then does the quit go ahead.
    @Test func exportsThenTheTakeThenTheEditorsThenTheReply() async {
        let rig = EditorsQuitRig(timeLimit: .never)
        rig.exports.close()
        rig.take.close()
        rig.editors.close()
        var asked: [TerminationQuestion] = []
        let decision = TerminationDecision.decide(
            isRecording: true, isExporting: true, isPoweringOff: false, hasEditSessions: true, hasUnsavedEdits: true)
        #expect(rig.sequencer.shouldTerminate(decision) { asked.append($0); return true } == .terminateLater)
        #expect(asked == [.unsavedEdits, .cancelExport])
        await waitUntil { rig.events == [.cancelExports] }
        await settle()
        #expect(rig.events == [.cancelExports], "the take waits for the exports")

        rig.exports.open()
        await waitUntil { rig.events.contains(.closeTake) }
        await settle()
        #expect(rig.events == [.cancelExports, .exportsEnded, .closeTake], "the editors wait for the take")

        rig.take.open()
        await waitUntil { rig.events.contains(.closeEditors) }
        await settle()
        #expect(rig.events == [.cancelExports, .exportsEnded, .closeTake, .takeClosed, .closeEditors], "the reply waits for the editors")

        rig.editors.open()
        await waitUntil { rig.events.last == .reply(takeClosed: true) }
        #expect(rig.events == [.cancelExports, .exportsEnded, .closeTake, .takeClosed, .closeEditors, .editorsClosed, .reply(takeClosed: true)])
    }

    /// Editors open and nothing else in progress: the quit waits for their sessions to close.
    @Test func onlyEditorsOpenTheQuitWaitsForThem() async {
        let rig = EditorsQuitRig(timeLimit: .never)
        rig.editors.close()
        let decision = TerminationDecision.decide(isRecording: false, isExporting: false, isPoweringOff: false, hasEditSessions: true)
        #expect(rig.sequencer.shouldTerminate(decision) { _ in Issue.record("asked"); return false } == .terminateLater)
        await waitUntil { rig.events == [.closeEditors] }
        await settle()
        #expect(rig.events == [.closeEditors])

        rig.editors.open()
        await waitUntil { rig.events.last == .reply(takeClosed: true) }
        #expect(rig.events == [.closeEditors, .editorsClosed, .reply(takeClosed: true)])
    }

    /// A session that does not close within `editorsTimeLimit` does not hold the quit for ever; it replies once.
    @Test func editorsThatDoNotCloseInTimeDoNotHoldTheQuit() async {
        let rig = EditorsQuitRig(timeLimit: .alreadyPassed)
        rig.editors.close()
        let decision = TerminationDecision.decide(isRecording: false, isExporting: false, isPoweringOff: false, hasEditSessions: true)
        #expect(rig.sequencer.shouldTerminate(decision) { _ in false } == .terminateLater)
        await waitUntil { rig.events.contains(.reply(takeClosed: true)) }
        #expect(rig.events == [.closeEditors, .reply(takeClosed: true)])

        rig.editors.open()
        await waitUntil { rig.events.contains(.editorsClosed) }
        await settle()
        #expect(rig.events.filter { if case .reply = $0 { true } else { false } }.count == 1)
    }

    /// Closing the take for a power off already took longer than its time limit: the quit no longer waits for the take,
    /// but still for the editors.
    @Test func aTakePastItsTimeLimitStillWaitsForTheEditors() async {
        let rig = EditorsQuitRig(timeLimit: .alreadyPassed, editorsTimeLimit: .never)
        rig.take.close()
        rig.editors.close()
        rig.sequencer.powerOff(isRecording: true)
        await waitUntil { rig.sequencer.quitTimeLimitPassed }
        let decision = TerminationDecision.decide(isRecording: true, isExporting: false, isPoweringOff: true, hasEditSessions: true)
        #expect(rig.sequencer.shouldTerminate(decision) { _ in false } == .terminateLater)
        await waitUntil { rig.events.contains(.closeEditors) }
        await settle()
        #expect(!rig.events.contains { if case .reply = $0 { true } else { false } })

        rig.editors.open()
        await waitUntil { rig.events.contains(.reply(takeClosed: false)) }
        #expect(rig.events == [.closeTake, .closeEditors, .editorsClosed, .reply(takeClosed: false)])
    }
}

/// Lets the main-actor jobs already queued run up to their next wait.
@MainActor private func settle() async {
    for _ in 0..<10 { await Task.yield() }
}

/// Lets the sequencer's tasks run until `condition` holds; records an issue if it does not within a minute (a
/// watchdog for a hang, not a bound on how long it takes).
@MainActor private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let end = clock.now + .seconds(60)
    while !condition() {
        guard clock.now < end else {
            Issue.record("timed out waiting for the condition", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// How a time limit's wait goes.
private enum EditorsTimeLimit {
    /// It does not pass while a test runs; cancelled, it ends at once.
    case never
    /// It has passed by the time it is waited for.
    case alreadyPassed
}

/// What the sequencer did, in order.
private enum QuitEvent: Equatable {
    case cancelExports, exportsEnded, closeTake, takeClosed, closeEditors, editorsClosed
    case reply(takeClosed: Bool)
}

/// A sequencer whose exports, take and editors end once their gates let them; all open unless a test closes them.
/// `timeLimit` is the take's; `editorsTimeLimit` the editors' (the same unless given).
@MainActor private final class EditorsQuitRig {
    let take = QuitGate()
    let exports = QuitGate()
    let editors = QuitGate()
    private(set) var events: [QuitEvent] = []
    private(set) var sequencer: QuitSequencer!

    init(timeLimit: EditorsTimeLimit, editorsTimeLimit: EditorsTimeLimit? = nil) {
        let (take, exports, editors) = (take, exports, editors)
        let takeLimit = timeLimit, editorsLimit = editorsTimeLimit ?? timeLimit
        sequencer = QuitSequencer(
            closeTake: { [unowned self] in
                events.append(.closeTake)
                await take.pass()
                events.append(.takeClosed)
            },
            cancelExports: { [unowned self] in
                events.append(.cancelExports)
                await exports.pass()
                events.append(.exportsEnded)
            },
            closeEditors: { [unowned self] in
                events.append(.closeEditors)
                await editors.pass()
                events.append(.editorsClosed)
            },
            reply: { [unowned self] in events.append(.reply(takeClosed: $0)) },
            sleep: { duration in
                let limit = duration == QuitSequencer.editorsTimeLimit ? editorsLimit : takeLimit
                switch limit {
                case .never: try await Task.sleep(for: .seconds(3600))
                case .alreadyPassed: break
                }
            })
    }
}

/// Holds whoever passes it while it is closed.
@MainActor private final class QuitGate {
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
