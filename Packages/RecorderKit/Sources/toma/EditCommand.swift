// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation
import ProjectAPI

/// `toma edit <package> '<json>'` or `--file <commands.json>`: the project changed with the app's own commands
/// (`ProjectRunner.apply`), each its own undo step, in order, stopping at the first that fails.
struct EditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Change a project with a command, or with a list of commands from a file.",
        discussion: """
            A command is a JSON object, {"command": "<name>", …}, its times in seconds of the output: \
            \(ProjectCommand.names.joined(separator: ", ")). docs/format/schema/edit-command.schema.json describes \
            them. Each one is a step of its own, which toma undo undoes. A list runs in order and stops at the first \
            that fails; what was done before it stays. Without --json, a line is printed as each command is done and saved.
            """)

    @Argument(help: "The .toma package.")
    var package: String

    @Argument(help: #"A command as JSON, for example '{"command":"setAspect","aspect":"9:16"}'."#)
    var command: String?

    @Option(help: "A file with a JSON list of commands (or one command), applied in order; - reads standard input.")
    var file: String?

    @OptionGroup var output: OutputOptions

    func validate() throws {
        if (command == nil) == (file == nil) {
            throw ValidationError("Give one command as JSON, or --file with a list of them.")
        }
    }

    func run() async throws {
        let url = try CLI.package(package)
        let commands = try ProjectCommand.list(from: try input())
        guard !commands.isEmpty else { throw APIError(.invalidCommand, "the list has no commands") }
        let json = output.json
        let batch = await ProjectRunner.apply(commands, to: url, environment: CLI.environment) { _, result in
            if !json { Terminal.out(CLIOutput.command(result)) }
        }
        if json { Terminal.out(CLIOutput.json(batch)) }
        guard let error = batch.error else { return }
        if json { throw ExitCode(CLI.exitCode(error.code)) }
        if let index = batch.failedIndex, commands.count > 1 {
            throw APIError(error.code, "command \(index + 1) (\(commands[index].name)): \(error.message)")
        }
        throw error
    }

    /// The command given, or the file's (standard input's for `-`).
    private func input() throws -> Data {
        if let command { return Data(command.utf8) }
        guard let file else { return Data() }
        if file == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
        let url = URL(fileURLWithPath: file, relativeTo: CLI.workingDirectory)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw APIError(.invalidCommand, "the file \(url.path) cannot be read")
        }
    }
}

/// `toma undo <package>`: undoes the project's last step, also one the app made.
struct UndoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo", abstract: "Undo the project's last step, as Edit ▸ Undo does in Toma.")

    @Argument(help: "The .toma package.")
    var package: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let result = try await ProjectRunner.undo(try CLI.package(package), environment: CLI.environment)
        output.emit(result, text: CLIOutput.command)
    }
}

/// `toma redo <package>`: redoes the step last undone.
struct RedoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "redo", abstract: "Redo the step last undone, as Edit ▸ Redo does in Toma.")

    @Argument(help: "The .toma package.")
    var package: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let result = try await ProjectRunner.redo(try CLI.package(package), environment: CLI.environment)
        output.emit(result, text: CLIOutput.command)
    }
}
