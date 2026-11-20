// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat
import Synchronization

/// The exports `export_video` runs in the background (`background: true`), which `export_status` tells of: a client
/// such as Claude Desktop gives up on a call after 60 s, and an export of a few minutes of video takes longer. A job lives
/// as long as its server; the end of the input waits for it, SIGTERM cancels it (and its partial file goes).
final class ExportJobs: Sendable {
    /// What `export_video` with `background: true` and `export_status` answer.
    struct Status: Encodable, Sendable {
        var jobId: String
        /// `running`, `done` or `failed`.
        var status: String
        var project: String
        /// The file the export writes.
        var output: String
        /// From 0 to 1.
        var progress: Double
        /// What the export wrote, once `done`.
        var result: ExportResult?
        /// Why it failed, once `failed`.
        var error: APIError?
    }

    private enum State: Sendable {
        case running(Double)
        case done(ExportResult)
        case failed(APIError)
    }

    private struct Job: Sendable {
        var number: Int
        var project: String
        var output: String
        var state: State
        var task: Task<Void, Never>?
    }

    private let jobs = Mutex<[String: Job]>([:])

    /// Starts `work` as the job `id` (exporting `project` to `output`) and gives its first status. `work` is told how to
    /// report its progress.
    func start(
        id: String, project: URL, output: URL,
        work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> ExportResult
    ) -> Status {
        jobs.withLock { jobs in
            jobs[id] = Job(number: jobs.count, project: project.path, output: output.path, state: .running(0), task: nil)
        }
        let task = Task {
            let state: State
            do {
                state = .done(try await work { fraction in self.update(id, fraction) })
            } catch let error as APIError {
                state = .failed(error)
            } catch is CancellationError {
                state = .failed(APIError(.exportFailed, "the export was cancelled: nothing was written"))
            } catch {
                state = .failed(APIError(.exportFailed, "the export failed: \(error)"))
            }
            self.jobs.withLock { $0[id]?.state = state }
        }
        jobs.withLock { $0[id]?.task = task }
        return status(id)!
    }

    /// The job `id`; `nil` for one this server never started.
    func status(_ id: String) -> Status? {
        jobs.withLock { jobs in jobs[id].map { Self.status(id, $0) } }
    }

    /// Every job, in the order they started.
    var all: [Status] {
        jobs.withLock { jobs in
            jobs.sorted { $0.value.number < $1.value.number }.map { Self.status($0.key, $0.value) }
        }
    }

    /// Whether `id` is a job already.
    func contains(_ id: String) -> Bool {
        jobs.withLock { $0[id] != nil }
    }

    /// Waits for every job to end; with `cancelling`, cancels them first.
    func finish(cancelling: Bool) async {
        let tasks = jobs.withLock { $0.values.compactMap(\.task) }
        if cancelling { for task in tasks { task.cancel() } }
        for task in tasks { await task.value }
    }

    private func update(_ id: String, _ fraction: Double) {
        guard fraction.isFinite else { return }
        let rounded = (min(max(fraction, 0), 1) * 100).rounded(.down) / 100
        jobs.withLock { jobs in
            guard case let .running(last)? = jobs[id]?.state, rounded > last else { return }
            jobs[id]?.state = .running(rounded)
        }
    }

    private static func status(_ id: String, _ job: Job) -> Status {
        switch job.state {
        case let .running(progress):
            Status(jobId: id, status: "running", project: job.project, output: job.output, progress: progress)
        case let .done(result):
            Status(jobId: id, status: "done", project: job.project, output: job.output, progress: 1, result: result)
        case let .failed(error):
            Status(jobId: id, status: "failed", project: job.project, output: job.output, progress: 0, error: error)
        }
    }
}

/// `export_status{jobId?}`: how an export started with `export_video` and `background: true` is going.
struct ExportStatusTool: MCPTool {
    let name = "export_status"
    let description = """
        How an export started with export_video and background: true is going, at once: {jobId, status, project, \
        output, progress} with status "running" (progress from 0 to 1), "done" (with result: the file's path, \
        duration, size and chapters, as export_video gives it) or "failed" (with error: its code and message). Ask \
        again every few seconds until it is not running. Without jobId, every export of this server ({jobs: […]}). \
        The jobs live as long as the server.
        """
    var inputSchema: JSONValue {
        MCPSchema.object(["jobId": MCPSchema.string("What export_video with background: true answered.")])
    }
    var annotations: JSONValue? { MCPSchema.annotations("Check a Toma export", readOnly: true) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let arguments = try MCPArguments(arguments, tool: name, keys: ["jobId"])
        guard let id = try arguments.optionalString("jobId") else {
            return try .json(JobList(jobs: context.jobs.all))
        }
        guard let status = context.jobs.status(id) else {
            throw APIError(.refused, "there is no export \(id) in this server: its jobs end with it")
        }
        return try .json(status)
    }

    private struct JobList: Encodable {
        var jobs: [ExportJobs.Status]
    }
}
