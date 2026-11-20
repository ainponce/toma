// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Editing
import Observation
import ProjectFormat
import ProjectJobs
import os

/// The camera's analysis in the editor (phase 2 design §6.1, §6.2 and §10; plan 2b decision 16): the person's masks and
/// the faces the document asks for, through the base's seam (`EditorModel.jobs`, `updateAnalysis(_:)`,
/// `exportPreparations`).
///
/// - **Asked for.** With each document whose needs change (the camera shown, a background that is not Original, Follow
///   the Face, the takes its sequence shows) it enqueues `CameraAnalysis.neededJobs` of each take the sequence shows
///   that the queue has no state for, off the main thread: a job that is done, failed or unavailable is not run again
///   for an edit (the export asks again for what it lacks). A take new in the sequence puts its jobs in the queue
///   (phase 3 design §8.1).
/// - **Shown.** The jobs' states arrive by `ProjectJobs.updates()`, never by waiting on a job; each camera job that is
///   done, and each change of the needs, has `CameraAnalysis.fill` read the caches off the main thread and hands the
///   masks and the faces to the preview with `updateAnalysis` (the latest read wins; an older one that ends late is
///   dropped). A mask or a face done whose cache file is gone (macOS emptied the caches) is asked for again, once until
///   it is seen again.
/// - **The export.** `prepareExport` waits for what the document lacks (`CameraAnalysis.prepareForExport`, which leaves
///   out what this Mac cannot do and the segments that cannot be read, as the preview does) and hands it over before
///   the exporter starts; a job that fails, or is cancelled while the export is not, stops the export with "Couldn't
///   prepare the camera: …".
@MainActor @Observable
final class EditorImage {
    /// The camera's two analyses, as the Camera tab shows them.
    enum CameraJob {
        /// The person's masks (`personMask-1`): a background Blurred or Removed.
        case masks
        /// The faces (`faceTrack-1`): Follow the Face.
        case faces
    }

    /// What a document needs of the camera's analysis: what `CameraAnalysis.neededJobs` and `fill` read of it.
    private struct Needs: Equatable {
        var masks: Bool
        var faces: Bool
        /// The takes the sequence shows, in its order (`SequenceAnalyses.takes(shownBy:in:)`).
        var takes: [String]

        init(_ document: EditDocument, project: LoadedProject) {
            masks = document.camera.show && document.camera.background != .original
            faces = document.camera.show && document.camera.framing.mode == .face
            takes = SequenceAnalyses.takes(shownBy: document, in: project).map(\.id)
        }
    }

    /// The camera jobs of a take's segments that can be analysed, in the order `neededJobs` gives them; found off the
    /// main thread when the project opens.
    private struct Possible: Equatable {
        var masks: [AnalysisJobKind] = []
        var faces: [AnalysisJobKind] = []
    }

