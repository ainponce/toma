// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Editing
import Foundation
import ProjectFormat

/// What the control socket works on in the app: the editor of the package the request names, its session and what the
/// editor's gestures go through (fases 4 y 5 design §6.4). The app makes one of its `EditorModel`; the tests, of an
/// `EditSession` alone (`init(session:stylesFolder:makeID:)`).
@MainActor public struct ControlEditor {
    /// The editor's session: its document, its undo history and what it has saved.
    public var session: EditSession
    /// The project as the editor reads it (the package where it is now).
    public var project: @MainActor () -> LoadedProject
    /// What each take the sequence shows has, as the editor's mix holds the sound's cuts to it (`EditorModel.takeBounds`);
    /// those it lacks are read from the takes' events.
    public var takeBounds: @MainActor () -> [String: ClosedRange<HostTime>]
    /// Whether the editor can change the project now (`EditorModel.canEdit`): it is open and holds `edit.lock`.
    public var canEdit: @MainActor () -> Bool
    /// One step, as the editor's gestures make it (`EditorModel.perform`).
    public var perform: @MainActor (EditStep) -> EditOutcome
    /// The row Style's "Apply" (`EditorModel.applyStyle`): the style, its image brought into the package first.
    public var applyStyle: @MainActor (NamedStyle, URL?) async -> EditOutcome
    /// The user's named styles (`StyleLibrary.defaultDirectory` in the app), for `applyStyle{id}`.
    public var stylesFolder: URL
    /// The name of Toma's style (`NamedStyle.tomaStyleID`), as the app shows it.
    public var tomaStyleName: String
    /// A new id: `makeID("m-")` is `m-` and 8 random hex digits.
    public var makeID: @Sendable (String) -> String

    public init(
        session: EditSession, project: @escaping @MainActor () -> LoadedProject,
        takeBounds: @escaping @MainActor () -> [String: ClosedRange<HostTime>], canEdit: @escaping @MainActor () -> Bool,
        perform: @escaping @MainActor (EditStep) -> EditOutcome,
        applyStyle: @escaping @MainActor (NamedStyle, URL?) async -> EditOutcome, stylesFolder: URL, tomaStyleName: String,
        makeID: @escaping @Sendable (String) -> String
    ) {
        self.session = session
        self.project = project
        self.takeBounds = takeBounds
        self.canEdit = canEdit
        self.perform = perform
        self.applyStyle = applyStyle
        self.stylesFolder = stylesFolder
        self.tomaStyleName = tomaStyleName
        self.makeID = makeID
    }

    /// `session` alone, as an editor without anything of its own: its project, the takes' bounds read from their events,
    /// its `perform` and `applyStyle`, editable while the session is.
    public init(session: EditSession, stylesFolder: URL, makeID: @escaping @Sendable (String) -> String) {
        self.init(
            session: session, project: { session.project }, takeBounds: { [:] },
            canEdit: { session.access == .editable }, perform: { session.perform($0) },
            applyStyle: { await session.applyStyle($0, imageDirectory: $1).outcome }, stylesFolder: stylesFolder,
            tomaStyleName: "Toma's Style", makeID: makeID)
    }
}

/// What the app does with a request of the control socket (fases 4 y 5 design §6.4, plan 4b decision 19), on the main
/// actor, with the editor of the package it names: the API's commands become the steps of the app's own gestures
/// (`CommandSteps`, the same as `TomaProject.apply` makes), performed by the editor, so they are seen at once, undone with
/// Edit ▸ Undo and logged as gestures; and the answer waits for them to be on the disk (`EditSession.flushed`).
///
/// Through the socket, `transcribe` and a `setBackground` with an image from outside the package are `notAvailable`: the
/// app does them in its own windows, and no request names a file other than its package's. Every result says `via: app`.
public enum ControlHandling {
    /// How many times a command is worked out again because the editor's document changed meanwhile (the user edits).
    static let attempts = 8

