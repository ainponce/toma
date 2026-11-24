// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Analysis
import Export
import Foundation
import Observation
import ProjectFormat
import Sharing
import Synchronization
import os

/// Share, the editor's (plan 5a, Task S4; design §8.2–§8.4): the video uploaded with its poster and its page to the
/// person's own storage, and the link to it. Nothing connects until "Share" or "Delete from Storage" is chosen: opening
/// the little window (`ShareControl`) only reads the settings, whether the Keychain has the secret (never the secret
/// itself, which only sharing reads), and the project's `shares.json`, off the main thread.
///
/// A share holds the app's `ExportGate` from its start to its end (export and upload: one heavy job at a time, and the
/// update and quitting wait for it); closing the window cancels it without asking (the project loses nothing and what
/// was uploaded is removed), and quitting cancels it as it cancels an export (`EditorModel.cancelExportAndWait`).
@MainActor @Observable
final class EditorShare {
    enum State: Equatable {
        case idle
        case running(ShareProgress)
        case finished(ShareRecord)
        /// Why it failed, in words (`ShareTexts`).
        case failed(String)
    }

    /// What the little window says of a link once it was copied.
    struct Copied: Equatable {
        var id: String
        var note: ShareRules.LinkNote
    }

    /// Why "Delete from Storage" failed, in words, under the link it was chosen for.
    struct DeleteProblem: Equatable {
        var id: String
        var text: String
    }

    private(set) var state: State = .idle
    /// The project's links (`shares.json`), newest first, as read when the little window opened and since.
    private(set) var records: [ShareRecord] = []
    /// Why the links of before cannot be listed (`shares.json` is unreadable); `nil` when they can.
    private(set) var historyProblem: String?
    /// Settings ▸ Share as read when the little window opened (or a share started).
    private(set) var preferences = SharePreferences()
    /// Whether Settings ▸ Share make a configuration with the secret the Keychain has (`ShareRules.isConfigured`: asked
    /// whether the secret is there, never read), as found when the little window opened.
    private(set) var isConfigured = false
    /// The settings and the links were read once: until then nothing is said of them.
    private(set) var isLoaded = false
    /// A share was cancelled and is removing what it uploaded.
    private(set) var isCancelling = false
    /// The links being removed from the storage, by id.
    private(set) var deleting: Set<String> = []
    /// Why "Delete from Storage" failed, of which link.
    private(set) var deleteProblem: DeleteProblem?
    /// The last link copied, and what was said of it.
    private(set) var copied: Copied?
    /// What the share's export said once it was done (what it had to leave out, a cleanup it skipped).
    private(set) var notices: [String] = []
    /// The little window is open.
    var isPresented = false


    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    /// Another export of the app runs (the gate is taken, not by this share): "Share" waits.
    var waitsForAnExport: Bool {
        !isRunning && (model?.exportGate.isBusy ?? false)
    }

    /// Whether "Share" can start now: the project open and editable, nothing else exporting.
    var canStart: Bool {
        !isRunning && (model?.canExport ?? false)
    }

    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The "Delete from Storage" on their way, by the link's id.
    @ObservationIgnored private var deletions: [String: Task<Void, Never>] = [:]
    /// The last MP4 this editor exported in this session (decision 11).
    @ObservationIgnored private var remembered: RememberedExport?
    #if DEBUG
    /// `TOMA_SHOWCASE_SHARE`: the state is made up, and nothing is read.
    @ObservationIgnored private var isShowcase = false
    #endif

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Share")

    /// The session every upload of the app goes through: ephemeral, nothing kept (`S3Client.ephemeralSession()`).
    nonisolated private static let session = S3Client.ephemeralSession()

    init(model: EditorModel, secrets: any SecretStore = KeychainSecretStore()) {
        self.model = model
        self.secrets = secrets
    }

    /// The service the app uploads with, its page in the app's language.
    nonisolated static func service() -> ShareService {
        ShareService(session: session, labels: pageLabels)
    }

    /// The page's words: "Chapters" and the language, the app's.
    nonisolated static var pageLabels: SharePage.Labels {
        let language = Bundle.main.preferredLocalizations.first { $0.caseInsensitiveCompare("Base") != .orderedSame } ?? "en"
        return SharePage.Labels(
            chapters: String(localized: "Chapters", comment: "The heading of the chapters on a shared video's web page"),
            language: language)
    }

    // MARK: - Reading

