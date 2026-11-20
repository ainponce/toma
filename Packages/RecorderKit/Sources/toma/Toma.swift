// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Darwin
import Foundation
import ProjectAPI

/// The `toma` command: Toma's projects from the terminal (fases 4 y 5 design §6.2). Exit codes (plan 4b decision 11):
/// 0 done; 2 a usage error (what ArgumentParser gives as 64) or a command that is not one (`invalidCommand`); 3 a
/// project another process is editing (`locked`); 1 the rest. Standard output carries only the result: with `--json`,
/// exactly one JSON document, the result or `{"error": {"code", "message"}}`.
@main
struct Toma: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toma",
        abstract: "Work with Toma projects from the command line.",
        discussion: """
            Exit codes: 0 done; 1 an error; 2 a usage error or a command that is not one (invalidCommand); 3 the \
            project is being edited by another app (locked). With --json, standard output is one JSON document: the \
            result, or {"error": {"code", "message"}}. docs/automation.md tells more.
            """,
        version: ProjectAPI.version,
        // Only ever appended to (milestones 5a and 5b add theirs at the end).
        subcommands: [
            InfoCommand.self,
            ValidateCommand.self,
            TranscriptCommand.self,
            MarkersCommand.self,
            ChaptersCommand.self,
            EditCommand.self,
            UndoCommand.self,
            RedoCommand.self,
            ExportCommand.self,
            MCPCommand.self,
            ShareCommand.self,
        ])

    static func main() async {
        let status = await run(Array(CommandLine.arguments.dropFirst()))
        Darwin.exit(status)
    }

    /// Parses and runs `arguments`, says what went wrong, and gives the exit code.
    static func run(_ arguments: [String]) async -> Int32 {
        // Known before parsing, so a usage error is JSON too.
        let json = arguments.contains("--json")
        do {
            var command = try parseAsRoot(arguments)
            if var command = command as? any AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
            return 0
        } catch {
            return finish(error, json: json)
        }
    }

    /// Says `error` where it goes and gives its exit code.
    private static func finish(_ error: any Error, json: Bool) -> Int32 {
        switch error {
        case let error as APIError:
            if json { Terminal.out(CLIOutput.json(error: error)) } else { Terminal.error("error: \(error.description)") }
            return CLI.exitCode(error.code)
        case let exit as ExitCode:
            // The command said what it had to already.
            return exit.rawValue
        case is CancellationError:
            let error = APIError(.refused, "cancelled")
            if json { Terminal.out(CLIOutput.json(error: error)) } else { Terminal.error("error: \(error.description)") }
            return 1
        default:
            let code = exitCode(for: error)
            if code == .success {
                // --help and --version.
                Terminal.out(fullMessage(for: error))
                return 0
            }
            let usage = code == .validationFailure
            if json {
                Terminal.out(CLIOutput.json(error: APIError(usage ? .invalidCommand : .refused, message(for: error))))
            } else {
                Terminal.error(fullMessage(for: error))
            }
            return usage ? 2 : 1
        }
    }
}