    /// The states of the takes' camera jobs, as `ProjectJobs.updates()` last said.
    private(set) var states: [AnalysisJobKind: JobState] = [:]
    /// Every camera job a document could need of each take of the package, by its id; empty until it is found.
    private var possible: [String: Possible] = [:]

    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private var project: LoadedProject?
    @ObservationIgnored private var caches: ProjectCaches?
    /// The session's document, as last told.
    @ObservationIgnored private var document: EditDocument?
    /// The needs the jobs were asked for and the analysis was read with; `nil` until `possible` is found.
    @ObservationIgnored private var needs: Needs?
    /// Counts the openings, so what an earlier one finds is dropped.
    @ObservationIgnored private var opening = 0
    /// Counts the readings of the caches, so only the latest is handed over.
    @ObservationIgnored private var reading = 0
    /// The jobs done whose cache file was found missing and that were asked for again, until a reading sees it.
    @ObservationIgnored private var askedAgain: Set<AnalysisJobKind> = []
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var enqueueTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?

    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "EditorImage")

    /// The camera's analysis of `model`'s project, which it holds weakly.
    init(model: EditorModel) {
        self.model = model
    }

    // MARK: - What the editor tells it

    /// The session opened `project` (its take, and the package's others), with its analysis caches `caches` and
    /// `document`: what was there before is forgotten, the jobs' states are followed, and what `document` needs is asked
    /// for and read once the takes' segments are found (off the main thread).
    func opened(project: LoadedProject, caches: ProjectCaches, document: EditDocument) {
        guard !closed else { return }
        self.project = project
        self.caches = caches
        self.document = document
        needs = nil
        possible = [:]
        askedAgain = []
        listen()
        opening += 1
        let current = opening
        openTask?.cancel()
        openTask = Task { [weak self] in
            let possible = await Task.detached(priority: .utility) {
                var possible: [String: Possible] = [:]
                for take in project.takes {
                    possible[take.id] = Self.possibleJobs(take: take, package: project.package, document: document)
                }
                return possible
            }.value
            guard let self, !self.closed, current == self.opening else { return }
            self.possible = possible
            if let document = self.document { self.follow(document) }
        }
    }

    /// The session's document changed: what it needs is asked for and read, if that changed.
    func documentChanged(_ document: EditDocument) {
        guard !closed, project != nil else { return }
        self.document = document
        // Until the takes' segments are found, the opening follows the latest document.
        guard needs != nil else { return }
        follow(document)
    }

    /// How far the camera's `kind` analysis that `document` needs is, 0 to 1 (`CameraAnalysis.progress`: a job done,
    /// failed or unavailable counts whole); `nil` when `document` needs none.
    func cameraProgress(_ document: EditDocument, _ kind: CameraJob) -> Double? {
        guard let project else { return nil }
        return CameraAnalysis.progress(
            states, of: kinds(document, kind), takes: SequenceAnalyses.takes(shownBy: document, in: project))
    }

    /// Why a job of the camera's `kind` analysis that `document` needs made nothing (the first that failed or is
    /// unavailable, take by take in the segments' order); `nil` while none did.
    func problem(_ document: EditDocument, _ kind: CameraJob) -> JobProblem? {
        for job in kinds(document, kind) {
            switch states[job] {
            case .failed(let problem)?, .unavailable(let problem)?: return problem
            case .waiting?, .running?, .done?, nil: continue
            }
        }
        return nil
    }

    /// What an export does first (`EditorModel.exportPreparations`): waits for the masks and the faces the exported
    /// document lacks, first in the queue (`CameraAnalysis.prepareForExport`), reporting how far the jobs that were not
    /// done yet are (`CameraAnalysis.progress`), and hands them to the export and the preview (`updateAnalysis`).
    /// `false`, which stops the export, when the export was cancelled meanwhile (saying nothing) or a job failed or was
    /// cancelled (with "Couldn't prepare the camera: …").
    func prepareExport(_ model: EditorModel, _ export: ExportPreparation) async -> Bool {
        guard !closed, let caches else { return true }
        let document = export.document, project = export.project
        var inputs = export.analysis
        let pending = (kinds(document, .faces) + kinds(document, .masks)).filter { states[$0] != .done }
        let takes = SequenceAnalyses.takes(shownBy: document, in: project)
        let watcher = pending.isEmpty ? nil : Task { [jobs = model.jobs] in
            for await all in await jobs.updates() {
                if let fraction = CameraAnalysis.progress(all, of: pending, takes: takes) { export.report(fraction) }
            }
        }
        defer { watcher?.cancel() }
        do {
            try await CameraAnalysis.prepareForExport(
                &inputs, document: document, project: project, caches: caches, jobs: model.jobs)
        } catch {
            // "Cancel Export", or the window closing: the export ends without a word.
            guard !Task.isCancelled, !closed else { return false }
            Self.logger.error("The camera's analysis for the export failed: \(String(describing: error), privacy: .public)")
            showFailure(error, in: model)
            return false
        }
        guard !Task.isCancelled, !closed else { return false }
        export.analysis.personMasks = inputs.personMasks
        export.analysis.faceTracks = inputs.faceTracks
        if Needs(document, project: project) == needs {
            // What the export waited for is newer than any reading under way.
            reading += 1
            readTask?.cancel()
            hand(inputs)
        } else {
            // Edited since the export took its copy: the preview reads what its own document needs.
            read()
        }
        return true
    }

    /// The editor closed: nothing more is asked for, read or handed over (the editor cancels the jobs).
    func close() {
        guard !closed else { return }
        closed = true
        for task in [updatesTask, openTask, enqueueTask, readTask] { task?.cancel() }
        updatesTask = nil
        openTask = nil
        enqueueTask = nil
        readTask = nil
        project = nil
        caches = nil
        document = nil
    }

    // MARK: - Words

    /// Why the camera could not be prepared, after "Couldn't prepare the camera:".
    static func reason(of problem: JobProblem) -> String {
        switch problem {
        case .noSpace:
            // The library's words for it.
            String(localized: "the disk is full")
        case .notOnThisMac:
            String(localized: "this Mac can't analyze its image", comment: "Why the camera couldn't be prepared, after “Couldn't prepare the camera:”")
        case .sourceUnreadable:
            String(localized: "one of its files can't be read", comment: "Why the camera couldn't be prepared, after “Couldn't prepare the camera:”")
        case .failed:
            String(localized: "its image couldn't be analyzed", comment: "Why the camera couldn't be prepared, after “Couldn't prepare the camera:”")
        default:
            String(localized: "an unexpected error occurred")
        }
    }

    // MARK: - Private

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

    /// The queue's states are `all`: the camera's are kept, and a job of it that is now done has the caches read again.
    private func jobsChanged(_ all: [AnalysisJobKind: JobState]) {
        guard !closed else { return }
        let camera = all.filter { Self.isCamera($0.key) }
        guard camera != states else { return }
        let finished = camera.contains { kind, state in state == .done && states[kind] != .done }
        states = camera
        if finished, needs != nil { read() }
    }

    /// `document` is the latest: when its needs change, what it needs is asked for and the caches are read for it.
    private func follow(_ document: EditDocument) {
        guard let project else { return }
        let next = Needs(document, project: project)
        guard next != needs else { return }
        needs = next
        enqueue(document)
        read()
    }

    /// Enqueues, off the main thread and after what was enqueued before, the jobs `document` needs of each take its
    /// sequence shows that the queue has no state for.
    private func enqueue(_ document: EditDocument) {
        guard let jobs = model?.jobs, let project, let caches else { return }
        let previous = enqueueTask
        previous?.cancel()
        enqueueTask = Task.detached(priority: .utility) {
            await previous?.value
            let takes = SequenceAnalyses.takes(shownBy: document, in: project)
            for kind in CameraAnalysis.neededJobs(document: document, takes: takes, package: project.package) {
                guard !Task.isCancelled else { return }
                guard await jobs.state(of: kind) == nil, let focused = Self.project(project, of: kind),
                    let work = CameraAnalysis.work(for: kind, project: focused, caches: caches)
                else { continue }
                // Closed (or followed by another document) while it asked.
                guard !Task.isCancelled else { return }
                await jobs.enqueue(kind, work: work)
            }
        }
    }

    /// Reads what the caches hold for the latest document, off the main thread, and hands it over unless a newer reading
    /// started meanwhile.
    private func read() {
        guard let project, let caches, let document else { return }
        reading += 1
        let current = reading
        readTask?.cancel()
        readTask = Task { [weak self] in
            let inputs = await Task.detached(priority: .utility) {
                var inputs = AnalysisInputs()
                CameraAnalysis.fill(
                    &inputs, document: document, takes: SequenceAnalyses.takes(shownBy: document, in: project),
                    package: project.package, caches: caches)
                return inputs
            }.value
            guard let self, !self.closed, current == self.reading else { return }
            self.hand(inputs)
            self.askAgainForMissing(inputs, document: document)
        }
    }

    /// Hands `inputs`' masks and faces to the preview and the export, and to the export sheet's GIF preview.
    private func hand(_ inputs: AnalysisInputs) {
        guard let model else { return }
        model.updateAnalysis { analysis in
            analysis.personMasks = inputs.personMasks
            analysis.faceTracks = inputs.faceTracks
        }
        model.exportSheetAnalysisChanged()
    }

    /// The jobs `document` needs that are done but whose cache `inputs` lacks (macOS emptied the caches) are enqueued
    /// again: once, until a reading finds them.
    private func askAgainForMissing(_ inputs: AnalysisInputs, document: EditDocument) {
        guard let jobs = model?.jobs, let project, let caches else { return }
        var missing: [(AnalysisJobKind, JobWork)] = []
        for kind in kinds(document, .faces) + kinds(document, .masks) {
            let found: Bool
            switch kind {
            case let .personMask(take, track, segment):
                found = inputs.personMasks[CameraSegment(take: take, track: track, segment: segment)] != nil
            case let .faceTrack(take, track, segment):
                found = inputs.faceTracks[CameraSegment(take: take, track: track, segment: segment)] != nil
            case .transcription, .soundIsolation, .loudness, .sensitiveScan:
                continue
            }
            if found {
                askedAgain.remove(kind)
            } else if states[kind] == .done, !askedAgain.contains(kind), let focused = Self.project(project, of: kind),
                let work = CameraAnalysis.work(for: kind, project: focused, caches: caches) {
                askedAgain.insert(kind)
                missing.append((kind, work))
            }
        }
        guard !missing.isEmpty else { return }
        Task {
            for (kind, work) in missing { await jobs.enqueue(kind, work: work) }
        }
    }

    /// The jobs of the camera's `kind` analysis `document` needs, as `CameraAnalysis.neededJobs` gives them: take by
    /// take, in the order its sequence first shows each.
    private func kinds(_ document: EditDocument, _ kind: CameraJob) -> [AnalysisJobKind] {
        guard let project else { return [] }
        let needs = Needs(document, project: project)
        return needs.takes.flatMap { take -> [AnalysisJobKind] in
            switch kind {
            case .masks: needs.masks ? possible[take]?.masks ?? [] : []
            case .faces: needs.faces ? possible[take]?.faces ?? [] : []
            }
        }
    }

    /// `project` focused on the take of the camera job `kind` (`LoadedProject.focused(on:)`), whose work is that take's;
    /// `nil` for a take the manifest does not have and any other job.
    private nonisolated static func project(_ project: LoadedProject, of kind: AnalysisJobKind) -> LoadedProject? {
        switch kind {
        case let .personMask(take, _, _), let .faceTrack(take, _, _): project.focused(on: take)
        case .transcription, .soundIsolation, .loudness, .sensitiveScan: nil
        }
    }

    /// "Couldn't prepare the camera: …" for `error`, over the editor's window.
    private func showFailure(_ error: any Error, in model: EditorModel) {
        let reason =
            switch error {
            case let error as JobError: Self.reason(of: error.problem)
            case is CancellationError:
                String(localized: "its analysis was canceled", comment: "Why the camera couldn't be prepared, after “Couldn't prepare the camera:”")
            default: String(localized: "an unexpected error occurred")
            }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(
                localized: "Couldn't prepare the camera: %@",
                comment: "An alert: an export stopped because the camera's analysis (its background or its face) failed, and why"),
            reason)
        if let window = model.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Every camera job a document of `take` could need: those `neededJobs` gives with the camera shown, a background
    /// and Follow the Face. Reads each segment's `lstat`: never on the main thread.
    private nonisolated static func possibleJobs(take: TakeRecord, package: ProjectPackage, document: EditDocument) -> Possible {
        var all = document
        all.camera.show = true
        all.camera.background = .blurred
        all.camera.framing.mode = .face
        var possible = Possible()
        for kind in CameraAnalysis.neededJobs(document: all, take: take, package: package) {
            switch kind {
            case .personMask: possible.masks.append(kind)
            case .faceTrack: possible.faces.append(kind)
            case .transcription, .soundIsolation, .loudness, .sensitiveScan: break
            }
        }
        return possible
    }

    private nonisolated static func isCamera(_ kind: AnalysisJobKind) -> Bool {
        switch kind {
        case .personMask, .faceTrack: true
        case .transcription, .soundIsolation, .loudness, .sensitiveScan: false
        }
    }
}
