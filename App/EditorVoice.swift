// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import AppSupport
import Editing
import Export
import Observation
import ProjectFormat
import ProjectJobs
import Speech
import Transcription
import os

/// The voice in the editor (phase 2 design §5.1, §5.5–§5.7 and §10; plan 2a decisions 2, 7, 9, 13 and 17): the
/// transcription, the clean voice and the loudness of the project's take, through the base's seam (`EditorModel.jobs`,
/// `updateAnalysis(_:)`, `exportPreparations`).
///
/// - **Transcribing.** As the project opens, a document without a transcript is transcribed by itself when Settings ▸
///   General ▸ "Transcribe Automatically" is on, on macOS 26, with the model of its language installed (what
///   `SpeechTranscriber.installedLocales` lists), the project editable, and its document already of version 3 on disk
///   or its package recorded by this launch (`AutomaticTranscription`: an untouched project of phase 1 never changes by
///   being opened); otherwise with `transcribe()`, the Captions tab's Transcribe. The job runs
///   in the project's queue (never while a take records) and what it makes becomes one step, `transcript.create`; if
///   the project cannot be edited by then, it is dropped. Transcribing again asks first when corrections would be lost
///   ("Transcribing again replaces %lld corrected words.").
/// - **Several takes** (phase 3 design §8.1, plan 3d decision 16). Transcribing runs one job for each take of the
///   sequence whose words the transcript lacks in the language chosen (`SequenceTranscription.takes(toTranscribe:)`;
///   each of them again once none lacks its own), one after the other in the sequence's order, and each one's words go
///   into the document as they arrive (`TranscriptCommands.mergeTakes`), asking first if corrections of that take alone
///   would be lost; the Captions tab says which of them it is on ("Transcribing 2 of 3…"). With the document transcribed
///   and "Transcribe Automatically" on, a take that comes into the sequence is transcribed by itself in the document's
///   language, once in each opening.
/// - **The clean voice and the loudness.** With each document whose needs change (a microphone's cleanup above 0 or
///   not, Normalize, the takes its sequence shows), the jobs `SequenceVoiceJobs.needed` lists are enqueued, off the main
///   thread: those the queue has no state for, and a job done whose cache is missing again (macOS emptied the caches)
///   once. Each take the sequence shows has its own (phase 3 design §8.1): a take new in it puts its jobs in the queue.
///   Each of them that is done, and each change of the needs, has `SequenceVoiceJobs.applied` read the caches off the
///   main thread and hands the clean voice and the loudness to the preview's mix with `updateAnalysis` (the latest read
///   wins).
/// - **The export.** `prepareExport` waits for what the exported document lacks (`SequenceVoiceJobs.prepareExport`),
///   reporting its progress, and hands it to the export; a project cleaned on a Mac with the voice isolation exports dry
///   here, and says so once it is done.
@MainActor @Observable
final class EditorVoice {
    /// Where the transcription of the takes is, as the Captions tab shows it.
    enum Transcription: Equatable {
        /// This macOS has no `SpeechTranscriber`: "Transcription needs macOS 26."
        case needsMacOS26
        /// This Mac cannot transcribe (`SpeechTranscriber.isAvailable` is false, or it transcribes no language).
        case unavailable
        /// No take of the sequence has a microphone, system audio or device audio that recorded anything.
        case noAudio
        /// Nothing under way and no transcript: the Transcribe button.
        case idle
        /// Asked for, waiting its turn in the queue (with several takes, the one it is on: `transcriptionCount`).
        case queued
        /// Hearing the words of a take, from 0 to 1 (with several, of the one it is on: `transcriptionCount`).
        case running(Double)
        /// The last transcription failed, with the sentence that says why.
        case failed(String)
        /// The document has its transcript.
        case done
    }

    /// A language `speechTranscriber-1` transcribes, as the language menu shows it.
    struct Language: Identifiable, Equatable {
        /// BCP 47 (`es-MX`).
        let id: String
        /// In the user's language ("Español (México)").
        let name: String
        /// Its model is on this Mac.
        let installed: Bool
    }

    /// Which of the takes being transcribed it is on: the `take`th (from 1) of `of`.
    struct TakeCount: Equatable {
        var take: Int
        var of: Int
    }

