// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Darwin
import Editing
import Foundation
import ProjectFormat

/// A Toma project opened without the app (fases 4 y 5 design §6.2): read in output time, edited with the app's own
/// commands (`CommandSteps`), undone and redone through its edit log.
///
/// - `.read` never writes (plan 4b, Global Constraints): no `edit.lock`, no `NewDocument` for a project without edits, no
///   repair of a damaged log; the document is the one on disk, as `EditSession.readDocumentWithDiskVersion` reads it.
/// - `.edit` reads the document as `.read` does and asks whether another process holds `edit.lock` (`locked`), without
///   taking it. The `EditSession`, with the lock, opens with the first command that changes the document, or the first
///   undo or redo the log has: a command that fails or changes nothing writes nothing, not even the first document of
///   a project never opened in the editor, and a project of version 1 to 4 stays as it is until a command changes it,
///   which the session writes with its `migrate` (and, for version 1 or 2, the package's upgrade to 3). Each command is
///   one `perform`, its own undo (never joined to the one before it, as a burst of keys is in the editor), waited for
///   on the disk (`flushed`) before it returns: what `apply` says was done is in the log.
///
/// Everything it throws is an `APIError`. What reads the disk (the takes' events) runs off the main actor.
@MainActor public final class TomaProject {
    public enum Mode: String, Codable, Sendable { case read, edit }

    public let url: URL
    public let mode: Mode
    public let environment: APIEnvironment

    private enum Storage {
        case read(LoadedProject, EditDocument)
        /// `.edit` before its session opens: the document on disk, as `.read` reads it.
        case editing(LoadedProject, EditDocument)
        case edit(EditSession)
    }

    /// What the log on disk can undo and redo as the project opened, before its session opens.
    private struct DiskHistory: Sendable {
        var undo: EditLabel?
        var redo: EditLabel?
    }

    private var storage: Storage
    /// The takes the manifest says are being recorded (`TakeStatus.recording`) as the project opened.
    let recordingTakes: [String]
    /// What reading the project found beyond its document (`EditSession.readDocumentWithFindings`).
    let findings: ReadFindings
    /// What the opening of the session did that the next result tells: an `edit.json` or a log set aside.
    private var openingWarnings: [String] = []
    /// The `documentVersion` of the edit document on disk as the project opened; `nil` without one.
    private let openedDocumentVersion: Int?
    private let diskHistory: DiskHistory
    /// The session being opened, which every call waiting for it shares.
    private var opening: Task<EditSession, any Error>?
    private var recorded: MarkerList.Recorded?
    /// Whether `close()` was called: nothing is done after it (the export checks it too).
    private(set) var closed = false

    private init(
        url: URL, mode: Mode, environment: APIEnvironment, storage: Storage, openedDocumentVersion: Int?, diskHistory: DiskHistory,
        recordingTakes: [String], findings: ReadFindings
    ) {
        self.url = url
        self.mode = mode
        self.environment = environment
        self.storage = storage
        self.recordingTakes = recordingTakes
        self.findings = findings
        self.openedDocumentVersion = openedDocumentVersion
        self.diskHistory = diskHistory
    }

    /// Opens the package at `url` (a folder `.toma`, checked as `ProjectPaths` does) for reading or editing.
    ///
    /// A take the manifest says is being recorded (`TakeStatus.recording`: the recorder is writing it, or a crash left it
    /// so, until the user recovers it in Toma) is only read: editing it is `locked`, as exporting it is, since
    /// the first document of its project would hold only what was recorded so far (the library does not open it either).
    public static func open(_ url: URL, mode: Mode, environment: APIEnvironment = .standard) async throws -> TomaProject {
        try ProjectPaths.checkPackage(url)
        let context = environment.editContext
        let read = await Task.detached {
            () -> Result<(LoadedProject, EditDocument, Int?, ReadFindings, DiskHistory, Bool), any Error> in
            Result {
                let (project, document, diskVersion, findings) = try EditSession.readDocumentWithFindings(
                    url, take: nil, context: context)
                let editing = mode == .edit
                return (
                    project, document, Self.hasEditFiles(project) ? diskVersion : nil, findings,
                    editing ? Self.diskHistory(of: project) : DiskHistory(),
                    // Asked about, never taken nor made (`RecordingLock.isHeld`), as `EditSession` asks about it.
                    editing && RecordingLock.isHeld(at: project.package.editLockURL))
            }
        }.value
        switch read {
        case let .success((project, document, version, findings, history, locked)):
            let recording = project.takes.filter { $0.status == .recording }.map(\.id)
            if mode == .edit, !recording.isEmpty { throw beingRecorded(recording) }
            if locked { throw apiError(ReadOnlyReason.openElsewhere) }
            // What the editor opens read-only, the API does not edit either: said with what it found.
            if mode == .edit, let refusal = findings.refusal {
                let found = Self.documentWarnings(findings)
                throw APIError(
                    .refused, apiError(refusal).message + (found.isEmpty ? "" : ": " + found.joined(separator: "; ")))
            }
            return TomaProject(
                url: url, mode: mode, environment: environment,
                storage: mode == .read ? .read(project, document) : .editing(project, document), openedDocumentVersion: version,
                diskHistory: history, recordingTakes: recording, findings: findings)
        case let .failure(error):
            throw apiError(error)
        }
    }

