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

/// `get_transcript{project, from?, to?, words?}`: the transcript (`ProjectRunner.transcript`) in parts an agent's tool
/// result holds (`TranscriptPage`): segments by default, every word with `words: true`; `refused` without one.
struct GetTranscriptTool: MCPTool {
    let name = "get_transcript"
    let description = """
        The project's transcript as the output says it: {language, duration, from, to, nextFrom?, segments} where each \
        segment is a sentence (or the words between two pauses) with its start and end in seconds of the output; with \
        words: true, {…, words} with every word and its own start and end instead (for exact cuts). Words the edits \
        cut out are left out. A long transcript comes in parts: from and to (seconds of the output) ask for a part, and \
        when a part runs out of room before to, nextFrom says where to ask again (duration is the whole output's). A \
        project without a transcript is refused: make one with apply_commands and {"command": "transcribe"}.
        """
    var inputSchema: JSONValue {
        MCPSchema.object(
            [
                "project": MCPSchema.project,
                "from": MCPSchema.number("Seconds of the output where the part starts: 0 by default.", minimum: 0),
                "to": MCPSchema.number("Seconds of the output where the part ends: the end by default.", minimum: 0),
                "words": MCPSchema.boolean("Every word with its times instead of sentences: bigger, for exact cuts."),
            ], required: ["project"])
    }
    var annotations: JSONValue? { MCPSchema.annotations("Read a Toma project's transcript", readOnly: true) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let arguments = try MCPArguments(arguments, tool: name, keys: ["project", "from", "to", "words"])
        let url = try context.packageURL(try arguments.string("project"))
        let from = try arguments.optionalNumber("from"), to = try arguments.optionalNumber("to")
        let words = try arguments.optionalBool("words") ?? false
        let environment = context.environment
        let report = try await context.serialized(url) { try await ProjectRunner.transcript(url, environment: environment) }
        guard let report else {
            throw APIError(
                .refused, #"the project has no transcript: make one with apply_commands and {"command": "transcribe"}"#)
        }
        return try .json(try TranscriptPage.make(report, from: from, to: to, words: words))
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