    private(set) var transcription = Transcription.idle
    /// While a transcription of more than one take is under way, which of them it is on; `nil` otherwise.
    private(set) var transcriptionCount: TakeCount?
    /// The languages to choose from, by name; empty until they are found, and on macOS 15.
    private(set) var languages: [Language] = []
    /// The language the next transcription is in (BCP 47); choosing one remembers it (`TranscriptionPreferences`). Empty
    /// until it is found, or when no language is transcribed here.
    var language: String {
        get { chosenLanguage }
        set { choose(newValue) }
    }
    /// Whether the model of `language` is on this Mac.
    private(set) var modelStatus = LanguageModelStatus.unsupported
    /// "Download the Language" under way, from 0 to 1; `nil` otherwise.
    private(set) var downloadProgress: Double?
    /// How far the cleaning of each microphone being cleaned is, by `AudioPlan.key(take:track:)`, 0 to 1 (its segments'
    /// jobs on average); a track that is not being cleaned has none.
    private(set) var cleanupProgress: [String: Double] = [:]
    /// How far the loudness being measured is, 0 to 1; `nil` while none is.
    private(set) var loudnessProgress: Double?
    /// Whether this Mac has the system's voice isolation (`AUSoundIsolation`); found off the main thread as the project
    /// opens (true until then).
    private(set) var isolationAvailable = true
    /// "Hide During Silences" is finding them.
    private(set) var isFindingSilences = false
    /// The word the Captions tab is to show, set by `reveal(_:)`; the tab clears it once shown.
    var revealed: TranscriptWordRef?