    /// The identity of the package `path` names (`ProjectPaths`' rules): an absolute path, without `..`, of a folder
    /// `.toma` that is not a link and holds a `manifest.json`.
    public static func packageID(_ path: String?) throws(APIError) -> ControlPackageID {
        guard let path, path.hasPrefix("/") else { throw APIError(.notAProject, "the request names no package by an absolute path") }
        let url = try ProjectPaths.package(path, relativeTo: URL(fileURLWithPath: "/"))
        guard let id = ControlPackageID(url: url) else { throw APIError(.notAProject, "\(url.path) is not there") }
        return id
    }

    /// The answer to `request` for `editor`, the editor of the package it names. `ping` and `flush` are always done;
    /// `apply`, `undo` and `redo` are not handled while the editor cannot edit.
    @MainActor public static func handle(_ request: ControlRequest, editor: ControlEditor) async -> ControlResponse {
        switch request.op {
        case .ping:
            return .done
        case .flush:
            _ = await editor.session.flushed()
            return .done
        case .apply:
            guard let commands = request.commands, !commands.isEmpty else {
                return .refused(APIError(.invalidCommand, "the request has no commands"))
            }
            return await apply(commands, editor: editor)
        case .undo, .redo:
            guard editor.canEdit() else { return .notHandled }
            do throws(APIError) {
                let result = try await step(back: request.op == .undo, editor: editor)
                return ControlResponse(handled: true, results: [result], error: nil, failedIndex: nil)
            } catch {
                return .refused(error)
            }
        }
    }

    /// `commands` in order through `editor`, each its own step, waited for on the disk; stops at the first that fails
    /// (plan 4b decision 6). Not handled if the editor cannot edit before the first.
    @MainActor public static func apply(_ commands: [ProjectCommand], editor: ControlEditor) async -> ControlResponse {
        var results: [CommandResult] = []
        for (k, command) in commands.enumerated() {
            guard editor.canEdit() else {
                if k == 0 { return .notHandled }
                return ControlResponse(
                    handled: true, results: results,
                    error: APIError(.locked, "Toma can no longer edit the project: it is open there for viewing only"), failedIndex: k)
            }
            do throws(APIError) {
                results.append(try await apply(command, editor: editor))
            } catch {
                return ControlResponse(handled: true, results: results, error: error, failedIndex: k)
            }
        }
        return ControlResponse(handled: true, results: results, error: nil, failedIndex: nil)
    }

    // MARK: - Private

    @MainActor private static func apply(_ command: ProjectCommand, editor: ControlEditor) async throws(APIError) -> CommandResult {
        switch command {
        case .transcribe:
            throw APIError(
                .notAvailable,
                "transcribe is not done through Toma while it has the project open: transcribe it there (Captions), or close it there first")
        case let .setBackground(.image(file)) where file.hasPrefix("/"):
            throw APIError(
                .notAvailable,
                "an image from outside the project is not brought in through Toma while it has the project open: choose it there (Background ▸ Image), or close it there first")
        default:
            break
        }
        let session = editor.session
        for _ in 0..<attempts {
            let revision = session.revision
            let (scope, step) = await workedOut(command, editor: editor)
            // The user changed the document while its takes were read: from the document as it is now.
            guard session.revision == revision else { continue }
            switch try step.get() {
            case .unchanged:
                return result(command.name, changed: false, label: nil, created: nil, session: session)
            case let .step(step, created):
                guard editor.perform(step) != .refused else {
                    try checkEditable(editor)
                    throw APIError(.refused, "the change would leave a document Toma cannot draw")
                }
                try await settle(editor)
                return result(command.name, changed: true, label: step.label.rawValue, created: created, session: session)
            case .needsSession:
                guard case let .applyStyle(id) = command else {
                    throw APIError(.notAvailable, "\(command.name) is not done through Toma while it has the project open")
                }
                let (style, imageDirectory) = try await namedStyle(id, editor: editor)
                guard StyleCommands.applyStyle(scope.document, style, takes: scope.takes) != nil else {
                    return result(command.name, changed: false, label: nil, created: nil, session: session)
                }
                guard await editor.applyStyle(style, imageDirectory) != .refused else {
                    try checkEditable(editor)
                    throw APIError(.refused, "the style could not be applied")
                }
                try await settle(editor)
                return result(command.name, changed: true, label: EditLabel.styleApply.rawValue, created: nil, session: session)
            }
        }
        throw APIError(.refused, "the project kept changing in Toma while the command was worked out: try it again")
    }