    /// In `.read`, the document on disk as `EditSession.readDocument` gives it; in `.edit`, the session's.
    public var document: EditDocument {
        switch storage {
        case let .read(_, document), let .editing(_, document): document
        case let .edit(session): session.document
        }
    }

    public var project: LoadedProject {
        switch storage {
        case let .read(project, _), let .editing(project, _): project
        case let .edit(session): session.project
        }
    }

    /// The markers the output shows, with their output time (`MarkerList.visible`, `VisibleMarker.output` in ns), in
    /// output order.
    public var markers: [VisibleMarker] {
        get async {
            let document = self.document
            let recorded = await recordedMarkers()
            return MarkerList.visible(document: document, recorded: recorded, timeMap: TimeMap(sequence: document.sequence))
        }
    }

    /// The `documentVersion` the edit document is written in on disk; `nil` without one.
    public var documentVersion: Int? {
        if case let .edit(session) = storage { return session.diskDocumentVersion }
        return openedDocumentVersion
    }

    /// What the project is in that its document does not say, a sentence each (`ProjectReport.warnings`): a take being
    /// recorded, and what the editor would open read-only for, set aside or rewrite (`documentWarnings`).
    var warnings: [String] {
        (recordingTakes.isEmpty ? [] : [Self.beingRecorded(recordingTakes).message]) + Self.documentWarnings(findings)
    }

    /// What `findings` say of the document on disk as it is read, shown and exported, a sentence each.
    nonisolated static func documentWarnings(_ findings: ReadFindings) -> [String] {
        var warnings: [String] = []
        if !findings.problems.isEmpty {
            warnings.append(
                "the document breaks Toma's rules, so it is read, shown and exported without what breaks them and Toma opens it "
                    + "read-only: " + findings.problems.map(\.sentence).joined(separator: "; "))
        }
        if findings.undrawableValues {
            warnings.append(
                "the document has a frame rate or a clip speed Toma cannot draw: it is read, shown and exported with the nearest "
                    + "one, and Toma opens it read-only")
        }
        if findings.keepsSnapshotApart {
            warnings.append(
                "edit.json cannot be read: the project is read and exported without its edits, and its first edit sets edit.json "
                    + "aside (edit.json.damaged-…) and starts again from the recording")
        }
        if findings.rewritesLog {
            let upTo = findings.recoveredUpTo.map { " up to " + $0.formatted(.iso8601) } ?? ""
            warnings.append(
                "edit-log.jsonl is damaged or does not match its document: the project is read and exported as it was edited\(upTo), "
                    + "and its first edit sets the log aside and rewrites it up to there")
        }
        return warnings
    }

    /// `locked` for a project whose takes `takes` are being recorded.
    nonisolated static func beingRecorded(_ takes: [String]) -> APIError {
        let names = takes.joined(separator: ", ")
        return APIError(
            .locked,
            "\(names) \(takes.count == 1 ? "is" : "are") being recorded, or a crash left \(takes.count == 1 ? "it" : "them") "
                + "recording (open the project in Toma and choose Recover): what is on disk is only what was recorded so far; "
                + "edit or export it once the recording ends or the take is recovered")
    }

