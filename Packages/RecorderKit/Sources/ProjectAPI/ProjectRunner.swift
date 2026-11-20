// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The operations of one go that the `toma` command and the MCP server make on a project (plan 4b, Task A4): each opens
/// the package (`TomaProject`), does one thing and closes it, so nothing stays open nor locked between two calls. Reading
/// and exporting open it for reading, which never writes; a change, an undo and a redo open it for editing, which takes
/// `edit.lock` with the first change. Everything it throws is an `APIError` (an export that is cancelled throws
/// `CancellationError`).
///
/// The app over its control socket (fases 4 y 5 design §6.4, plan 4b decision 19): a change, an undo or a redo of a
/// project another process holds `edit.lock` of is asked of the app (`environment.controlSocket`), which applies it in
/// its editor when it is the one with the project open (`via: app`); `locked` when it is not, or no app answers. Before a
/// read or an export of a project someone holds `edit.lock` of, the app is asked to put what its editor shows on the
/// disk first (`flush`), if it answers.
@MainActor public enum ProjectRunner {
    /// How long the app has to answer a change, an undo or a redo: 30 s.
    public static let appTimeout: Duration = .seconds(30)
    /// How long the app has to answer a `flush`: 10 s.
    public static let flushTimeout: Duration = .seconds(10)

    /// What `toma info` and `project_info` say of the project at `url`.
    public static func report(_ url: URL, environment: APIEnvironment) async throws -> ProjectReport {
        await askTheAppToFlush(url, environment: environment)
        return try await reading(url, environment: environment) { await $0.report() }
    }

    /// The transcript; `nil` without one.
    public static func transcript(_ url: URL, environment: APIEnvironment) async throws -> TranscriptReport? {
        await askTheAppToFlush(url, environment: environment)
        return try await reading(url, environment: environment) { $0.transcriptReport() }
    }

    /// The markers and the chapters.
    public static func markers(_ url: URL, environment: APIEnvironment) async throws -> MarkersReport {
        await askTheAppToFlush(url, environment: environment)
        return try await reading(url, environment: environment) { await $0.markersReport() }
    }

    /// `commands` in order, each its own undo step, stopping at the first that fails (plan 4b decision 6): what was done
    /// before it stays. A project that cannot be opened for editing (not a project, locked, newer) gives its error with
    /// no result and no `failedIndex`: nothing ran. `each` is told of every command as it is done and on the disk, with
    /// its index in the list. A project another process holds `edit.lock` of goes through the app, if it is the one
    /// (`via: app`, and `each` is told of them once the app answers); `locked` if not.
    public static func apply(
        _ commands: [ProjectCommand], to url: URL, environment: APIEnvironment,
        each: (@MainActor (Int, CommandResult) -> Void)? = nil
    ) async -> BatchResult {
        let project: TomaProject
        do {
            project = try await TomaProject.open(url, mode: .edit, environment: environment)
        } catch {
            let error = TomaProject.apiError(error)
            guard error.code == .locked else { return BatchResult(results: [], error: error, failedIndex: nil) }
            return await throughTheApp(commands, url, environment: environment, each: each)
                ?? BatchResult(results: [], error: error, failedIndex: nil)
        }
        var results: [CommandResult] = []
        var failure: (APIError, Int)?
        for (k, command) in commands.enumerated() {
            do {
                let result = try await project.apply(command)
                results.append(result)
                each?(k, result)
            } catch {
                failure = (TomaProject.apiError(error), k)
                break
            }
        }
        await project.close()
        // The app took the project between the look at its lock and the first change: nothing ran here.
        if results.isEmpty, let (error, _) = failure, error.code == .locked {
            return await throughTheApp(commands, url, environment: environment, each: each)
                ?? BatchResult(results: [], error: error, failedIndex: 0)
        }
        return BatchResult(results: results, error: failure?.0, failedIndex: failure?.1)
    }

    /// Undoes the last step of the project's edit log: also one the app or an earlier call made. With the project open in
    /// the app, the app's Edit ▸ Undo.
    public static func undo(_ url: URL, environment: APIEnvironment) async throws -> CommandResult {
        try await steppingBack(.undo, url, environment: environment) { try await $0.undo() }
    }

    public static func redo(_ url: URL, environment: APIEnvironment) async throws -> CommandResult {
        try await steppingBack(.redo, url, environment: environment) { try await $0.redo() }
    }

