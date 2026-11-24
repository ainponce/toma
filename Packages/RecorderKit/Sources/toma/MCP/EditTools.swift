// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat

/// `apply_commands{project, commands}`: the commands of §6.2, in order, each its own undo step
/// (`ProjectRunner.apply`, plan 4b decision 6). A list that stops at a command gives `isError` with the `BatchResult`:
/// the results of those before it, which stay done, the error and `failedIndex`.
struct ApplyCommandsTool: MCPTool {
    let name = "apply_commands"
    var description: String {
        """
        Edits a Toma project with the app's own commands, in order: each one is an undo step of its own, the same step \
        the gesture in Toma makes, saved before the next starts. Times are seconds of the output as it plays when the \
        command runs (after the ones before it): read them with project_info, get_transcript or get_markers. The list \
        stops at the first command that fails; those before it stay done, and the result says which ran (results), \
        which failed (failedIndex, from 0) and why (error). A command that leaves things as they were is no error \
        (changed: false). The commands: \(ProjectCommand.names.joined(separator: ", ")). While the project is open in \
        Toma, Toma makes them in its editor, where they show at once (via: app; transcribe and a background image from \
        outside the project are notAvailable then); fails with "locked" while another process edits the project. If \
        Toma does not answer in time (refused), it may still make them: read project_info before trying again.
        """
    }
    var inputSchema: JSONValue {
        var command = CommandSchema.inline.objectValue ?? [:]
        // A schema inside another is no document of its own.
        command["$schema"] = nil
        return MCPSchema.object(
            [
                "project": MCPSchema.project,
                "commands": .object([
                    "type": .string("array"), "minItems": .integer(1), "items": .object(command),
                    "description": .string("The commands, in order: each {\"command\": \"<name>\", …}."),
                ]),
            ], required: ["project", "commands"])
    }
    var annotations: JSONValue? { MCPSchema.annotations("Edit a Toma project", readOnly: false) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let arguments = try MCPArguments(arguments, tool: name, keys: ["project", "commands"])
        let url = try context.packageURL(try arguments.string("project"))
        let commands = try Self.commands(arguments.value("commands"))
        let environment = context.environment
        let batch = try await context.serialized(url) {
            await ProjectRunner.apply(commands, to: url, environment: environment)
        }
        var result = try MCPToolResult.json(batch)
        result.isError = batch.error != nil
        return result
    }

    /// The list of commands: an array of them, or (as some clients send it) the JSON text of one.
    private static func commands(_ value: JSONValue?) throws(APIError) -> [ProjectCommand] {
        let commands: [ProjectCommand]
        switch value {
        case nil:
            throw APIError(.invalidCommand, "apply_commands needs the argument “commands”")
        case let .array(items)?:
            var list: [ProjectCommand] = []
            for (k, item) in items.enumerated() {
                do throws(APIError) { list.append(try ProjectCommand(json: item)) } catch {
                    throw APIError(error.code, "command \(k) (from 0): \(error.message)")
                }
            }
            commands = list
        case let .string(text)?:
            commands = try ProjectCommand.list(from: Data(text.utf8))
        default:
            throw APIError(.invalidCommand, "apply_commands: “commands” is a list of commands")
        }
        guard !commands.isEmpty else { throw APIError(.invalidCommand, "apply_commands: the list has no commands") }
        return commands
    }
}

/// `undo{project}`: `ProjectRunner.undo`, the project's last step, also one the app made.
struct UndoTool: MCPTool {
    let name = "undo"
    let description = """
        Undoes the project's last edit step, as Edit ▸ Undo in Toma: also a step the app or an earlier call made. The \
        result names the step undone (label) and the one an undo would undo next. Refused with nothing to undo.
        """
    var inputSchema: JSONValue { MCPSchema.object(["project": MCPSchema.project], required: ["project"]) }
    var annotations: JSONValue? { MCPSchema.annotations("Undo in a Toma project", readOnly: false) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let url = try context.packageURL(try MCPArguments(arguments, tool: name, keys: ["project"]).string("project"))
        let environment = context.environment
        return try .json(try await context.serialized(url) { try await ProjectRunner.undo(url, environment: environment) })
    }
}

/// `redo{project}`: `ProjectRunner.redo`, the step last undone.
struct RedoTool: MCPTool {
    let name = "redo"
    let description = """
        Redoes the step last undone, as Edit ▸ Redo in Toma. Refused with nothing to redo (a new edit after an undo \
        leaves nothing to redo).
        """
    var inputSchema: JSONValue { MCPSchema.object(["project": MCPSchema.project], required: ["project"]) }
    var annotations: JSONValue? { MCPSchema.annotations("Redo in a Toma project", readOnly: false) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let url = try context.packageURL(try MCPArguments(arguments, tool: name, keys: ["project"]).string("project"))
        let environment = context.environment
        return try .json(try await context.serialized(url) { try await ProjectRunner.redo(url, environment: environment) })
    }
}