    // MARK: - Reading

    public func report() async -> ProjectReport {
        let project = self.project, document = self.document
        let takes = await Task.detached { Reports.takes(of: project, document: document) }.value
        let recorded = await recordedMarkers()
        let map = TimeMap(sequence: document.sequence)
        let visible = MarkerList.visible(document: document, recorded: recorded, timeMap: map)
        let chapters = Reports.chapters(visible, document: document)
        return ProjectReport(
            path: url.path, name: url.deletingPathExtension().lastPathComponent, mode: mode,
            formatVersion: project.manifest.formatVersion, documentVersion: documentVersion, info: document.info,
            duration: map.durationSeconds, frameRate: document.frameRate, aspect: document.aspect.rawValue, takes: takes,
            sequence: Reports.sequence(document, map: map), markers: Reports.markers(visible),
            chapters: chapters.map { ChapterReport(start: Reports.seconds($0.start), title: $0.title) },
            zoom: Reports.zoom(document, map: map),
            style: StyleReport(style: (try? JSONValue(encoding: document.style)) ?? .null, cameraLayout: document.camera.layout.kind.rawValue),
            music: Reports.music(document), transcript: Reports.transcriptSummary(document),
            warnings: warnings.isEmpty ? nil : warnings)
    }

    /// The transcript, every word with where the output says it; `nil` without one.
    public func transcriptReport() -> TranscriptReport? {
        Reports.transcript(document)
    }

    public func markersReport() async -> MarkersReport {
        let document = self.document
        let recorded = await recordedMarkers()
        let visible = MarkerList.visible(document: document, recorded: recorded, timeMap: TimeMap(sequence: document.sequence))
        return Reports.markersReport(visible, document: document)
    }

    // MARK: - Editing

    /// Applies `command` as one step (`CommandSteps`), and waits for the disk. A setter given the value the project has
    /// changes nothing: `changed` is false.
    public func apply(_ command: ProjectCommand) async throws -> CommandResult {
        try checkCanEdit()
        if case let .transcribe(language, replace) = command {
            return try await runTranscription(language: language, replace: replace)
        }
        // Before the session opens, which may write: a command that fails or changes nothing never opens it.
        if case let .editing(project, document) = storage, try await !changes(command, project: project, document: document) {
            return result(command.name, changed: false, label: nil, created: nil)
        }
        let session = try await editableSession()
        while true {
            let revision = session.revision
            let (scope, step) = await Self.step(
                for: command, project: session.project, document: session.document, makeID: environment.makeID)
            // Another call changed the document while its takes were read: from the document as it is now.
            guard session.revision == revision else { continue }
            switch try step.get() {
            case .unchanged:
                return result(command.name, changed: false, label: nil, created: nil)
            case let .step(step, created):
                return try await perform(step, command: command.name, created: created, in: session)
            case .needsSession:
                return try await applyThroughSession(command, scope: scope, in: session)
            }
        }
    }

    /// `commands` in order, stopping at the first that fails (plan 4b decision 6): what was done before it stays, each
    /// command its own step.
    public func apply(_ commands: [ProjectCommand]) async -> BatchResult {
        var results: [CommandResult] = []
        for (k, command) in commands.enumerated() {
            do {
                results.append(try await apply(command))
            } catch {
                return BatchResult(results: results, error: Self.apiError(error), failedIndex: k)
            }
        }
        return BatchResult(results: results, error: nil, failedIndex: nil)
    }

    /// Undoes the last step, from the edit log: also one an earlier process made.
    public func undo() async throws -> CommandResult {
        try checkCanEdit()
        if case .editing = storage, diskHistory.undo == nil { throw APIError(.refused, "there is nothing to undo") }
        let session = try await editableSession()
        guard session.canUndo, let label = session.undoLabel else { throw APIError(.refused, "there is nothing to undo") }
        let reopened = session.reopenings
        guard session.undo() != .refused else {
            try checkEditable(session)
            throw APIError(.refused, "there is nothing to undo")
        }
        try await settle(session, reopened: reopened)
        return result("undo", changed: true, label: label.rawValue, created: nil)
    }

