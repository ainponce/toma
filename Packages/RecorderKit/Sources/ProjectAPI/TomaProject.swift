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
/// - `.edit` is an `EditSession` with `edit.lock`, as the editor's. Each command is one `perform`, waited for on the disk
///   (`flushed`) before it returns: what `apply` says was done is in the log. Another process holding the lock is
///   `locked`. A project of version 1 to 4 stays as it is until the first command that changes it, which the session
///   writes with its `migrate` (and, for version 1 or 2, the package's upgrade to 3).
///
/// Everything it throws is an `APIError`. What reads the disk (the takes' events) runs off the main actor.
@MainActor public final class TomaProject {
    public enum Mode: String, Codable, Sendable { case read, edit }

    public let url: URL
    public let mode: Mode
    public let environment: APIEnvironment

    private enum Storage {
        case read(LoadedProject, EditDocument)
        case edit(EditSession)
    }

    private let storage: Storage
    /// The `documentVersion` of the edit document on disk as the project opened; `nil` without one.
    private let openedDocumentVersion: Int?
    private var recorded: MarkerList.Recorded?
    private var closed = false

    private init(url: URL, mode: Mode, environment: APIEnvironment, storage: Storage, openedDocumentVersion: Int?) {
        self.url = url
        self.mode = mode
        self.environment = environment
        self.storage = storage
        self.openedDocumentVersion = openedDocumentVersion
    }

