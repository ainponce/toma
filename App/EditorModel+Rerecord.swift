// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import AppSupport
import Editing
import Foundation
import Observation
import ProjectFormat
import Synchronization
import os

/// What "Re-record from Here" hands the app (`EditorProjectHost.rerecord`, phase 3 design §8.2, 3d plan decisions 9 and
/// 10): where the take goes, the take whose sources it records again and how the camera looks at the playhead.
struct EditorRerecordRequest {
    /// The editor asking: its window is hidden meanwhile, and it hears how the re-record ended.
    let editor: EditorModel
    /// The editor's package (its `scriptWord` is set by the island, from `scriptWord`).
    var target: RerecordTarget
    /// The word of the package's script the teleprompter opens at (decision 12), being worked out off the main thread as
    /// the window hides: the island waits for it before the take is asked for.
    var scriptWord: Task<Int?, Never>
    /// The take of the clip at the playhead (a clip with content's own take): its screen, camera, microphone and system
    /// audio are recorded again (`RerecordSelection`).
    var take: TakeRecord
    /// The camera's style that rules at the playhead (`TrackCommands.rulingCameraStyle`): the new take starts with it.
    var cameraStyle: CameraStyle
    /// The project's name, for the island's "Re-record into «…»".
    var projectName: String
    /// When it was asked for (⇧⌘R or the Takes menu): the island logs the time to the countdown (design §15: < 1 s).
    var asked: ContinuousClock.Instant
}

/// The takes of an editor (phase 3 design §8.1 and §8.2, 3d plan decisions 6 to 10): the Takes menu's list, worked out
/// off the main thread whenever the project or the takes its sequence uses change, and the re-record under way, from
/// "Re-record from Here" until its take is applied (or nothing is). The editor's own state, never written anywhere.
@MainActor @Observable
final class EditorTakes {
    /// One row of the Takes menu for each take of the manifest, in its order (`TakeCommands.takes`); none until the project
    /// is shown.
    private(set) var list: [TakeInfo] = []
    /// A take is being recorded in the app (from its countdown until it is closed): no re-record starts meanwhile.
    private(set) var isRecording = false
    /// From "Re-record from Here" until its end was applied, or nothing was: the window is hidden, or the project opens
    /// again with the new take.
    private(set) var isRerecording = false
    /// The format of the package as the session last had it: one below 3 takes no new take until its first edit has
    /// moved it to 3 (3d plan decision 8).
    private(set) var packageFormat = 0

    /// The re-record asked for and not ended yet: where the playhead was, the take under it and the target given.
    struct Pending {
        /// The playhead's output instant when it was asked for: where `take.rerecord` cuts.
        let output: Int64
        /// The take of the clip at the playhead.
        let takeID: String
        let target: RerecordTarget
    }

    @ObservationIgnored fileprivate var pending: Pending?
    @ObservationIgnored private weak var model: EditorModel?
    /// What the list was last worked out from: the takes of the manifest and those the sequence uses.
    @ObservationIgnored private var listedFrom: ListKey?
    /// Only the newest list is shown.
    @ObservationIgnored private var generation = 0
    /// A look at the package's format once its first edit's upgrade is over (`EditorModel.flushed()`), one at a time.
    @ObservationIgnored private var formatCheck: Task<Void, Never>?

    private struct ListKey: Equatable {
        var takes: [String]
        var used: Set<String>
    }

    init(model: EditorModel) {
        self.model = model
        // On the next turn: made while a view reads it, nothing it shows changes during that view's update.
        Task { [weak self] in self?.watch() }
    }

    /// A take starts or stops being recorded in the app (`EditorModel.setRecording`).
    func recordingChanged(_ recording: Bool) {
        if isRecording != recording { isRecording = recording }
    }

    /// The package's format as the session has it now.
    fileprivate func noteFormat(_ format: Int) {
        if packageFormat != format { packageFormat = format }
    }

    fileprivate func began() {
        isRerecording = true
    }

    fileprivate func ended() {
        pending = nil
        if isRerecording { isRerecording = false }
    }

    /// Follows the editor's document and state: each change works the list out again (when what it depends on changed),
    /// and so does this first look.
    private func watch() {
        guard let model else { return }
        withObservationTracking {
            _ = model.document
            _ = model.state
        } onChange: { [weak self] in
            // Called before the change: read it once it is made.
            Task { @MainActor [weak self] in self?.watch() }
        }
        refresh()
    }