    /// Reads Settings ▸ Share, whether the Keychain has the secret, and the project's links, off the main thread: the
    /// little window opened. Connects to nothing.
    func refresh() {
        #if DEBUG
        if isShowcase { return }
        #endif
        let preferences = SettingsStore().settings.share
        self.preferences = preferences
        let secrets = secrets
        let package = model?.exportProject?.package
        loading?.cancel()
        loading = Task {
            let (configured, history) = await Task.detached { () -> (Bool, Result<[ShareRecord], any Error>?) in
                (
                    ShareRules.isConfigured(preferences, secrets: secrets),
                    package.map { package in Result { try ShareHistory(package: package).records() } }
                )
            }.value
            guard !Task.isCancelled else { return }
            isConfigured = configured
            switch history {
            case .success(let records)?:
                self.records = records
                historyProblem = nil
            case .failure(let error)?:
                Self.logger.error("Cannot read shares.json: \(String(describing: error), privacy: .public)")
                historyProblem = String(
                    localized: "The earlier links can't be listed: the project's shares.json can't be read.",
                    comment: "Share: the project's shares.json is unreadable; “shares.json” stays as it is")
            case nil:
                break
            }
            isLoaded = true
        }
    }

    // MARK: - Sharing

    /// "Share": the document as it is now, exported (or the last export, when it is the same video), its poster and its
    /// page uploaded, and the link added to `shares.json` (`ShareJob.run`), with the app's `ExportGate` taken throughout.
    func start() {
        #if DEBUG
        if isShowcase { return }
        #endif
        guard canStart, let model, let session = model.panelSession, let project = model.exportProject else { return }
        // The title and the summary typed in the Info tab, saved before the page reads them.
        model.ai.commitDrafts()
        let document = session.document
        let settings = SettingsStore().settings
        let preferences = settings.share
        let quality: ExportQuality = settings.export.highQuality ? .high : .standard
        let recorded = model.recordedMarkers, name = model.name, introTitle = EditorModel.introTitle
        let localizations = Bundle.main.preferredLocalizations
        let remembered = remembered, secrets = secrets, gate = model.exportGate
        self.preferences = preferences
        copied = nil
        notices = []
        deleteProblem = nil
        isCancelling = false
        gate.isBusy = true
        state = .running(ShareProgress(phase: .exporting, fraction: 0))
        let throttle = ShareProgressThrottle()
        task = Task {
            do {
                let inputs = try await Task.detached {
                    try ShareInputs.make(
                        project: project, document: document, recorded: recorded, projectName: name, introTitle: introTitle)
                }.value
                let record = try await ShareJob.run(
                    package: project.package, inputs: inputs, preferences: preferences, secrets: secrets,
                    service: Self.service(),
                    makeVideo: { request, suggested, progress in
                        if let reused = ShareRules.reusable(remembered, for: request, bytesNow: Self.fileSize(remembered?.url)) {
                            return reused
                        }
                        let chapters = MarkerRulerRules.fileChapters(
                            request.chapters, kind: .mp4, isOn: true, localizations: localizations)
                        let settings = ExportSettings(
                            outputSize: request.outputSize, framesPerSecond: request.framesPerSecond, quality: quality,
                            codec: .h264, chapters: chapters.chapters, chapterLanguage: chapters.language)
                        let said = try await model.exportVideo(
                            document, settings: settings, range: nil, to: suggested, progress: progress)
                        await self.exported(saying: said)
                        return suggested
                    },
                    progress: { progress in
                        guard throttle.shouldReport(progress) else { return }
                        Task { @MainActor in self.progressed(progress) }
                    })
                state = .finished(record)
                records.removeAll { $0.id == record.id }
                records.insert(record, at: 0)
                historyProblem = nil
            } catch let error where Self.isCancellation(error) {
                state = .idle
            } catch {
                Self.logger.error("Share failed: \(String(describing: error), privacy: .public)")
                state = .failed(ShareTexts.describe(error))
            }
            isCancelling = false
            gate.isBusy = false
            task = nil
        }
    }

    /// "Cancel": the share stops, and what it uploaded is removed before it ends.
    func cancel() {
        guard let task else { return }
        isCancelling = true
        task.cancel()
    }

    /// Cancels the share in progress and waits for it to end (quitting): what it uploaded is removed, its temporary
    /// folder too; at most `cleanupLimit`, so a stuck network never keeps the app from quitting.
    func cancelAndWait() async {
        guard let task else { return }
        cancel()
        await Self.wait(for: [task], atMost: Self.cleanupLimit)
    }

    /// How long closing the window or quitting waits for a cancelled share's cleanup: the quit's limit for the editors.
    nonisolated static let cleanupLimit = QuitSequencer.editorsTimeLimit

