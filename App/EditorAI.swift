// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import AppSupport
import Editing
import LocalAI
import Observation
import ProjectFormat

/// The local AI in the editor (fases 4 y 5 design §9, plan 5b decisions 6 to 13): Apple Intelligence's model on this Mac
/// proposes the video's chapters, its title and its summary from the transcript, and nothing it writes enters the
/// document without the user: the chapters go through the review sheet (`ChapterReviewSheet`) and its «Add», one step
/// `marker.chapters`; a suggested title or summary is one step `project.title` / `project.summary` that undoes.
///
/// One request at a time, each in a task of its own off the main thread; a newer request, a cancel or the editor closing
/// drops what an older one answers (`serial`). Whether the model can write is read again as the Info tab and the Markers
/// menu show, as the app comes to the front and before each request (decision 9): without it everything is dimmed with
/// the reason, and on macOS 15 the reason is «Requires macOS 26.».
@MainActor @Observable
final class EditorAI {
    enum Work: Equatable {
        case idle
        /// The chapters, at the part of the transcript being read (`nil` before the first).
        case chapters(AIProgress?)
        case title
        case summary
    }

    /// A field of the Info tab.
    enum Field: Hashable {
        case title, summary
    }

    /// What the chapters' review sheet shows (plan decision 13).
    enum Review: Equatable {
        /// Reading the transcript, at a part (`nil` before the first).
        case working(AIProgress?)
        /// What the model proposed, maybe nothing.
        case proposed(ChapterSuggestions)
        case noTranscript
        case tooShort
        case noWords
        case unavailable(AIUnavailableReason)
        /// The sentence of what failed.
        case failed(String)
    }

    /// Whether the model can write in the transcript's language (or, without one, the Mac's), as last read.
    private(set) var availability: AIAvailability
    private(set) var work = Work.idle
    /// The sentence of the last error of a title or a summary, under its field (`infoErrorField`); `nil` once another
    /// request starts.
    private(set) var infoError: String?
    private(set) var infoErrorField: Field?
    /// What the chapters' sheet shows while it is up; `nil` otherwise.
    private(set) var review: Review?

    /// The model each request asks (the system's; a scripted one in the screenshots).
    @ObservationIgnored var textModel: @Sendable () -> any TextModel
    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Counts the requests (and the cancels): only the latest one's answer is used.
    @ObservationIgnored private var serial = 0
    /// How many times «Suggest» was pressed in each field since the editor opened: the next one's `variation`.
    @ObservationIgnored private var suggested: [Field: Int] = [:]
    /// What the Info tab's fields show and haven't saved yet (typed with the focus on them): `commitDrafts()` saves it.
    @ObservationIgnored private var drafts: [Field: String] = [:]
    @ObservationIgnored private var sheet: NSWindow?
    @ObservationIgnored private var activation: NSObjectProtocol?
    @ObservationIgnored private var closed = false