    /// Opens the package at `url` (a folder `.toma`, checked as `ProjectPaths` does) for reading or editing.
    public static func open(_ url: URL, mode: Mode, environment: APIEnvironment = .standard) async throws -> TomaProject {
        try ProjectPaths.checkPackage(url)
        let context = environment.editContext
        switch mode {
        case .read:
            let read = await Task.detached { () -> Result<(LoadedProject, EditDocument, Int?), any Error> in
                Result {
                    let (project, document, diskVersion) = try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context)
                    return (project, document, Self.hasEditFiles(project) ? diskVersion : nil)
                }
            }.value
            switch read {
            case let .success((project, document, version)):
                return TomaProject(
                    url: url, mode: mode, environment: environment, storage: .read(project, document), openedDocumentVersion: version)
            case let .failure(error):
                throw apiError(error)
            }
        case .edit:
            let version = await Task.detached { Self.writtenDocumentVersion(of: url) }.value
            let session: EditSession
            do { session = try await EditSession.open(url, take: nil, context: context) } catch { throw apiError(error) }
            if case let .readOnly(reason) = session.access {
                await session.close()
                throw apiError(reason)
            }
            return TomaProject(url: url, mode: mode, environment: environment, storage: .edit(session), openedDocumentVersion: version)
        }
    }

    /// In `.read`, the document on disk as `EditSession.readDocument` gives it; in `.edit`, the session's.
    public var document: EditDocument {
        switch storage {
        case let .read(_, document): document
        case let .edit(session): session.document
        }
    }

    public var project: LoadedProject {
        switch storage {
        case let .read(project, _): project
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
        if case let .edit(session) = storage, session.documentIsCurrentOnDisk { return EditDocument.currentVersion }
        return openedDocumentVersion
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
            music: Reports.music(document), transcript: Reports.transcriptSummary(document))
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
        let session = try editableSession()
        if case let .transcribe(language, replace) = command {
            return try await runTranscription(language: language, replace: replace)
        }
        while true {
            let revision = session.revision
            let (scope, step) = await step(for: command, in: session)
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
        let session = try editableSession()
        guard session.canUndo, let label = session.undoLabel else { throw APIError(.refused, "there is nothing to undo") }
        let reopened = reopenings(of: session)
        guard session.undo() != .refused else {
            try checkEditable(session)
            throw APIError(.refused, "there is nothing to undo")
        }
        try await settle(session, reopened: reopened)
        return result("undo", changed: true, label: label.rawValue, created: nil)
    }

    public func redo() async throws -> CommandResult {
        let session = try editableSession()
        guard session.canRedo, let label = session.redoLabel else { throw APIError(.refused, "there is nothing to redo") }
        let reopened = reopenings(of: session)
        guard session.redo() != .refused else {
            try checkEditable(session)
            throw APIError(.refused, "there is nothing to redo")
        }
        try await settle(session, reopened: reopened)
        return result("redo", changed: true, label: label.rawValue, created: nil)
    }

    /// Releases the project: in `.edit`, the session writes its snapshot and lets go of `edit.lock`. Nothing after it.
    public func close() async {
        guard !closed else { return }
        closed = true
        if case let .edit(session) = storage { await session.close() }
    }

    // MARK: - Private

    /// The session, if the project can be edited now.
    private func editableSession() throws(APIError) -> EditSession {
        guard !closed else { throw APIError(.refused, "the project is closed") }
        guard case let .edit(session) = storage else {
            throw APIError(.refused, "the project is open for reading: open it for editing to change it")
        }
        try checkEditable(session)
        return session
    }

    private func checkEditable(_ session: EditSession) throws(APIError) {
        if case let .readOnly(reason) = session.access { throw Self.apiError(reason) }
    }

    /// How many times the session opened the package again since it opened.
    private func reopenings(of session: EditSession) -> Int {
        session.notices.filter { $0 == .reopenedAfterOtherApp }.count
    }

    /// `perform` of `step`, waited for on the disk.
    private func perform(_ step: EditStep, command: String, created: String?, in session: EditSession) async throws -> CommandResult {
        let reopened = reopenings(of: session)
        guard session.perform(step) != .refused else {
            try checkEditable(session)
            throw APIError(.refused, "the change would leave a document Toma cannot draw")
        }
        try await settle(session, reopened: reopened)
        return result(command, changed: true, label: step.label.rawValue, created: created)
    }

    /// Waits for what the session handed to the disk (an upgrade to version 3 included) and says what kept it from being
    /// saved: another process that took the package first (`locked`), or a disk that refused it (`refused`: the change
    /// waits in memory and is tried again while the project is open).
    private func settle(_ session: EditSession, reopened: Int) async throws(APIError) {
        _ = await session.flushed()
        try checkEditable(session)
        if reopenings(of: session) > reopened {
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
        // "Apply" of a style the project has already changes nothing (`StyleMenu.has`).
        guard StyleCommands.applyStyle(scope.document, style, takes: scope.takes) != nil else {
            return result("applyStyle", changed: false, label: nil, created: nil)
        }
        let reopened = reopenings(of: session)
        let (outcome, _) = await session.applyStyle(style, imageDirectory: imageDirectory)
        guard outcome != .refused else {
            try checkEditable(session)
            throw APIError(.refused, "the style could not be applied")
        }
        try await settle(session, reopened: reopened)
        return result("applyStyle", changed: true, label: EditLabel.styleApply.rawValue, created: nil)
    }

    /// An image from outside the package copied into its `assets/` (`EditSession.importAsset`), for a background: the
    /// path it has there.
    private func importImage(_ file: String, in session: EditSession) async throws -> String {
        let source = URL(fileURLWithPath: file)
        if source.pathComponents.contains("..") { throw APIError(.refused, "\(file): a path with “..” is refused") }
        var info = stat()
        guard lstat(file, &info) == 0 else { throw APIError(.refused, "there is no image at \(file)") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw APIError(.refused, "\(file) is a link or not a regular file") }
        switch await session.importAsset(source, kind: .image) {
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

    /// `command`'s step on the session's document and its scope, both worked out off the main actor (planning the
    /// automatic zoom again reads every event).
    private func step(for command: ProjectCommand, in session: EditSession) async -> (CommandScope, Result<CommandStep, APIError>) {
        let project = session.project, document = session.document, makeID = environment.makeID
        return await Task.detached {
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

    private func result(_ command: String, changed: Bool, label: String?, created: String?) -> CommandResult {
        var undo: String?
        if case let .edit(session) = storage { undo = session.undoLabel?.rawValue }
        return CommandResult(
            command: command, changed: changed, label: label, created: created,
            duration: TimeMap(sequence: document.sequence).durationSeconds, undo: undo, via: .project)
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

    /// The `documentVersion` `edit.json` is written in, read without following a link; `nil` without one.
    private nonisolated static func writtenDocumentVersion(of url: URL) -> Int? {
        guard let data = try? SafeRead.regularFile("edit.json", in: url) else { return nil }
        return EditDocument.writtenVersion(of: data)
    }
}