    /// Edit ▸ Undo (`back`) or Redo of the editor's session, waited for on the disk.
    @MainActor private static func step(back: Bool, editor: ControlEditor) async throws(APIError) -> CommandResult {
        let session = editor.session
        let label = back ? session.undoLabel : session.redoLabel
        let possible = back ? session.canUndo : session.canRedo
        let nothing = APIError(.refused, back ? "there is nothing to undo" : "there is nothing to redo")
        guard possible, let label else { throw nothing }
        guard (back ? session.undo() : session.redo()) != .refused else {
            try checkEditable(editor)
            throw nothing
        }
        try await settle(editor)
        return result(back ? "undo" : "redo", changed: true, label: label.rawValue, created: nil, session: session)
    }

    /// `command`'s step on the editor's document and its scope, worked out off the main actor (the takes' events are
    /// read, and planning the automatic zoom again reads every one).
    @MainActor private static func workedOut(
        _ command: ProjectCommand, editor: ControlEditor
    ) async -> (CommandScope, Result<CommandStep, APIError>) {
        let document = editor.session.document, project = editor.project(), bounds = editor.takeBounds()
        let makeID = editor.makeID
        return await Task.detached { () -> (CommandScope, Result<CommandStep, APIError>) in
            var scope = (try? CommandScope.reading(project: project, document: document, makeID: makeID))
                ?? CommandScope(document: document, project: project, takes: [], takeBounds: [:], recordedMarkers: [:], makeID: makeID)
            scope.takeBounds.merge(bounds) { $1 }
            do throws(APIError) {
                return (scope, .success(try CommandSteps.step(for: command, in: scope)))
            } catch {
                return (scope, .failure(error))
            }
        }.value
    }

    /// The style `id` names: Toma's (`toma`), or one of the user's named styles, with the folder of its image.
    @MainActor private static func namedStyle(_ id: String, editor: ControlEditor) async throws(APIError) -> (NamedStyle, URL?) {
        if id == NamedStyle.tomaStyleID { return (NamedStyle.toma(name: editor.tomaStyleName), nil) }
        let library = StyleLibrary(directory: editor.stylesFolder)
        let styles = await Task.detached { library.list() }.value
        guard let found = styles.first(where: { $0.id == id }) else {
            let ids = ([NamedStyle.tomaStyleID] + styles.map(\.id)).joined(separator: ", ")
            throw APIError(.refused, "there is no style “\(id)”; the styles are \(ids)")
        }
        return (found, library.imageDirectory(of: found))
    }

    /// Waits for what the editor handed to the disk, and says what kept it from being saved.
    @MainActor private static func settle(_ editor: ControlEditor) async throws(APIError) {
        let session = editor.session
        _ = await session.flushed()
        try checkEditable(editor)
        if session.hasUnsavedChanges {
            throw APIError(
                .refused,
                "Toma made the change but could not save it yet (the disk refused it); it keeps it and tries again while the project is open")
        }
    }

    @MainActor private static func checkEditable(_ editor: ControlEditor) throws(APIError) {
        if case let .readOnly(reason) = editor.session.access { throw TomaProject.apiError(reason) }
        guard editor.canEdit() else { throw APIError(.locked, "Toma can no longer edit the project") }
    }

    @MainActor private static func result(
        _ command: String, changed: Bool, label: String?, created: String?, session: EditSession
    ) -> CommandResult {
        CommandResult(
            command: command, changed: changed, label: label, created: created,
            duration: TimeMap(sequence: session.document.sequence).durationSeconds, undo: session.undoLabel?.rawValue, via: .app)
    }
}
