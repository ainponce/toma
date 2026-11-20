// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import LocalAI
import ProjectAPI
import ProjectFormat

/// `suggest_chapters{project}`: what `toma ai chapters --json` says (plan 5b, Task I4). It only proposes: the result's
/// `commands` are the `addMarker`s for `apply_commands`, which the agent sends once it has looked at the chapters.
struct SuggestChaptersTool: MCPTool {
    let name = "suggest_chapters"
    let description = """
        Proposes chapters for a project with the on-device model (Apple Intelligence, macOS 26): each with its time in \
        seconds of the output and a short title in the transcript's language, plus `commands`, the addMarker commands \
        that would add them. It never edits the project: review the chapters and pass the commands to apply_commands. \
        Needs a transcript (make one with apply_commands and {"command": "transcribe"}) and can take about 30 seconds \
        for a long video; it sends progress when the call has a progressToken. Without the model, the error code is \
        notAvailable and the message says why.
        """
    var inputSchema: JSONValue { MCPSchema.object(["project": MCPSchema.project], required: ["project"]) }
    var annotations: JSONValue? { MCPSchema.annotations("Suggest chapters for a Toma project", readOnly: true) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let url = try context.packageURL(try MCPArguments(arguments, tool: name, keys: ["project"]).string("project"))
        let environment = context.environment
        let report = context.progress
        let result = try await context.serialized(url) {
            try await AISuggestionRun.chapters(
                project: url, transcribe: false, environment: environment, transcriptHint: AISuggestionRun.Hint.mcp
            ) { progress in
                report?(Double(progress.part - 1) / Double(max(progress.parts, 1)), "part \(progress.part) of \(progress.parts)")
            }
        }
        return try .json(result)
    }
}
