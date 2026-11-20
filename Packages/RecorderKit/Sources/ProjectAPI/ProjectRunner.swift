// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The operations of one go that the `toma` command and the MCP server make on a project (plan 4b, Task A4): each opens
/// the package (`TomaProject`), does one thing and closes it, so nothing stays open nor locked between two calls. Reading
/// and exporting open it for reading, which never writes; a change, an undo and a redo open it for editing, which takes
/// `edit.lock` with the first change. Everything it throws is an `APIError` (an export that is cancelled throws
/// `CancellationError`).
@MainActor public enum ProjectRunner {
    /// What `toma info` and `project_info` say of the project at `url`.
    public static func report(_ url: URL, environment: APIEnvironment) async throws -> ProjectReport {
        try await reading(url, environment: environment) { await $0.report() }
    }

    /// The transcript; `nil` without one.
    public static func transcript(_ url: URL, environment: APIEnvironment) async throws -> TranscriptReport? {
        try await reading(url, environment: environment) { $0.transcriptReport() }
    }

    /// The markers and the chapters.
    public static func markers(_ url: URL, environment: APIEnvironment) async throws -> MarkersReport {
        try await reading(url, environment: environment) { await $0.markersReport() }
    }

    /// `commands` in order, each its own undo step, stopping at the first that fails (plan 4b decision 6): what was done
    /// before it stays. A project that cannot be opened for editing (not a project, locked, newer) gives its error with
    /// no result and no `failedIndex`: nothing ran. `each` is told of every command as it is done and on the disk, with
    /// its index in the list.
    public static func apply(
        _ commands: [ProjectCommand], to url: URL, environment: APIEnvironment,
        each: (@MainActor (Int, CommandResult) -> Void)? = nil
    ) async -> BatchResult {
        let project: TomaProject
        do {
            project = try await TomaProject.open(url, mode: .edit, environment: environment)
        } catch {
            return BatchResult(results: [], error: TomaProject.apiError(error), failedIndex: nil)
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
        return BatchResult(results: results, error: failure?.0, failedIndex: failure?.1)
    }

    /// Undoes the last step of the project's edit log: also one the app or an earlier call made.
    public static func undo(_ url: URL, environment: APIEnvironment) async throws -> CommandResult {
        try await editing(url, environment: environment) { try await $0.undo() }
    }

    public static func redo(_ url: URL, environment: APIEnvironment) async throws -> CommandResult {
        try await editing(url, environment: environment) { try await $0.redo() }
    }

    /// Exports the project as it is on disk to `destination` (`TomaProject.format(for:)` and `export`): opened for
    /// reading, so the package is never written.
    public static func export(
        _ url: URL, to destination: URL, request: ExportRequest, environment: APIEnvironment,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> ExportResult {
        try await reading(url, environment: environment) { project in
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