    public func redo() async throws -> CommandResult {
        try checkCanEdit()
        if case .editing = storage, diskHistory.redo == nil { throw APIError(.refused, "there is nothing to redo") }
        let session = try await editableSession()
        guard session.canRedo, let label = session.redoLabel else { throw APIError(.refused, "there is nothing to redo") }
        let reopened = session.reopenings
        guard session.redo() != .refused else {
            try checkEditable(session)
            throw APIError(.refused, "there is nothing to redo")
        }
        try await settle(session, reopened: reopened)
        return result("redo", changed: true, label: label.rawValue, created: nil)
    }

    /// Releases the project: in `.edit`, the session (if a command opened it) writes its snapshot and lets go of
    /// `edit.lock`. Nothing after it.
    public func close() async {
        guard !closed else { return }
        closed = true
        if let opening { _ = try? await opening.value }
        if case let .edit(session) = storage { await session.close() }
    }

    // MARK: - The session

    /// The edit session, opened now if no command opened it yet (it takes `edit.lock`, and may write as it opens: a new
    /// project's first document, the repair of a damaged log): `locked` if another process has the lock, `refused` if
    /// the project is closed or open for reading. Every command its own undo (`joinsBursts` off). What changes the
    /// document asks for it, and only then (`transcribe` too, once it has a transcript to apply).
    func editableSession() async throws -> EditSession {
        try checkCanEdit()
        if case let .edit(session) = storage {
            try checkEditable(session)
            return session
        }
        let url = url, environment = environment
        let task = opening ?? Task { try await Self.openSession(url, environment: environment) }
        opening = task
        let session: EditSession
        do {
            session = try await task.value
        } catch {
            opening = nil
            throw Self.apiError(error)
        }
        opening = nil
        if case let .edit(opened) = storage { return opened }
        guard !closed else {
            await session.close()
            throw APIError(.refused, "the project is closed")
        }
        storage = .edit(session)
        // The opening did what the read found it would: the result of this command says so.
        if findings.keepsSnapshotApart {
            openingWarnings.append(
                "edit.json could not be read: it was set aside (edit.json.damaged-…) and the project started again from the "
                    + "recording, without its edits")
        }
        if findings.rewritesLog {
            openingWarnings.append(
                "edit-log.jsonl was damaged or did not match its document: it was set aside and rewritten up to "
                    + (findings.recoveredUpTo?.formatted(.iso8601) ?? "its last good line") + "; what came after it is lost")
        }
        return session
    }

    private static func openSession(_ url: URL, environment: APIEnvironment) async throws -> EditSession {
        let session = try await EditSession.open(url, take: nil, context: environment.editContext)
        if case let .readOnly(reason) = session.access {
            await session.close()
            throw apiError(reason)
        }
        session.joinsBursts = false
        return session
    }

    /// `refused` if the project is closed or open for reading.
    private func checkCanEdit() throws(APIError) {
        guard !closed else { throw APIError(.refused, "the project is closed") }
        guard mode == .edit else { throw APIError(.refused, "the project is open for reading: open it for editing to change it") }
    }

    private func checkEditable(_ session: EditSession) throws(APIError) {
        if case let .readOnly(reason) = session.access { throw Self.apiError(reason) }
    }

    /// Whether `command` changes `document` (the one on disk, before the session opens): its error if it has one.
    private func changes(_ command: ProjectCommand, project: LoadedProject, document: EditDocument) async throws -> Bool {
        let (scope, step) = await Self.step(for: command, project: project, document: document, makeID: environment.makeID)
        switch try step.get() {
        case .unchanged:
            return false
        case .step:
            return true
        case .needsSession:
            switch command {
            case let .applyStyle(id):
                return try await style(id, appliedTo: scope) != nil
            case let .setBackground(.image(file)):
                try Self.checkOutsideImage(file)
                // Not an image: refused before the session opens, which would write a new project's first document.
                let source = URL(fileURLWithPath: file)
                guard await Task.detached(operation: { AssetImport.takesAsAnImage(source) }).value else {
                    throw APIError(.refused, "\(file) is not an image Toma can use (PNG, JPEG, HEIC, TIFF, GIF or PDF)")
                }
                return true
            default:
                return true
            }
        }
    }

    // MARK: - Private

