// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import ProjectAPI

/// `toma transcript <package>`: the words the output says (`ProjectRunner.transcript`); with `--json`, every word with
/// its times. A project without a transcript is `refused`.
struct TranscriptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript",
        abstract: "Print the transcript: the words the output says, in order.",
        discussion: "With --json, every word of every take with its times, and whether a cut leaves it out.")

    @Argument(help: "The .toma package.")
    var package: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        guard let report = try await ProjectRunner.transcript(try CLI.package(package), environment: CLI.environment) else {
            throw APIError(.refused, #"the project has no transcript: make one with toma edit <package> '{"command":"transcribe"}'"#)
        }
        output.emit(report, text: CLIOutput.transcript)
    }
}