    /// The list for the project and the document as they are now, off the main thread (it reads each take's events the
    /// first time); the package's format, looked at again once a pending upgrade is over.
    private func refresh() {
        guard let model, model.state == .ready, let document = model.document, let project = model.overlayProject else {
            listedFrom = nil
            generation += 1
            if !list.isEmpty { list = [] }
            return
        }
        let format = project.manifest.formatVersion
        if packageFormat != format { packageFormat = format }
        if format < 3, model.canEdit, formatCheck == nil {
            // The first edit moves the package to 3 off the main thread, after the document shows it.
            formatCheck = Task { [weak self, weak model] in
                await model?.flushed()
                guard let self else { return }
                formatCheck = nil
                if let format = model?.overlayProject?.manifest.formatVersion, format != packageFormat { packageFormat = format }
            }
        }
        let key = ListKey(takes: project.takes.map(\.id), used: Set(document.sequence.map(\.take)))
        guard key != listedFrom else { return }
        listedFrom = key
        generation += 1
        let generation = generation
        Task {
            let takes = await Task.detached(priority: .userInitiated) { TakeCommands.takes(of: project, document: document) }.value
            guard generation == self.generation, takes != list else { return }
            list = takes
        }
    }

    /// A new id for what a step adds (`EditorModel.newID`), from any thread.
    nonisolated static func newID(_ prefix: String) -> String {
        prefix + String(format: "%08x", UInt32.random(in: .min ... .max))
    }
}

/// The Takes menu and "Re-record from Here" in the editor (phase 3 design §8.1, §8.2 and §8.5, 3d plan decisions 6 to 12).
///
/// "Re-record from Here" (⇧⌘R) keeps the playhead and the take under it, reads the project's script and finds the word of
/// it the cursor is at off the main thread, and asks the app (`EditorProjectHost.rerecord`), which hides the window and
/// opens the island on the same sources (`RecordingController.startRerecord`). The new take is recorded into the same
/// package by the recorder alone: the editor writes nothing into `takes/` nor the manifest meanwhile (its session only
/// writes its own edit files, and only for edits, which a hidden window takes none of). However the re-record ends, the
/// window comes back (`rerecordEnded`); with a take recorded the project opens again (`load()`, which sees the new take,
/// queues its analyses and keeps the log's undo) and one step, `take.rerecord`, puts it in at the playhead kept. Nothing
/// here deletes or moves a take: one not used stays in the package and in the Takes menu.
extension EditorModel {
    /// Why "Re-record from Here" cannot be done now (3d plan decision 8), shown as the item's help.
    enum RerecordBlock: Equatable {
        /// The project is not shown, or open for viewing only.
        case notEditable
        /// The package is of format 1 or 2: its first edit moves it to 3, which a take is added to.
        case olderPackage
        /// A take is being recorded (or this editor's re-record is under way).
        case recording
        /// This editor's export is running.
        case exporting
    }

    /// The Takes menu's rows (`EditorTakes.list`).
    var takes: [TakeInfo] { takesState.list }

    /// Why "Re-record from Here" cannot be done now; `nil` when it can.
    var rerecordBlock: RerecordBlock? {
        guard canEdit, document != nil, overlayProject != nil else { return .notEditable }
        if takesState.isRecording || takesState.isRerecording { return .recording }
        if isExporting { return .exporting }
        guard takesState.packageFormat >= 3 else { return .olderPackage }
        return nil
    }

    /// The text of `block`, for the help of the Takes menu's item.
    static func text(of block: RerecordBlock) -> String {
        switch block {
        case .notEditable:
            String(localized: "The project is open for viewing only.", comment: "Why Re-record from Here is disabled")
        case .olderPackage:
            String(
                localized: "To re-record, make a change to the project first.",
                comment: "Why Re-record from Here is disabled: a project of an earlier version takes a new take after its first edit")
        case .recording:
            String(localized: "A recording is already in progress.")
        case .exporting:
            String(localized: "An export is in progress.", comment: "Why Re-record from Here is disabled")
        }
    }