    /// `perform` of `step`, waited for on the disk.
    func perform(_ step: EditStep, command: String, created: String?, in session: EditSession) async throws -> CommandResult {
        let reopened = session.reopenings
        guard session.perform(step) != .refused else {
            try checkEditable(session)
            throw APIError(.refused, "the change would leave a document Toma cannot draw")
        }
        try await settle(session, reopened: reopened)
        return result(command, changed: true, label: step.label.rawValue, created: created)
    }

    /// Waits for what the session handed to the disk (an upgrade to version 3 included) and says what kept it from being
    /// saved: another process that took the package first (`locked`), or a disk that refused it (`refused`: the change
    /// waits in memory and is tried again while the project is open). It throws only `APIError`, untyped: with
    /// `async throws(APIError)` the optimizer of Swift 6.4.2 crashes splitting the coroutines of whoever inlines it, and no
    /// Release build of the module comes out.
    private func settle(_ session: EditSession, reopened: Int) async throws {
        _ = await session.flushed()
        try checkEditable(session)
        if session.reopenings > reopened {
            throw APIError(.locked, "another app edited the project first: the change was discarded, and the project read again")
        }
        if session.hasUnsavedChanges {
            let code = session.notices.lazy.compactMap { notice -> POSIXErrorCode? in
                if case let .saveFailed(code) = notice { code } else { nil }
            }.first
            let reason = code.map { " (\(String(cString: strerror($0.rawValue))))" } ?? ""
            throw APIError(.refused, "the change could not be saved\(reason); it waits in memory and is tried again while the project is open")
        }
    }

    /// The commands that need the session itself (`CommandStep.needsSession`).
    private func applyThroughSession(_ command: ProjectCommand, scope: CommandScope, in session: EditSession) async throws -> CommandResult {
        switch command {
        case let .applyStyle(id):
            return try await applyStyle(id, scope: scope, in: session)
        case let .setBackground(.image(file)):
            let imported = try await importImage(file, in: session)
            let scope = await self.scope(of: session)
            switch try CommandSteps.step(for: .setBackground(.image(file: imported)), in: scope) {
            case let .step(step, created): return try await perform(step, command: command.name, created: created, in: session)
            case .unchanged, .needsSession: return result(command.name, changed: false, label: nil, created: nil)
            }
        default:
            throw APIError(.invalidCommand, "\(command.name) cannot be applied here")
        }
    }

    /// The row Style's "Apply" (`EditSession.applyStyle`, its image brought into the package): Toma's style (`toma`), or
    /// one of the library's (`StyleLibrary`) by its id (plan 4b decision 24).
    private func applyStyle(_ id: String, scope: CommandScope, in session: EditSession) async throws -> CommandResult {
        guard let (style, imageDirectory) = try await style(id, appliedTo: scope) else {
            return result("applyStyle", changed: false, label: nil, created: nil)
        }
        let reopened = session.reopenings
        // Its image waits out a full disk without end in `importAsset`: given up as soon as the session says so.
        let ((outcome, _), failure) = await givingUpOnSaveFailure(of: session) {
            await session.applyStyle(style, imageDirectory: imageDirectory)
        }
        guard outcome != .refused else {
            try checkEditable(session)
            if let failure { throw APIError(.refused, "the style's image could not be saved into the project (\(failure))") }
            throw APIError(.refused, "the style could not be applied")
        }
        try await settle(session, reopened: reopened)
        return result("applyStyle", changed: true, label: EditLabel.styleApply.rawValue, created: nil)
    }

    /// The style `id` names and the folder of its image, if applying it to `scope`'s document changes it: Toma's style
    /// (`toma`), or one of the library's (`StyleLibrary`) by its id (plan 4b decision 24: «Toma's Style» of the row
    /// Style). `nil` for a style the project has already: "Apply" changes nothing.
    private func style(_ id: String, appliedTo scope: CommandScope) async throws -> (NamedStyle, URL?)? {
        let style: NamedStyle
        let imageDirectory: URL?
        if id == NamedStyle.tomaStyleID {
            style = NamedStyle.toma(name: "Toma's Style")
            imageDirectory = nil
        } else {
            let library = StyleLibrary(directory: environment.stylesFolder)
            let styles = await Task.detached { library.list() }.value
            guard let found = styles.first(where: { $0.id == id }) else {
                let ids = ([NamedStyle.tomaStyleID] + styles.map(\.id)).joined(separator: ", ")
                throw APIError(.refused, "there is no style “\(id)”; the styles are \(ids)")
            }
            style = found
            imageDirectory = library.imageDirectory(of: found)
        }
        guard StyleCommands.applyStyle(scope.document, style, takes: scope.takes) != nil else { return nil }
        return (style, imageDirectory)
    }