    /// Returns once every one of `work` has ended, or once `limit` has passed (on the suspending clock); what is still
    /// running goes on.
    nonisolated private static func wait(for work: [Task<Void, Never>], atMost limit: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for task in work { await task.value }
            }
            group.addTask {
                try? await Task.sleep(for: limit, clock: .suspending)
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// The editor's window closed: the share in progress is cancelled, and what has to end before the editor is done
    /// closing is given back, its cleanup (removing what it uploaded) and a "Delete from Storage" on its way, so the
    /// window's closing (and a quit right after it) waits for them (`EditorModel.close()`), at most `cleanupLimit`. `nil`
    /// when nothing runs.
    func cancelForClose() -> Task<Void, Never>? {
        cancel()
        let pending = [task].compactMap { $0 } + Array(deletions.values)
        guard !pending.isEmpty else { return nil }
        return Task {
            await Self.wait(for: pending, atMost: Self.cleanupLimit)
        }
    }

    private func progressed(_ progress: ShareProgress) {
        guard case .running(let shown) = state, progress != shown, !isCancelling else { return }
        state = .running(progress)
    }

    private func exported(saying notices: [String]) {
        self.notices = notices
    }

    /// The last MP4 this editor exported, to upload instead of exporting it again (decision 11).
    func remember(_ export: RememberedExport) {
        remembered = export
    }

    /// The MP4 the export sheet just wrote to `url`, remembered once its document's hash and its size are known (off the
    /// main thread).
    func remember(_ document: EditDocument, settings: ExportSettings, range: ExportRange?, at url: URL) {
        Task {
            let export = await Task.detached { () -> RememberedExport? in
                guard let hash = try? ShareInputs.documentHash(document), let bytes = Self.fileSize(url) else { return nil }
                return RememberedExport(
                    url: url, documentHash: hash, outputSize: settings.outputSize, framesPerSecond: settings.framesPerSecond,
                    codec: settings.codec.rawValue, wholeVideo: range == nil, bytes: bytes, chapters: settings.chapters)
            }.value
            if let export { remember(export) }
        }
    }

    // MARK: - The links

    /// "Copy": the link on the clipboard, as text; what is said of it (design §8.4: whether it is public or when it expires).
    @discardableResult
    func copy(_ record: ShareRecord) -> ShareRules.LinkNote {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.url, forType: .string)
        let note = ShareRules.note(for: record, now: Date())
        copied = Copied(id: record.id, note: note)
        return note
    }

    /// "Open": the link in the browser, if it is a web link (`ShareRules.webLink`): a `shares.json` that came with a
    /// package from elsewhere never opens a file or another app.
    func open(_ record: ShareRecord) {
        guard let url = ShareRules.webLink(record.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// "Delete from Storage", once confirmed: the link's three objects removed from the storage, then its row from
    /// `shares.json` (`ShareJob.delete`); if the storage fails the row stays, and why is said under it.
    func delete(_ record: ShareRecord) {
        #if DEBUG
        if isShowcase { return }
        #endif
        guard let project = model?.exportProject, !deleting.contains(record.id) else { return }
        let preferences = SettingsStore().settings.share, secrets = secrets
        deleting.insert(record.id)
        if deleteProblem?.id == record.id { deleteProblem = nil }
        deletions[record.id] = Task {
            do {
                try await ShareJob.delete(
                    record, package: project.package, preferences: preferences, secrets: secrets, service: Self.service())
                records.removeAll { $0.id == record.id }
                if case .finished(let shown) = state, shown.id == record.id { state = .idle }
                if copied?.id == record.id { copied = nil }
            } catch {
                Self.logger.error("Delete of a share failed: \(String(describing: error), privacy: .public)")
                deleteProblem = DeleteProblem(id: record.id, text: ShareTexts.describe(error))
            }
            deleting.remove(record.id)
            deletions[record.id] = nil
        }
    }

    // MARK: - Private

    nonisolated private static func fileSize(_ url: URL?) -> Int64? {
        guard let url, let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true, let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? ShareError) == .cancelled || (error as? ExportError) == .cancelled
    }

    #if DEBUG
    /// `TOMA_SHOWCASE_SHARE` (`Showcase+Share`): the little window open on a made-up state, with made-up settings and
    /// links; nothing is read, nothing connects.
    func showcase(
        state: State, records: [ShareRecord], preferences: SharePreferences, hasSecret: Bool, copied: Copied? = nil
    ) {
        isShowcase = true
        self.state = state
        self.records = records
        self.preferences = preferences
        isConfigured = ShareConfiguration.problems(in: preferences, hasSecret: hasSecret).isEmpty
        self.copied = copied
        isLoaded = true
        isPresented = true
    }
    #endif
}

/// Lets a share's progress through at most every half percent, but always a change of phase and the end: from off the
/// main thread, each one a hop to it.
private final class ShareProgressThrottle: Sendable {
    private let last = Mutex<ShareProgress?>(nil)

    func shouldReport(_ progress: ShareProgress) -> Bool {
        last.withLock { last in
            guard let shown = last, shown.phase == progress.phase, progress.fraction < 1,
                progress.fraction - shown.fraction < 0.005
            else {
                last = progress
                return true
            }
            return false
        }
    }
}