    private var chosenLanguage = ""
    /// What the queue last said of the voice's jobs.
    private var states: [AnalysisJobKind: JobState] = [:]
    /// The sentence of the last transcription that failed; `nil` once another one is asked for.
    private var transcriptionFailure: String?
    /// Whether this Mac transcribes (macOS 26 and `SpeechTranscriber.isAvailable`); `nil` until found.
    private var speechAvailable: Bool?

    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private var project: LoadedProject?
    @ObservationIgnored private var voiceJobs: SequenceVoiceJobs?
    /// The session's document, as last told.
    @ObservationIgnored private var document: EditDocument?
    /// Whether a take the sequence shows has something to transcribe (`SequenceTranscription.transcribable`).
    @ObservationIgnored private var transcribable = false
    /// The jobs of the transcription under way, one for each take it hears, in order, and the one it is on.
    @ObservationIgnored private var batch: [AnalysisJobKind] = []
    @ObservationIgnored private var batchIndex = 0
    /// Cancel was pressed: the transcription under way hears no more takes.
    @ObservationIgnored private var batchCancelled = false
    /// The takes transcribed (or asked for) since the project opened: a take new to the sequence is transcribed by
    /// itself once, never again after it failed or was cancelled.
    @ObservationIgnored private var tried: Set<String> = []
    /// The needs the jobs were asked for and the caches read with; `nil` until the project opened.
    @ObservationIgnored private var needs: Needs?
    /// The cleanup jobs of each track since it last had none waiting or running, and the loudness jobs likewise: what
    /// the progress is the average of.
    @ObservationIgnored private var cleanupBatches: [String: Set<AnalysisJobKind>] = [:]
    @ObservationIgnored private var loudnessBatch: Set<AnalysisJobKind> = []
    /// The jobs done whose cache was missing again and that were asked for once more, until `needed` leaves them out.
    @ObservationIgnored private var askedAgain: Set<AnalysisJobKind> = []
    @ObservationIgnored private let preferences = TranscriptionPreferencesStore()
    /// Counts the openings and the readings of the caches, so only the latest one's outcome is used.
    @ObservationIgnored private var opening = 0
    @ObservationIgnored private var reading = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var enqueueTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "EditorVoice")

    /// What a document needs of the voice's jobs: what `SequenceVoiceJobs.needed` and `applied` read of it.
    private struct Needs: Equatable {
        /// The tracks with a cleanup above 0, by `AudioPlan.key(take:track:)`.
        var cleaned: Set<String>
        var normalize: Bool
        /// The takes the sequence shows, in its order (`SequenceAnalyses.takes(shownBy:in:)`).
        var takes: [String]

        init(_ document: EditDocument, project: LoadedProject) {
            cleaned = Set(document.audio.tracks.filter { $0.value.cleanup > 0 }.keys)
            normalize = document.audio.normalize
            takes = SequenceAnalyses.takes(shownBy: document, in: project).map(\.id)
        }
    }

    /// The voice of `model`'s project, which it holds weakly.
    init(model: EditorModel) {
        self.model = model
    }

    // MARK: - What the editor tells it

    /// The session opened `project` (its take), with its analysis caches `caches` and `document`: what was there before is
    /// forgotten, the jobs' states are followed, what `document` needs is asked for and read, and the languages are found
    /// (off the main thread), then a document without a transcript is transcribed if it is to be by itself.
    func opened(project: LoadedProject, caches: ProjectCaches, document: EditDocument) {
        guard !closed else { return }
        self.project = project
        self.document = document
        needs = nil
        cleanupBatches = [:]
        loudnessBatch = []
        askedAgain = []
        tried = []
        transcriptionFailure = nil
        let voiceJobs = SequenceVoiceJobs(project: project, caches: caches, engine: Self.engine(), isolator: SystemVoiceIsolation())
        self.voiceJobs = voiceJobs
        listen()
        follow(document)
        refreshTranscription()
        opening += 1
        let current = opening
        let saved = preferences.preferences
        openTask?.cancel()
        openTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                (isolation: SoundIsolation.isAvailable, speech: SpeechLanguages.isAvailable())
            }.value
            let languages = await Self.findLanguages()
            var language = document.transcript.map { Locale(identifier: $0.language).identifier(.bcp47) } ?? saved.language
            if language.map({ id in !languages.contains { $0.id == id } }) ?? true {
                language = await SpeechLanguages.defaultLanguage()
            }
            var status = LanguageModelStatus.unsupported
            if let language { status = await SpeechLanguages.status(of: language) }
            #if DEBUG
            if let language { await Self.logModelInventory(language) }
            #endif
            guard let self, !self.closed, current == self.opening else { return }
            self.isolationAvailable = found.isolation
            self.speechAvailable = found.speech
            self.languages = languages
            self.chosenLanguage = language ?? ""
            self.modelStatus = status
            self.refreshTranscription()
            // Never on an untouched project of phase 1: its step would migrate it and turn its captions on.
            if let model = self.model, AutomaticTranscription.starts(
                automatic: saved.automatic, modelInstalled: status == .installed, hasTranscript: self.document?.transcript != nil,
                canEdit: model.canEdit, documentIsCurrentOnDisk: model.documentIsCurrentOnDisk,
                recordedThisSession: model.recordedThisSession)
            {
                self.transcribe()
            } else {
                self.transcribeNewTakes()
            }
        }
    }

    /// The session's document changed: whether it has a transcript is shown, and what it needs is asked for and read, if
    /// that changed.
    func documentChanged(_ document: EditDocument) {
        guard !closed, project != nil else { return }
        self.document = document
        refreshTranscription()
        follow(document)
    }

    /// The editor closed: nothing more is asked for, read or handed over (the editor cancels the jobs, the transcription
    /// among them), and a download under way is cancelled.
    func close() {
        guard !closed else { return }
        closed = true
        for task in [updatesTask, openTask, enqueueTask, readTask, transcriptionTask, downloadTask, statusTask] { task?.cancel() }
        updatesTask = nil
        openTask = nil
        enqueueTask = nil
        readTask = nil
        transcriptionTask = nil
        downloadTask = nil
        statusTask = nil
        project = nil
        voiceJobs = nil
        document = nil
    }

    // MARK: - Transcribing

    /// Transcribes in `language`, first in the queue, the takes of the sequence whose words the transcript lacks in it, or
    /// each of them again once none does (`SequenceTranscription.takes(toTranscribe:)`): what each one hears goes into the
    /// document as it arrives, in one step (after asking, if corrections of that take would be lost). Nothing if it
    /// cannot be edited, there is nothing to transcribe or one is under way. With one take, the phase 2's.
    func transcribe() {
        transcribe(in: chosenLanguage, takes: nil)
    }

    /// Stops the transcription under way, or takes it out of the queue: nothing more reaches the document (the takes
    /// already transcribed stay).
    func cancelTranscription() {
        guard transcriptionTask != nil else { return }
        batchCancelled = true
        guard batch.indices.contains(batchIndex), let jobs = model?.jobs else { return }
        let kind = batch[batchIndex]
        Task { await jobs.cancel(kind) }
    }

    /// Transcribes in `language` the takes `takes` of the sequence (those `transcribe()` picks when `nil`), one after the
    /// other in its order, each first in the queue, and puts each one's words in the document as they arrive. Stops at a
    /// cancel or once the language's model is gone; a take that fails says so and the next one goes on.
    private func transcribe(in language: String, takes: [String]?) {
        guard !closed, transcriptionTask == nil, let voiceJobs, let project, let model, model.canEdit, !language.isEmpty,
              let document = model.document
        else { return }
        let jobs = model.jobs
        transcriptionFailure = nil
        batch = []
        batchIndex = 0
        batchCancelled = false
        transcriptionTask = Task { [weak self] in
            let wanted = takes ?? SequenceTranscription.takes(
                toTranscribe: document, shown: SequenceAnalyses.takes(shownBy: document, in: project), language: language)
            // `transcriptions` reads what `VoiceJobs` reads: off the main thread.
            let all = await Task.detached(priority: .userInitiated) {
                voiceJobs.transcriptions(language: language, document: document)
            }.value
            let jobsToRun = all.filter { kind, _ in Self.take(of: kind).map(wanted.contains) ?? false }
            guard let self, !self.closed else { return }
            self.batch = jobsToRun.map(\.0)
            self.tried.formUnion(wanted)
            for (index, (kind, work)) in jobsToRun.enumerated() where !self.batchCancelled {
                self.batchIndex = index
                self.refreshTranscription()
                let outcome: Result<JobOutput, any Error>
                do {
                    outcome = .success(try await jobs.result(of: kind, work: work))
                } catch {
                    outcome = .failure(error)
                }
                guard !self.closed else { return }
                var stop = false
                switch outcome {
                case .success(.transcript(let transcript)):
                    await self.transcribed(transcript)
                case .success(.cached):
                    break
                case .failure(let error as JobError):
                    Self.logger.error("The transcription failed: \(String(describing: error.problem), privacy: .public)")
                    if case .modelNotInstalled = error.problem {
                        // Its model went away: the tab offers to download it.
                        self.refreshStatus()
                        stop = true
                    } else {
                        self.transcriptionFailure = Self.failure(error.problem)
                    }
                case .failure:
                    // Cancelled.
                    stop = true
                }
                guard !self.closed else { return }
                // Nothing more could go into the document.
                if self.model?.canEdit != true { stop = true }
                if stop { break }
            }
            self.transcriptionTask = nil
            self.batch = []
            self.batchIndex = 0
            self.refreshTranscription()
            // A take that came into the sequence meanwhile.
            self.transcribeNewTakes()
        }
        refreshTranscription()
    }

    /// With the document transcribed and "Transcribe Automatically" on, transcribes by itself, in the document's language,
    /// the takes of the sequence it lacks (`SequenceTranscription.newTakes`) that were not transcribed since the project
    /// opened, if the model of that language is the one chosen and installed and nothing is transcribing.
    private func transcribeNewTakes() {
        guard !closed, transcriptionTask == nil, speechAvailable == true, let project, let model, model.canEdit,
              let document = model.document, let transcript = document.transcript, preferences.preferences.automatic,
              modelStatus == .installed, Locale(identifier: transcript.language).identifier(.bcp47) == chosenLanguage
        else { return }
        let new = SequenceTranscription.newTakes(document, shown: SequenceAnalyses.takes(shownBy: document, in: project))
            .filter { !tried.contains($0) }
        guard !new.isEmpty else { return }
        transcribe(in: chosenLanguage, takes: new)
    }

    /// The take of a transcription job; `nil` for any other kind.
    private nonisolated static func take(of kind: AnalysisJobKind) -> String? {
        if case .transcription(let take, _) = kind { take } else { nil }
    }

    /// "Download the Language": the model of `language`, with its progress (`downloadProgress`). The only place a model is
    /// downloaded; closing the editor cancels it.
    func downloadLanguage() {
        guard !closed, downloadTask == nil, !chosenLanguage.isEmpty, modelStatus == .downloadable else { return }
        let language = chosenLanguage
        downloadProgress = 0
        modelStatus = .downloading
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in self?.downloaded(fraction) }
        }
        downloadTask = Task { [weak self] in
            do {
                try await SpeechLanguages.download(language, progress: report)
            } catch {
                if !(error is CancellationError) {
                    Self.logger.error("Cannot download \(language, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            guard let self, !self.closed else { return }
            self.downloadTask = nil
            self.downloadProgress = nil
            let languages = await Self.findLanguages()
            guard !self.closed else { return }
            self.languages = languages
            self.refreshStatus()
        }
    }

    /// Shows the word `ref` in the Captions tab.
    func reveal(_ ref: TranscriptWordRef) {
        guard let model else { return }
        model.panelVisible = true
        model.panelTab = .captions
        revealed = ref
    }

    // MARK: - Hiding the camera

    /// "Hide During Silences" (plan decision 9): a Screen Only block in each silence of 3 s or more, in one step, over
    /// every take of the sequence (plan 3d decision 17). With a transcript of every take it shows that can be heard, the
    /// silences are between the words that stay; otherwise, where each take's first microphone is quiet (found off the
    /// main thread), joined across takes. How many blocks it added (0 when none fits); `nil` when it could not: the
    /// project cannot be edited, or without the words no take has a microphone or one cannot be read.
    func hideCameraInSilences() async -> Int? {
        guard !closed, !isFindingSilences, let model, model.canEdit, let document = model.document,
              let project = model.exportProject
        else { return nil }
        isFindingSilences = true
        defer { isFindingSilences = false }
        let shown = SequenceAnalyses.takes(shownBy: document, in: project)
        var quiet: [String: [Range<HostTime>]]?
        if !SequenceTranscription.silencesFromWords(document, shown: shown) {
            let microphones = shown.compactMap { take in
                take.tracks.first { $0.kind == .microphone && !$0.segments.isEmpty }.map { (take: take.id, track: $0.id) }
            }
            guard !microphones.isEmpty else { return nil }
            var found: [String: [Range<HostTime>]] = [:]
            do {
                for microphone in microphones {
                    guard let take = project.focused(on: microphone.take) else { continue }
                    let audio = try await TrackAudio.load(take, track: microphone.track, channels: 1)
                    found[microphone.take] = try await SilenceFinder.quietSpans(audio)
                }
            } catch {
                Self.logger.error("Cannot find the silences: \(String(describing: error), privacy: .public)")
                return nil
            }
            quiet = found
        }
        // The document as it is now: edited, or closed, meanwhile.
        guard !closed, model.canEdit, let latest = model.document else { return nil }
        let map = TimeMap(sequence: latest.sequence)
        let silences = quiet.map { VoiceSilences.fromQuiet(ofTakes: $0, timeMap: map) }
            ?? VoiceSilences.fromWords(latest, timeMap: map)
        guard let step = VoiceSilences.hideCamera(latest, silences: silences, timeMap: map, makeID: EditorModel.newID) else {
            return 0
        }
        let before = Set(latest.camera.layouts.map(\.id))
        guard model.perform(step) != .refused else { return nil }
        return Set(model.document?.camera.layouts.map(\.id) ?? []).subtracting(before).count
    }

    // MARK: - The export

    /// What an export does first (`EditorModel.exportPreparations`): for an export with sound, waits for the clean voice
    /// and the loudness its document lacks (`prepareExport(_:onto:progress:)`) and hands them to it, with "Exported
    /// without noise cleanup: …" when this Mac cannot clean. `false`, which stops the export, when it was cancelled
    /// meanwhile (saying nothing) or a job failed (with "Couldn't prepare the audio: …").
    func prepareExport(_ model: EditorModel, _ export: ExportPreparation) async -> Bool {
        guard export.hasSound, !closed, voiceJobs != nil else { return true }
        do {
            let (inputs, notice) = try await prepareExport(export.document, onto: export.analysis) { fraction in
                Task { @MainActor in export.report(fraction) }
            }
            guard !Task.isCancelled, !closed else { return false }
            export.analysis.cleanVoice = inputs.cleanVoice
            export.analysis.loudness = inputs.loudness
            if let notice { export.notice(notice) }
            return true
        } catch {
            // "Cancel Export", or the window closing: the export ends without a word.
            guard !Task.isCancelled, !closed else { return false }
            Self.logger.error("The voice's analysis for the export failed: \(String(describing: error), privacy: .public)")
            showFailure(error, in: model)
            return false
        }
    }

    /// `inputs` with the clean voice and the loudness `document` needs, once every job it needs is done (first in the
    /// queue), reporting their progress from 0 to 1; and the sentence the export says when this Mac cannot clean what
    /// `document` cleans. The other fields of `inputs` as they are.
    /// - Throws: the `JobError` of a job that failed; `CancellationError` if the task is cancelled (the jobs go on).
    func prepareExport(
        _ document: EditDocument, onto inputs: AnalysisInputs, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (AnalysisInputs, notice: String?) {
        guard let voiceJobs, let jobs = model?.jobs else { return (inputs, nil) }
        let (prepared, skipped) = try await voiceJobs.prepareExport(document, onto: inputs, jobs: jobs, progress: progress)
        let notice = skipped
            ? String(
                localized: "Exported without noise cleanup: this Mac doesn't have the system's voice isolation.",
                comment: "Said once an export is done: a project cleaned on another Mac was exported without the cleanup")
            : nil
        return (prepared, notice)
    }

    // MARK: - Private

    /// The engine of the transcriptions: `speechTranscriber-1` from macOS 26, none before.
    private static func engine() -> (any SpeechEngine)? {
        if #available(macOS 26, *) { SpeechTranscriberEngine() } else { nil }
    }

    /// The languages `speechTranscriber-1` transcribes, by name, and whether each is installed (none before macOS 26).
    private nonisolated static func findLanguages() async -> [Language] {
        let supported = await SpeechLanguages.supported()
        let installed = Set(await SpeechLanguages.installed())
        return supported.map { id in
            let name = Locale.current.localizedString(forIdentifier: id) ?? id
            return Language(id: id, name: name.prefix(1).uppercased(with: .current) + name.dropFirst(), installed: installed.contains(id))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    #if DEBUG
    /// What Speech says of `language` inside the app, in the log: `SpeechTranscriber.installedLocales` and
    /// `AssetInventory.status`. On macOS 26.6.2 the Debug app hears it listed by `installedLocales` while
    /// `AssetInventory.status` says `.supported`, as from a process without a bundle (A6): installed is what
    /// `installedLocales` says (`SpeechLanguages.status`).
    private nonisolated static func logModelInventory(_ language: String) async {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))
        else { return }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let inventory = await AssetInventory.status(forModules: [module])
        let identifier = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == identifier }
        logger.notice("Speech in the app for \(identifier, privacy: .public): installedLocales lists it \(installed, privacy: .public), AssetInventory.status \(String(describing: inventory), privacy: .public)")
    }
    #endif

    /// `language` is chosen: remembered, and whether its model is installed found again.
    private func choose(_ language: String) {
        guard !closed, language != chosenLanguage, languages.contains(where: { $0.id == language }) else { return }
        chosenLanguage = language
        var saved = preferences.preferences
        saved.language = language
        preferences.preferences = saved
        refreshStatus()
    }

    /// Finds again whether the model of `language` is installed, unless a download of it is under way.
    private func refreshStatus() {
        guard downloadTask == nil else { return }
        let language = chosenLanguage
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            let status = language.isEmpty ? LanguageModelStatus.unsupported : await SpeechLanguages.status(of: language)
            guard let self, !Task.isCancelled, !self.closed, self.chosenLanguage == language, self.downloadTask == nil else { return }
            self.modelStatus = status
            self.refreshTranscription()
        }
    }

    private func downloaded(_ fraction: Double) {
        guard downloadTask != nil, let progress = downloadProgress, fraction > progress else { return }
        downloadProgress = fraction
    }

    /// What the transcription is now, from the Mac, the takes, the queue, the last failure and the document.
    private func refreshTranscription() {
        let kind = batch.indices.contains(batchIndex) ? batch[batchIndex] : nil
        let next: Transcription
        if !SpeechLanguages.isSupportedOS {
            next = .needsMacOS26
        } else if project != nil, !transcribable, transcriptionTask == nil {
            next = .noAudio
        } else if speechAvailable == false || (speechAvailable == true && languages.isEmpty) {
            next = .unavailable
        } else if let kind, case .running(let progress)? = states[kind] {
            next = .running(progress)
        } else if let kind, states[kind] == .waiting || (transcriptionTask != nil && states[kind] == nil) {
            next = .queued
        } else if transcriptionTask != nil, kind == nil {
            // Finding the takes' jobs.
            next = .queued
        } else if transcriptionTask != nil {
            // Ended, its outcome on its way.
            next = transcription
        } else if let transcriptionFailure {
            next = .failed(transcriptionFailure)
        } else {
            next = document?.transcript == nil ? .idle : .done
        }
        if next != transcription { transcription = next }
        let count = transcriptionTask != nil && batch.count > 1 ? TakeCount(take: batchIndex + 1, of: batch.count) : nil
        if count != transcriptionCount { transcriptionCount = count }
    }

    /// The transcription made `transcript` (the words of the takes it heard): they replace those takes' in the document
    /// in one step, after asking when corrections of those takes would be lost (the others' are kept); dropped if the
    /// project cannot be edited. Returns once it is in the document, or the alert was answered.
    private func transcribed(_ transcript: Transcript) async {
        guard let model, model.canEdit, let document = model.document else {
            Self.logger.notice("A transcription was dropped: the project can't be edited")
            return
        }
        let heard = Set(transcript.takes.map(\.take))
        let lost = document.transcript.map { TranscriptCommands.lostCorrections($0, transcript, inTakes: heard) } ?? 0
        guard lost > 0 else { return create(transcript) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Transcribing again replaces \(lost) corrected words.",
            comment: "An alert before a new transcription replaces one whose words were corrected")
        alert.addButton(withTitle: String(localized: "Replace", comment: "The alert before a new transcription replaces the corrected one"))
        alert.addButton(withTitle: String(localized: "Keep the Current One", comment: "The alert before a new transcription replaces the corrected one"))
        let response: NSApplication.ModalResponse
        if let window = model.window, window.isVisible {
            response = await withCheckedContinuation { answered in
                alert.beginSheetModal(for: window) { answered.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return }
        create(transcript)
    }

    /// The words of `transcript` in the document as it is now, if it can be edited: `transcript.create` of it whole when
    /// it has every take of the transcript there (with one take, the phase 2's step), otherwise those takes merged in
    /// (`TranscriptCommands.mergeTakes`), the others as they are.
    private func create(_ transcript: Transcript) {
        guard !closed, let model, model.canEdit, let document = model.document else { return }
        let heard = Set(transcript.takes.map(\.take))
        let whole = document.transcript.map { $0.takes.allSatisfy { heard.contains($0.take) } } ?? true
        guard let step = whole ? TranscriptCommands.create(document, transcript) : TranscriptCommands.mergeTakes(document, transcript)
        else { return }
        model.perform(step)
    }

    /// Follows the jobs' states (`ProjectJobs.updates()`), once.
    private func listen() {
        guard updatesTask == nil, let jobs = model?.jobs else { return }
        updatesTask = Task { [weak self] in
            for await all in await jobs.updates() {
                guard let self else { return }
                self.jobsChanged(all)
            }
        }
    }

    /// The queue's states are `all`: the voice's are kept, the progress shown, and a cleanup or loudness job that is now
    /// done has the caches read again (and, once none waits or runs, what is still needed asked for).
    private func jobsChanged(_ all: [AnalysisJobKind: JobState]) {
        guard !closed else { return }
        let voice = all.filter { Self.isVoice($0.key) }
        guard voice != states else { return }
        let finished = voice.contains { kind, state in
            state == .done && states[kind] != .done && !Self.isTranscription(kind)
        }
        states = voice
        showProgress()
        refreshTranscription()
        guard finished, let document else { return }
        read(document)
        if !states.contains(where: { !Self.isTranscription($0.key) && Self.isPending($0.value) }) { enqueue(document) }
    }

    /// The progress of the cleanups and of the loudness waiting or running, each over the jobs of its batch.
    private func showProgress() {
        for (kind, state) in states where Self.isPending(state) {
            switch kind {
            case let .soundIsolation(take, track, _): cleanupBatches[AudioPlan.key(take: take, track: track), default: []].insert(kind)
            case .loudness: loudnessBatch.insert(kind)
            case .transcription, .personMask, .faceTrack, .sensitiveScan: break
            }
        }
        var cleanup: [String: Double] = [:]
        for (key, batch) in cleanupBatches {
            if batch.contains(where: { states[$0].map(Self.isPending) ?? false }) {
                cleanup[key] = average(batch)
            } else {
                cleanupBatches[key] = nil
            }
        }
        if cleanup != cleanupProgress { cleanupProgress = cleanup }
        var loudness: Double?
        if loudnessBatch.contains(where: { states[$0].map(Self.isPending) ?? false }) {
            loudness = average(loudnessBatch)
        } else {
            loudnessBatch = []
        }
        if loudness != loudnessProgress { loudnessProgress = loudness }
    }

    /// How far the jobs `batch` are together: each one over counts whole, one running by its progress, one waiting as
    /// nothing.
    private func average(_ batch: Set<AnalysisJobKind>) -> Double {
        guard !batch.isEmpty else { return 0 }
        let done = batch.reduce(0.0) { sum, kind in
            switch states[kind] {
            case .done?, .failed?, .unavailable?: sum + 1
            case .running(let progress)?: sum + min(max(progress, 0), 1)
            case .waiting?, nil: sum
            }
        }
        return done / Double(batch.count)
    }

    /// `document` is the latest: when its needs change, what it needs is asked for and the caches are read for it; when
    /// the takes its sequence shows change, whether it has something to transcribe is found again and a take new in it
    /// is transcribed by itself if it is to be (`transcribeNewTakes`).
    private func follow(_ document: EditDocument) {
        guard let project else { return }
        let next = Needs(document, project: project)
        guard next != needs else { return }
        let takesChanged = next.takes != needs?.takes
        needs = next
        enqueue(document)
        read(document)
        guard takesChanged else { return }
        transcribable = !SequenceTranscription.transcribable(SequenceAnalyses.takes(shownBy: document, in: project)).isEmpty
        refreshTranscription()
        transcribeNewTakes()
    }

    /// Enqueues, off the main thread and after what was enqueued before, the jobs `document` needs that the queue has no
    /// state for, and those done that are needed again (their cache went missing, or a loudness measured before the
    /// cleaning it is now of) once each.
    private func enqueue(_ document: EditDocument) {
        guard let voiceJobs, let jobs = model?.jobs else { return }
        let previous = enqueueTask
        previous?.cancel()
        enqueueTask = Task { [weak self] in
            await previous?.value
            let kinds = await Task.detached(priority: .utility) { voiceJobs.needed(for: document) }.value
            guard let self, !Task.isCancelled, !self.closed else { return }
            self.askedAgain.formIntersection(kinds)
            for kind in kinds {
                let state = await jobs.state(of: kind)
                // Closed, or followed by another document, while it asked.
                guard !Task.isCancelled, !self.closed else { return }
                if state == .done {
                    guard !self.askedAgain.contains(kind) else { continue }
                    self.askedAgain.insert(kind)
                } else if state != nil {
                    continue
                }
                guard let work = voiceJobs.work(for: kind) else { continue }
                await jobs.enqueue(kind, work: work)
            }
        }
    }

    /// Reads what the caches hold for `document`, off the main thread, and hands it to the preview's mix unless a newer
    /// reading started meanwhile.
    private func read(_ document: EditDocument) {
        guard let voiceJobs, let model else { return }
        reading += 1
        let current = reading
        let inputs = model.analysis
        readTask?.cancel()
        readTask = Task { [weak self] in
            let read = await Task.detached(priority: .utility) { voiceJobs.applied(to: inputs, document: document) }.value
            guard let self, !self.closed, current == self.reading else { return }
            self.model?.updateAnalysis { analysis in
                analysis.cleanVoice = read.cleanVoice
                analysis.loudness = read.loudness
            }
        }
    }

    /// "Couldn't prepare the audio: …" for `error`, over the editor's window.
    private func showFailure(_ error: any Error, in model: EditorModel) {
        let reason =
            switch error {
            case let error as JobError: Self.reason(of: error.problem)
            default: String(localized: "an unexpected error occurred")
            }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(
                localized: "Couldn't prepare the audio: %@",
                comment: "An alert: an export stopped because the cleanup or the loudness of its sound failed, and why"),
            reason)
        if let window = model.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The sentence of a transcription that failed for `problem`.
    private static func failure(_ problem: JobProblem) -> String {
        String(
            format: String(localized: "Couldn't transcribe: %@", comment: "The Captions tab: the transcription failed, and why"),
            reason(of: problem))
    }

    /// Why the voice's analysis failed, after "Couldn't transcribe:" or "Couldn't prepare the audio:".
    private static func reason(of problem: JobProblem) -> String {
        switch problem {
        case .noSpace:
            // The library's words for it.
            String(localized: "the disk is full")
        case .needsMacOS26, .notOnThisMac, .modelNotInstalled:
            String(localized: "this Mac can't analyze its sound", comment: "Why the voice's analysis failed, after “Couldn't transcribe:” or “Couldn't prepare the audio:”")
        case .sourceUnreadable:
            String(localized: "its audio can't be read", comment: "Why the voice's analysis failed, after “Couldn't transcribe:” or “Couldn't prepare the audio:”")
        default:
            String(localized: "its sound couldn't be analyzed", comment: "Why the voice's analysis failed, after “Couldn't transcribe:” or “Couldn't prepare the audio:”")
        }
    }

    private static func isPending(_ state: JobState) -> Bool {
        switch state {
        case .waiting, .running: true
        case .done, .failed, .unavailable: false
        }
    }

    private nonisolated static func isVoice(_ kind: AnalysisJobKind) -> Bool {
        switch kind {
        case .transcription, .soundIsolation, .loudness: true
        case .personMask, .faceTrack, .sensitiveScan: false
        }
    }

    private nonisolated static func isTranscription(_ kind: AnalysisJobKind) -> Bool {
        if case .transcription = kind { true } else { false }
    }
}