    /// `body` (an import, which `EditSession.importAsset` tries again every 2 s while the disk refuses it, without end),
    /// cancelled as soon as the session shows `.saveFailed`, or when the caller's task is: the import then gives up with
    /// `.saveFailed`, and the command says `refused`, as `perform` does on the same disk. Its value, and why it was given
    /// up on (the session takes its notice away as the import ends).
    private func givingUpOnSaveFailure<T: Sendable>(
        of session: EditSession, _ body: @escaping @MainActor () async -> T
    ) async -> (T, failure: String?) {
        let work = Task { await body() }
        let watch = Task { () -> String? in
            while !Task.isCancelled {
                if let failure = Self.saveFailure(of: session) {
                    work.cancel()
                    return failure
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
        let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        watch.cancel()
        return (value, await watch.value)
    }

    /// Why the session's last change could not be saved, if it says so (`EditNotice.saveFailed`).
    private static func saveFailure(of session: EditSession) -> String? {
        session.notices.lazy.compactMap { notice -> String? in
            if case let .saveFailed(code) = notice { String(cString: strerror(code.rawValue)) } else { nil }
        }.first
    }

    /// An image from outside the package, as a background takes one (fases 4 y 5 design §6.3): a regular file, not a
    /// link, by a path without `..`.
    private static func checkOutsideImage(_ file: String) throws(APIError) {
        if URL(fileURLWithPath: file).pathComponents.contains("..") { throw APIError(.refused, "\(file): a path with “..” is refused") }
        var info = stat()
        guard lstat(file, &info) == 0 else { throw APIError(.refused, "there is no image at \(file)") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw APIError(.refused, "\(file) is a link or not a regular file") }
    }

    /// An image from outside the package copied into its `assets/` (`EditSession.importAsset`), for a background: the
    /// path it has there.
    private func importImage(_ file: String, in session: EditSession) async throws -> String {
        try Self.checkOutsideImage(file)
        let source = URL(fileURLWithPath: file)
        switch await givingUpOnSaveFailure(of: session, { await session.importAsset(source, kind: .image) }).0 {
        case let .imported(path):
            return path
        case .notAnImage, .notALUT, .notPlayable:
            throw APIError(.refused, "\(file) is not an image Toma can use (PNG, JPEG, HEIC, TIFF, GIF or PDF)")
        case .notEditable:
            try checkEditable(session)
            throw APIError(.locked, "another app changed the project before the image could be brought in")
        case let .saveFailed(code):
            throw APIError(.refused, "the image could not be saved into the project (\(String(cString: strerror(code.rawValue)))")
        }
    }

    /// The scope of the session's document, its takes' events read off the main actor.
    private func scope(of session: EditSession) async -> CommandScope {
        let project = session.project, document = session.document, makeID = environment.makeID
        return await Task.detached { Self.scope(project: project, document: document, makeID: makeID) }.value
    }

    /// `command`'s step on `document` and its scope, both worked out off the main actor (planning the automatic zoom
    /// again reads every event).
    private static func step(
        for command: ProjectCommand, project: LoadedProject, document: EditDocument, makeID: @escaping @Sendable (String) -> String
    ) async -> (CommandScope, Result<CommandStep, APIError>) {
        await Task.detached {
            let scope = Self.scope(project: project, document: document, makeID: makeID)
            do throws(APIError) {
                return (scope, .success(try CommandSteps.step(for: command, in: scope)))
            } catch {
                return (scope, .failure(error))
            }
        }.value
    }

    private nonisolated static func scope(
        project: LoadedProject, document: EditDocument, makeID: @escaping @Sendable (String) -> String
    ) -> CommandScope {
        (try? CommandScope.reading(project: project, document: document, makeID: makeID))
            ?? CommandScope(document: document, project: project, takes: [], takeBounds: [:], recordedMarkers: [:], makeID: makeID)
    }

    /// The recorded markers of every take, read once, off the main actor: a take's events never change.
    private func recordedMarkers() async -> MarkerList.Recorded {
        if let recorded { return recorded }
        let project = self.project
        let read = await Task.detached { CommandScope.recordedMarkers(of: project) }.value
        recorded = read
        return read
    }

    func result(_ command: String, changed: Bool, label: String?, created: String?) -> CommandResult {
        let undo: String? = switch storage {
        case let .edit(session): session.undoLabel?.rawValue
        case .editing: diskHistory.undo?.rawValue
        case .read: nil
        }
        // What the opening set aside is told once, by the first result after it.
        let warnings = openingWarnings
        openingWarnings = []
        return CommandResult(
            command: command, changed: changed, label: label, created: created,
            duration: TimeMap(sequence: document.sequence).durationSeconds, undo: undo, via: .project,
            warnings: warnings.isEmpty ? nil : warnings)
    }

    // MARK: - Errors

    /// What opening or reading threw, as the API's error.
    nonisolated static func apiError(_ error: any Error) -> APIError {
        if let error = error as? APIError { return error }
        switch error {
        case let LoadedProjectError.unsupportedFormatVersion(version) where version > Manifest.newestFormatVersion:
            return APIError(.newerVersion, "the package is of format version \(version), newer than this version of Toma reads")
        case let LoadedProjectError.unsupportedFormatVersion(version):
            return APIError(.notAProject, "the package is of format version \(version), which Toma does not read")
        case LoadedProjectError.noTakes:
            return APIError(.notAProject, "the package has no takes")
        case let LoadedProjectError.takeNotFound(take):
            return APIError(.notAProject, "the package has no take \(take)")
        case LoadedProjectError.invalidPath:
            return APIError(.notAProject, "the manifest names a path that leaves the package")
        case let EditDocumentError.newerVersion(version):
            return APIError(.newerVersion, "the edit document is of version \(version), newer than this version of Toma reads")
        case let error as POSIXError where error.code == .ELOOP || error.code == .EFTYPE:
            return APIError(.refused, "a file of the package is a link or not a regular file: Toma does not read through it")
        case let error as POSIXError where error.code == .ENOENT || error.code == .ENOTDIR:
            return APIError(.notAProject, "a file the package needs is not there")
        case is DecodingError:
            return APIError(.notAProject, "the package's manifest or edit document cannot be read")
        default:
            return APIError(.refused, "the project cannot be read: \(error)")
        }
    }

    /// Why a session cannot edit, as the API's error.
    nonisolated static func apiError(_ reason: ReadOnlyReason) -> APIError {
        switch reason {
        case .openElsewhere, .otherAppStartedEditing:
            APIError(.locked, "another app is editing the project (it holds edit.lock): close it there, or edit it through the app")
        case let .newerDocument(version):
            APIError(.newerVersion, "the project is of version \(version), newer than this version of Toma edits")
        case .diskNotWritable:
            APIError(.refused, "the project's folder or volume cannot be written")
        case .unsafeEditFiles:
            APIError(
                .refused,
                "edit.json, edit-log.jsonl or edit.lock is a link or not a regular file, or the document holds values Toma cannot draw")
        case .unreadable:
            APIError(.refused, "another app changed the package into one this version of Toma cannot open")
        case .inTrash:
            APIError(.refused, "the project is in the trash")
        }
    }

    /// Whether a version 3 package has an edit document on disk (`edit.json` or `edit-log.jsonl`).
    private nonisolated static func hasEditFiles(_ project: LoadedProject) -> Bool {
        guard project.manifest.formatVersion >= 3 else { return false }
        var info = stat()
        return lstat(project.package.editURL.path, &info) == 0 || lstat(project.package.editLogURL.path, &info) == 0
    }

    /// What the edit log of `project` can undo and redo, as its session would see it: nothing without a log.
    private nonisolated static func diskHistory(of project: LoadedProject) -> DiskHistory {
        guard project.manifest.formatVersion >= 3, let read = try? EditLogReader.read(project.package.editLogURL) else {
            return DiskHistory()
        }
        let history = UndoHistory(entries: read.entries, createVersion: read.createVersion ?? EditDocument.currentVersion)
        return DiskHistory(undo: history.undoLabel, redo: history.redoLabel)
    }
}
