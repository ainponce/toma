// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat

/// `list_projects{folder?}`: the packages of the library (`~/Movies/Toma`, or `TOMA_PROJECTS_FOLDER`) or of a folder,
/// as `toma` lists them (`ProjectRunner.listProjects`): up to 4 folders down, never through a link nor into `Trash/`.
struct ListProjectsTool: MCPTool {
    let name = "list_projects"
    let description = """
        Lists the Toma projects (.toma packages) in Toma's library (~/Movies/Toma) or in the folder given, up to 4 folders \
        down: each one's path, name, duration in seconds, document version and when it last changed, or the problem \
        that keeps it from opening. Give a path from here to the other tools.
        """
    var inputSchema: JSONValue {
        MCPSchema.object([
            "folder": MCPSchema.string(
                "A folder to look in instead of the library: an absolute path (~ is the home folder), or one from the "
                    + "server's working directory.")
        ])
    }
    var annotations: JSONValue? { MCPSchema.annotations("List Toma projects", readOnly: true) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let arguments = try MCPArguments(arguments, tool: name, keys: ["folder"])
        let folder = try arguments.optionalString("folder").map { path throws(APIError) in
            try Self.folder(path, relativeTo: context.workingDirectory)
        }
        let environment = context.environment
        let projects = try await ProjectRunner.listProjects(in: folder, environment: environment)
        return try .json(Listing(folder: (folder ?? environment.projectsFolder).path, projects: projects))
    }

    private struct Listing: Encodable {
        var folder: String
        var projects: [ProjectListing]
    }

    /// `path` from `cwd`, without `.` components; `refused` with a `..` (`ProjectPaths`' rules).
    private static func folder(_ path: String, relativeTo cwd: URL) throws(APIError) -> URL {
        guard !path.isEmpty else { throw APIError(.refused, "no folder was given") }
        let expanded = (path as NSString).expandingTildeInPath
        let components = expanded.split(separator: "/").map(String.init)
        if components.contains("..") { throw APIError(.refused, "\(path): a path with “..” is refused") }
        let base = expanded.hasPrefix("/") ? [] : cwd.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let parts = base + components.filter { $0 != "." }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: true)
    }
}

/// `project_info{project}`: what `toma info` says (`ProjectRunner.report`).
struct ProjectInfoTool: MCPTool {
    let name = "project_info"
    let description = """
        Describes a Toma project as it is on disk: title and summary, duration and frame rate, aspect, the takes and \
        their tracks, the sequence of clips, markers and chapters, zoom (automatic and blocks, with ids), style, camera, \
        music and whether it has a transcript. Times are seconds of the output as it plays now (and nanoseconds of the \
        recording). Never changes the project.
        """
    var inputSchema: JSONValue { MCPSchema.object(["project": MCPSchema.project], required: ["project"]) }
    var annotations: JSONValue? { MCPSchema.annotations("Describe a Toma project", readOnly: true) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let url = try context.packageURL(try MCPArguments(arguments, tool: name, keys: ["project"]).string("project"))
        let environment = context.environment
        return try .json(try await context.serialized(url) { try await ProjectRunner.report(url, environment: environment) })
    }
}

/// `get_transcript{project}`: what `toma transcript --json` says (`ProjectRunner.transcript`); `refused` without one.
struct GetTranscriptTool: MCPTool {
    let name = "get_transcript"
    let description = """
        The project's transcript: its language, the text the output says, and every word of the takes with its start \
        and end in seconds of the output (none, and "cut": true, for a word the edits leave out). A project without a \
        transcript is refused: make one with apply_commands and {"command": "transcribe"}.
        """
    var inputSchema: JSONValue { MCPSchema.object(["project": MCPSchema.project], required: ["project"]) }
    var annotations: JSONValue? { MCPSchema.annotations("Read a Toma project's transcript", readOnly: true) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let url = try context.packageURL(try MCPArguments(arguments, tool: name, keys: ["project"]).string("project"))
        let environment = context.environment
        let report = try await context.serialized(url) { try await ProjectRunner.transcript(url, environment: environment) }
        guard let report else {
            throw APIError(
                .refused, #"the project has no transcript: make one with apply_commands and {"command": "transcribe"}"#)
        }
        return try .json(report)
    }
}

/// `get_markers{project}`: what `toma markers --json` says (`ProjectRunner.markers`).
struct GetMarkersTool: MCPTool {
    let name = "get_markers"
    let description = """
        The project's markers (id, name, time in seconds of the output, and where they come from) and the chapters the \
        markers with a name make in an exported video, with the chapters as YouTube description lines.
        """
    var inputSchema: JSONValue { MCPSchema.object(["project": MCPSchema.project], required: ["project"]) }
    var annotations: JSONValue? { MCPSchema.annotations("Read a Toma project's markers", readOnly: true) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let url = try context.packageURL(try MCPArguments(arguments, tool: name, keys: ["project"]).string("project"))
        let environment = context.environment
        let report = try await context.serialized(url) { try await ProjectRunner.markers(url, environment: environment) }
        return try .json(report)
    }
}