    init(model: EditorModel, textModel: @escaping @Sendable () -> any TextModel = { SystemTextModel() }) {
        self.model = model
        self.textModel = textModel
        availability = textModel().availability(language: Self.language(of: model.document))
        // Apple Intelligence turned on or off in System Settings: read again as the app comes back.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAvailability() }
        }
    }

    // MARK: - Whether it can

    /// Reads again whether the model writes the transcript's language (BCP 47), or, without a transcript, the Mac's.
    func refreshAvailability() {
        guard !closed else { return }
        let next = textModel().availability(language: Self.language(of: model?.document))
        if next != availability { availability = next }
    }

    /// The project can be edited, the model writes and nothing is under way.
    var canPropose: Bool {
        model?.canEdit == true && availability == .available && work == .idle
    }

    /// As `canPropose`, with a transcript: «Suggest» of the title and the summary.
    var canSuggest: Bool {
        canPropose && model?.document?.transcript != nil
    }

    /// The reason in words (decision 9), as the Info tab and the Markers menu show it.
    static func text(_ reason: AIUnavailableReason) -> String {
        switch reason {
        case .needsMacOS26:
            String(localized: "Requires macOS 26.", comment: "Why the AI features are dimmed: Apple Intelligence's model needs macOS 26")
        case .deviceNotEligible:
            String(localized: "This Mac doesn't support Apple Intelligence.", comment: "Why the AI features are dimmed")
        case .appleIntelligenceNotEnabled:
            String(localized: "Apple Intelligence isn't turned on.", comment: "Why the AI features are dimmed: it is off in System Settings")
        case .modelNotReady:
            String(localized: "Apple Intelligence is still getting ready.", comment: "Why the AI features are dimmed: its model is still downloading")
        case .unsupportedLanguage(let language):
            String(
                localized: "Apple Intelligence doesn't write in \(Self.languageName(language)).",
                comment: "Why the AI features are dimmed: the model doesn't write the transcript's language; the language's name, lowercase in Spanish (“español (México)”)")
        case .unknown:
            String(localized: "Apple Intelligence isn't available.", comment: "Why the AI features are dimmed, for a reason Toma doesn't know")
        }
    }

    // MARK: - Chapters

    /// «Propose Chapters…»: the review sheet over the window, and the chapters asked for (the transcript read in parts,
    /// off the main thread). Without a transcript, or with the model unavailable, the sheet says so. `existing`: the
    /// output of each marker with a name.
    func proposeChapters() {
        guard !closed, let model, model.canEdit, work == .idle, sheet == nil, let document = model.document else { return }
        refreshAvailability()
        let first: Review
        if document.transcript == nil {
            first = .noTranscript
        } else if case .unavailable(let reason) = availability {
            first = .unavailable(reason)
        } else {
            first = .working(nil)
        }
        review = first
        guard let sheet = model.beginChapterReview(self) else {
            review = nil
            return
        }
        self.sheet = sheet
        guard first == .working(nil) else { return }

        let existing = model.visibleMarkers.filter { !$0.name.isEmpty }.map(\.output)
        let textModel = textModel()
        serial += 1
        let current = serial
        work = .chapters(nil)
        task = Task { [weak self] in
            let result = await Self.offMainThread(progress: { self?.progressed($0, current) }) { progress in
                try await ChapterSuggester(model: textModel).suggest(document: document, existing: existing, progress: progress)
            }
            self?.finishedChapters(result, current)
        }
    }

    private func progressed(_ progress: AIProgress, _ current: Int) {
        guard current == serial, !closed, case .chapters = work else { return }
        work = .chapters(progress)
        review = .working(progress)
    }

    private func finishedChapters(_ result: Result<ChapterSuggestions, any Error>, _ current: Int) {
        guard current == serial, !closed else { return }
        task = nil
        work = .idle
        switch result {
        case .success(let suggestions):
            review = .proposed(suggestions)
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            review = switch error as? AIError {
            case .noTranscript?: .noTranscript
            case .tooShort?: .tooShort
            case .noWords?: .noWords
            case .unavailable(let reason)?: .unavailable(reason)
            default: .failed(Self.sentence(error))
            }
        }
    }

    /// «Add N Chapters»: `chapters` as markers, in one step built on the document as it is now (`ChapterCommands.add`),
    /// said by VoiceOver; the sheet closes.
    func addChapters(_ chapters: [Chapter]) {
        defer { closeReview() }
        guard let model, model.canEdit, let document = model.document else { return }
        let addition = ChapterCommands.add(
            document, chapters, timeMap: TimeMap(sequence: document.sequence), recorded: model.recordedMarkers,
            makeID: EditorModel.newID)
        var said: [String] = []
        if let addition, model.perform(addition.step) != .refused {
            let count = addition.added + addition.named
            if count == 1 {
                said.append(String(localized: "1 chapter added.", comment: "VoiceOver, after «Add Chapters» of the chapters' sheet"))
            } else if count > 1 {
                said.append(String(localized: "\(count) chapters added.", comment: "VoiceOver, after «Add Chapters» of the chapters' sheet"))
            }
            if addition.skipped == 1 {
                said.append(String(localized: "1 already had a marker.", comment: "VoiceOver, after «Add Chapters»: a chapter fell on a marker with a name and was left out"))
            } else if addition.skipped > 1 {
                said.append(String(localized: "\(addition.skipped) already had a marker.", comment: "VoiceOver, after «Add Chapters»: chapters that fell on a marker with a name and were left out"))
            }
        }
        if said.isEmpty {
            said.append(String(localized: "No chapters were added.", comment: "VoiceOver, after «Add Chapters» when every chapter was left out"))
        }
        Self.announce(said.joined(separator: " "))
    }

    /// The playhead on the frame nearest output time `output`, paused: a click on a chapter's time in the sheet.
    func seek(toOutput output: Int64) {
        guard let model, model.canPlay, let document = model.document else { return }
        if model.isPlaying { model.pause() }
        let frameCount = TimeMap(sequence: document.sequence).frameCount(frameRate: document.frameRate)
        model.seek(frame: PlayheadRule.frame(nearest: Double(output) / 1e9, frameRate: document.frameRate, frameCount: frameCount))
    }

    /// «Transcribe», of the sheet or the Info tab without a transcript: the sheet closes, the transcription starts
    /// (`EditorVoice.transcribe()`) and the panel shows the Captions tab, where it goes on.
    func transcribeFirst() {
        guard let model else { return }
        closeReview()
        model.voice.transcribe()
        model.panelVisible = true
        model.panelTab = .captions
    }

    /// «Cancel» of the sheet: what it was reading stops and the sheet closes.
    func cancelReview() {
        cancel()
        closeReview()
    }

    private func closeReview() {
        review = nil
        guard let sheet else { return }
        self.sheet = nil
        sheet.sheetParent?.endSheet(sheet)
        // On the next turn, out of the button's action: the sheet's view goes with its window.
        Task { @MainActor in
            sheet.contentViewController = nil
            sheet.close()
        }
    }

    // MARK: - Title and summary

    /// «Suggest» of the title: the model's title (`variation` 0 the first time in this opening of the editor, another one
    /// each time after, decision 6) in the document in one step that undoes.
    func suggestTitle() { suggest(.title) }

    /// «Suggest» of the summary, as `suggestTitle()`.
    func suggestSummary() { suggest(.summary) }

    private func suggest(_ field: Field) {
        guard !closed, let model, model.canEdit, work == .idle, let document = model.document else { return }
        refreshAvailability()
        infoError = nil
        infoErrorField = nil
        if case .unavailable(let reason) = availability {
            failed(field, Self.text(reason))
            return
        }
        let variation = suggested[field, default: 0]
        suggested[field] = variation + 1
        let textModel = textModel()
        serial += 1
        let current = serial
        work = field == .title ? .title : .summary
        task = Task { [weak self] in
            let result = await Self.offMainThread(progress: { _ in }) { progress in
                let suggester = InfoSuggester(model: textModel)
                return switch field {
                case .title: try await suggester.title(document: document, variation: variation, progress: progress)
                case .summary: try await suggester.summary(document: document, variation: variation, progress: progress)
                }
            }
            self?.finishedInfo(result, field, current)
        }
    }

    private func finishedInfo(_ result: Result<String, any Error>, _ field: Field, _ current: Int) {
        guard current == serial, !closed else { return }
        task = nil
        work = .idle
        switch result {
        case .success(let text):
            switch field {
            case .title: setTitle(text)
            case .summary: setSummary(text)
            }
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            failed(field, Self.sentence(error))
        }
    }

    private func failed(_ field: Field, _ sentence: String) {
        infoError = sentence
        infoErrorField = field
    }

    /// Stops what is under way: nothing it answers reaches the document.
    func cancel() {
        serial += 1
        task?.cancel()
        task = nil
        work = .idle
    }

    /// The project's title, as typed (`InfoCommands.setTitle`, one step); nothing if it does not change. Its draft is
    /// gone.
    func setTitle(_ text: String) {
        drafts[.title] = nil
        guard let model, model.canEdit, let document = model.document, let step = InfoCommands.setTitle(document, text) else { return }
        model.perform(step)
    }

    /// The project's summary, as typed (`InfoCommands.setSummary`, one step); nothing if it does not change. Its draft
    /// is gone.
    func setSummary(_ text: String) {
        drafts[.summary] = nil
        guard let model, model.canEdit, let document = model.document, let step = InfoCommands.setSummary(document, text)
        else { return }
        model.perform(step)
    }

    /// The Info tab's `field` shows `text`, typed and not saved yet: what `commitDrafts()` saves.
    func draft(_ field: Field, _ text: String) {
        drafts[field] = text
    }

    /// What is typed in the Info tab and not saved yet, saved as leaving its field does (a step for each field): before
    /// the editor closes (⌘W, ⌘Q), the panel shows another tab, and Share or Export read the document's `info`.
    func commitDrafts() {
        let pending = drafts
        if let title = pending[.title] { setTitle(title) }
        if let summary = pending[.summary] { setSummary(summary) }
    }

    // MARK: - YouTube

    /// The summary, a blank line and the chapters (decision 14); `""` with neither.
    var youTubeDescription: String {
        guard let model, let document = model.document else { return "" }
        return YouTubeDescription.text(
            summary: document.info?.summary, chapters: model.chapters, duration: TimeMap(sequence: document.sequence).duration)
    }

    var canCopyYouTubeDescription: Bool { !youTubeDescription.isEmpty }

    /// «Copy Description for YouTube»: `youTubeDescription` on the clipboard, said by VoiceOver. Whether there was one.
    @discardableResult
    func copyYouTubeDescription() -> Bool {
        // The summary typed in the Info tab, saved before it is read (the Markers menu takes no focus).
        commitDrafts()
        let text = youTubeDescription
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Self.announce(String(localized: "Description copied.", comment: "VoiceOver: «Copy Description for YouTube» put the text on the clipboard"))
        return true
    }

    // MARK: - Closing

    /// The editor closed: what runs is cancelled, the sheet ends and nothing more reaches the document.
    func close() {
        guard !closed else { return }
        cancel()
        closeReview()
        closed = true
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
    }

    // MARK: - Helpers

    /// The language the model is asked to write: the transcript's, or, without one, the Mac's (BCP 47).
    private static func language(of document: EditDocument?) -> String {
        document?.transcript?.language ?? Locale.current.identifier(.bcp47)
    }

    /// `bcp47` in the user's language («español (México)»).
    private static func languageName(_ bcp47: String) -> String {
        Locale.current.localizedString(forIdentifier: bcp47) ?? bcp47
    }

    /// What a request that failed says, under its field or in the sheet (decision 8).
    static func sentence(_ error: any Error) -> String {
        switch error as? AIError {
        case .unavailable(let reason)?: text(reason)
        case .noTranscript?: String(localized: "This project has no transcript.")
        case .noWords?: String(localized: "Nothing said is left in the video.", comment: "The AI can't write: every word of the transcript is cut")
        case .tooShort?: String(localized: "The video is too short for chapters.")
        case .refused?: String(localized: "Apple Intelligence wouldn't write it for this video.", comment: "The model or its guardrails declined to write a title or a summary")
        case .contextTooLong?: String(localized: "The transcript is too long for Apple Intelligence.")
        case .busy?: String(localized: "Apple Intelligence is busy. Try again in a moment.")
        case .failed(let description)?:
            String(localized: "Apple Intelligence couldn't answer: \(description)", comment: "The model failed; the system's description follows")
        case nil: String(localized: "Apple Intelligence couldn't answer: \(error.localizedDescription)", comment: "The model failed; the system's description follows")
        }
    }

    private static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text])
    }

    /// `work` off the main thread, its progress told here in order; cancelling the task that awaits it cancels it.
    private static func offMainThread<Answer: Sendable>(
        progress: @escaping (AIProgress) -> Void,
        _ work: @escaping @Sendable (@escaping @Sendable (AIProgress) -> Void) async throws -> Answer
    ) async -> Result<Answer, any Error> {
        let (stream, continuation) = AsyncStream.makeStream(of: AIProgress.self)
        let inner = Task.detached(priority: .userInitiated) { () -> Result<Answer, any Error> in
            defer { continuation.finish() }
            do {
                return .success(try await work { continuation.yield($0) })
            } catch {
                return .failure(error)
            }
        }
        return await withTaskCancellationHandler {
            for await step in stream { progress(step) }
            return await inner.value
        } onCancel: {
            inner.cancel()
        }
    }
}