    /// "Re-record from Here" (⇧⌘R, the Takes menu): the playhead and the take under it kept, and the app asked at once,
    /// which hides the window (nothing can be edited from then on) while the script's word is worked out off the main
    /// thread from the document as it was. Whether it was asked for.
    @discardableResult
    func rerecordFromHere() -> Bool {
        // The format as it is now: a first edit's upgrade may have ended since the menu was drawn.
        if let project = overlayProject { takesState.noteFormat(project.manifest.formatVersion) }
        guard rerecordBlock == nil, !isGesturing, let document, let project = overlayProject, let actions = projectActions
        else { return false }
        let asked = ContinuousClock.now
        if isPlaying { pause() }
        let τ = playheadNanoseconds
        // The take shown at the playhead (the last clip's at the end), a clip with content's own take.
        let take = (playheadProject ?? project).take
        let style = TrackCommands.rulingCameraStyle(document, atOutput: τ, timeMap: TimeMap(sequence: document.sequence)).style
        let package = project.package
        let word = Task.detached(priority: .userInitiated) { Self.scriptWord(in: package, document: document, before: τ) }
        let target = RerecordTarget(packageURL: currentLocation)
        Self.rerecordLogger.notice("Re-record from \(τ, privacy: .public) ns, over \(take.id, privacy: .public)")
        takesState.began()
        takesState.pending = EditorTakes.Pending(output: τ, takeID: take.id, target: target)
        let request = EditorRerecordRequest(
            editor: self, target: target, scriptWord: word, take: take, cameraStyle: style, projectName: name, asked: asked)
        guard actions.rerecord(request) else {
            // Refused (a take records, another editor's re-record is under way): nothing was hidden.
            word.cancel()
            rerecordEnded(.nothing)
            return false
        }
        return true
    }

    /// The re-record this editor asked for ended (decision 10): with a take recorded, the project opens again with it
    /// (`load()`) and, once shown, `take.rerecord` puts it in at the playhead kept, in one step that undoes alone; with
    /// nothing, or to quit, nothing changes. The window is shown again by the app. Nothing without a re-record asked for.
    func rerecordEnded(_ outcome: RerecordOutcome) {
        guard let pending = takesState.pending else {
            takesState.ended()
            return
        }
        takesState.pending = nil
        switch outcome {
        case .recorded(let takeID):
            Self.rerecordLogger.notice("Re-recorded \(takeID, privacy: .public): opening the project again")
            load()
            Task {
                await applyRerecord(of: takeID, at: pending.output)
                takesState.ended()
            }
        case .nothing:
            takesState.ended()
        case .quit:
            Self.rerecordLogger.notice("The re-record's take was closed to quit: it stays in the package, unused")
            takesState.ended()
        }
    }

    /// Once the project shows the new take `takeID` (`load()` is opening it), `take.rerecord` at output instant `output`:
    /// the step worked out off the main thread from the document shown, and made again if the document changed
    /// meanwhile; then the playhead goes to the take's first frame. A project that can't be edited now keeps the take
    /// unused, in the Takes menu, and says so (`tellTakeNotApplied`).
    private func applyRerecord(of takeID: String, at output: Int64) async {
        while !closed, state == .opening || state == .recovering {
            await stateChange()
        }
        for _ in 0..<3 {
            guard !closed, state == .ready, canEdit, let document, let project = overlayProject else { break }
            guard let shown = project.focused(on: takeID) else {
                Self.rerecordLogger.error("The project opened again has no take \(takeID, privacy: .public)")
                break
            }
            let step = await Task.detached(priority: .userInitiated) {
                // Its events, read here the first time: never on the main thread.
                TakeCommands.rerecord(document, take: shown, atOutput: output, makeID: EditorTakes.newID)
            }.value
            guard !closed, state == .ready, let now = self.document else { break }
            guard now == document else { continue }
            guard let step, perform(step) != .refused else { break }
            Self.rerecordLogger.notice("Applied \(takeID, privacy: .public) from \(output, privacy: .public) ns")
            if let rate = self.document?.frameRate {
                // The first frame of the grid at or after the cut: the new take's first.
                var frame = Int((Double(output) * Double(rate) / 1e9).rounded(.up))
                while Int64(TimeMap.frameTime(frame, frameRate: rate)) < output { frame += 1 }
                seek(frame: frame)
            }
            return
        }
        Self.rerecordLogger.notice("The take \(takeID, privacy: .public) was not applied: it stays in the package, unused")
        guard !closed else { return }
        tellTakeNotApplied()
    }