    /// Exports the project as it is on disk to `destination` (`TomaProject.format(for:)` and `export`): opened for
    /// reading, so the package is never written. With the project open in the app, what its editor shows is put on the
    /// disk first.
    public static func export(
        _ url: URL, to destination: URL, request: ExportRequest, environment: APIEnvironment,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> ExportResult {
        await askTheAppToFlush(url, environment: environment)
        return try await reading(url, environment: environment) { project in
            let format = try await project.format(for: request)
            return try await project.export(to: destination, format: format, progress: progress)
        }
    }

    /// What `toma validate` says of the package at `url` (`ProjectValidation`); never throws: a package that cannot be
    /// read is one that is not valid, and its problem says why.
    public static func validate(_ url: URL, environment: APIEnvironment) async -> ValidationReport {
        await ProjectValidation.report(url, environment: environment)
    }

    /// The packages in `folder`, or in the library's folder (`environment.projectsFolder`) with `nil`
    /// (`ProjectListing.list`).
    public static func listProjects(in folder: URL?, environment: APIEnvironment) async throws -> [ProjectListing] {
        try await ProjectListing.list(in: folder, environment: environment)
    }

    // MARK: - The app

    /// `commands` applied by the app over its control socket, if it has the project open for editing; `nil` if it does not
    /// or no app answers (nothing was asked of it, or it did not take it): the project is `locked`.
    private static func throughTheApp(
        _ commands: [ProjectCommand], _ url: URL, environment: APIEnvironment, each: (@MainActor (Int, CommandResult) -> Void)?
    ) async -> BatchResult? {
        let request = ControlRequest(op: .apply, package: url.path, commands: commands)
        let response: ControlResponse
        switch await askTheApp(request, environment: environment, timeout: appTimeout) {
        case let .success(answer): response = answer
        case let .failure(error): return BatchResult(results: [], error: error, failedIndex: nil)
        case nil: return nil
        }
        guard response.handled || response.error != nil else { return nil }
        for (k, result) in response.results.enumerated() { each?(k, result) }
        return BatchResult(results: response.results, error: response.error, failedIndex: response.failedIndex)
    }

    /// An undo or a redo: on the package, or by the app if another process holds `edit.lock` and it is the app.
    private static func steppingBack(
        _ op: ControlRequest.Op, _ url: URL, environment: APIEnvironment, _ body: (TomaProject) async throws -> CommandResult
    ) async throws -> CommandResult {
        do {
            return try await editing(url, environment: environment, body)
        } catch let error as APIError where error.code == .locked {
            switch await askTheApp(ControlRequest(op: op, package: url.path, commands: nil), environment: environment, timeout: appTimeout) {
            case let .success(response) where response.handled || response.error != nil:
                if let failure = response.error { throw failure }
                guard let result = response.results.first else { throw APIError(.refused, "Toma answered without a result") }
                return result
            case let .failure(failure): throw failure
            case .success, nil: throw error
            }
        }
    }

    /// Asks the app to put what its editor shows of the project at `url` on the disk, when someone holds its `edit.lock`
    /// and the app answers within `flushTimeout`; otherwise nothing.
    private static func askTheAppToFlush(_ url: URL, environment: APIEnvironment) async {
        let lock = url.appending(path: "edit.lock", directoryHint: .notDirectory)
        guard await Task.detached(operation: { RecordingLock.isHeld(at: lock) }).value else { return }
        _ = await askTheApp(ControlRequest(op: .flush, package: url.path, commands: nil), environment: environment, timeout: flushTimeout)
    }

    /// The app's answer to `request`: `nil` when no app listens (nothing was sent); an error when one did not answer as it
    /// should, or answered too late (it may have done it).
    private static func askTheApp(
        _ request: ControlRequest, environment: APIEnvironment, timeout: Duration
    ) async -> Result<ControlResponse, APIError>? {
        do throws(ControlSocketError) {
            return .success(try await ControlClient.send(request, to: environment.controlSocket, timeout: timeout))
        } catch {
            switch error {
            case .noServer, .pathTooLong, .notASocket:
                return nil
            case .timedOut:
                return .failure(APIError(
                    .refused, "Toma, which has the project open, did not answer in time: look there whether it was done"))
            case .inUse, .system:
                return .failure(APIError(.refused, "Toma, which has the project open, did not answer (\(error))"))
            }
        }
    }

    // MARK: - Private

    private static func reading<T>(
        _ url: URL, environment: APIEnvironment, _ body: (TomaProject) async throws -> T
    ) async throws -> T {
        try await opened(url, mode: .read, environment: environment, body)
    }

    private static func editing<T>(
        _ url: URL, environment: APIEnvironment, _ body: (TomaProject) async throws -> T
    ) async throws -> T {
        try await opened(url, mode: .edit, environment: environment, body)
    }

    /// `body` with the project at `url` open in `mode`, closed afterwards whatever it does.
    private static func opened<T>(
        _ url: URL, mode: TomaProject.Mode, environment: APIEnvironment, _ body: (TomaProject) async throws -> T
    ) async throws -> T {
        let project: TomaProject
        do {
            project = try await TomaProject.open(url, mode: mode, environment: environment)
        } catch {
            throw TomaProject.apiError(error)
        }
        do {
            let value = try await body(project)
            await project.close()
            return value
        } catch is CancellationError {
            await project.close()
            throw CancellationError()
        } catch {
            await project.close()
            throw TomaProject.apiError(error)
        }
    }
}