    /// The new take is in the project but not in the video: said over the window (the Takes menu lists it, unused).
    private func tellTakeNotApplied() {
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "The new take couldn't be put in the video.",
            comment: "Re-record from Here recorded a take, but the editor could not put it in the video")
        alert.informativeText = String(
            localized: "It's in the project: the Takes menu lists it as Unused.",
            comment: "Re-record from Here: where the take that could not be put in the video is")
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Returns once `state` changes (observed, `withObservationTracking`), or after a second at most: the caller looks
    /// again, so a window closed meanwhile, which changes no state, never keeps it waiting.
    private func stateChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            withObservationTracking {
                _ = state
            } onChange: {
                once.resume()
            }
            Task {
                try? await Task.sleep(for: .seconds(1))
                once.resume()
            }
        }
    }

    /// "Use from Here" (`fromHere`) or "Add to End" of the Takes menu: the take `take` put in the sequence from the
    /// playhead or after its end (`TakeCommands`, one step `take.use`), worked out off the main thread; with nothing to put
    /// in, the system's beep.
    func useTake(_ take: TakeInfo, fromHere: Bool) {
        guard canEdit, !isGesturing, !take.isEmpty, let document, let shown = overlayProject?.focused(on: take.id) else {
            NSSound.beep()
            return
        }
        if isPlaying { pause() }
        let τ = playheadNanoseconds
        Task {
            let step = await Task.detached(priority: .userInitiated) {
                fromHere
                    ? TakeCommands.useFromHere(document, take: shown, atOutput: τ, makeID: EditorTakes.newID)
                    : TakeCommands.appendToEnd(document, take: shown, makeID: EditorTakes.newID)
            }.value
            // Another edit came first: what was worked out is of a document no longer shown.
            guard canEdit, self.document == document, let step, perform(step) != .refused else {
                NSSound.beep()
                return
            }
        }
    }

    /// The word of the package's script the teleprompter opens at for output instant `τ` (decision 12): the transcript's
    /// words said before `τ` aligned with the script (`teleprompterAlign-1`), at the start of that word's sentence;
    /// `nil` (the start) without a script or without words said before it. Reads `script.txt`: never on the main thread.
    nonisolated static func scriptWord(in package: ProjectPackage, document: EditDocument, before τ: Int64) -> Int? {
        guard let script = package.readScript() else { return nil }
        let words = ScriptWords(script)
        guard !words.words.isEmpty else { return nil }
        let spoken = ScriptPosition.spokenWords(before: τ, in: document, timeMap: TimeMap(sequence: document.sequence))
        guard !spoken.isEmpty else { return nil }
        return words.sentenceStart(of: ScriptPosition.word(in: words, spoken: spoken))
    }

    nonisolated static let rerecordLogger = Logger(subsystem: "dev.toma.Toma", category: "Rerecord")
}

/// Resumes a continuation once, whichever of its wakers comes first.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume() {
        let waiting = continuation.withLock { continuation in
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume()
    }
}

#if DEBUG
extension EditorModel {
    /// `TOMA_SHOWCASE_P3_RERECORD=<take id>`: the end of a "Re-record from Here" at `TOMA_SHOWCASE_PLAYHEAD` that recorded
    /// that take of the package, through what a real one does once the recorder tells it (`rerecordEnded(.recorded)`: the
    /// project opened again, then `take.rerecord`); `TOMA_SHOWCASE_P3_TAKES_MENU=<path>` writes the Takes menu's items
    /// into that text file, then; and `TOMA_SHOWCASE_P3_TIMELINE_PNG` the timeline as it is then.
    func showcaseRerecord(_ environment: [String: String]) async {
        if let takeID = environment["TOMA_SHOWCASE_P3_RERECORD"], let document {
            if let seconds = environment["TOMA_SHOWCASE_PLAYHEAD"].flatMap(Double.init) {
                scrub(toSeconds: seconds)
                endScrub()
            }
            let τ = playheadNanoseconds
            let take = playheadProject?.take.id ?? document.sequence.first?.take ?? ""
            takesState.began()
            takesState.pending = EditorTakes.Pending(output: τ, takeID: take, target: RerecordTarget(packageURL: currentLocation))
            rerecordEnded(.recorded(takeID: takeID))
            while takesState.isRerecording { try? await Task.sleep(for: .milliseconds(100)) }
            let clips = self.document?.sequence.map { "\($0.take) \($0.start.nanoseconds)…\($0.end.nanoseconds)" } ?? []
            print("rerecord: undo «\(undoLabel.map { "\($0)" } ?? "none")», sequence \(clips)")
        }
        if let path = environment["TOMA_SHOWCASE_P3_TAKES_MENU"] {
            // Once the list is worked out.
            try? await Task.sleep(for: .seconds(1))
            var lines = [TakesMenu.rerecordTitle + (rerecordBlock.map { " — " + Self.text(of: $0) } ?? "")]
            lines += takes.map { TakesMenu.title(of: $0) + ($0.isEmpty ? "" : " ▸ \(TakesMenu.useTitle) | \(TakesMenu.appendTitle)") }
            try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        if environment["TOMA_SHOWCASE_P3_RERECORD"] != nil, let path = environment["TOMA_SHOWCASE_P3_TIMELINE_PNG"] {
            try? await Task.sleep(for: .seconds(3))
            Self.writeTakesTimelinePNG(to: URL(filePath: path))
        }
    }
}
#endif
