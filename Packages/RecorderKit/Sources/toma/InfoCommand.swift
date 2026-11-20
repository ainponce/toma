// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import ProjectAPI

/// `toma info <package>`: what the project is (`ProjectRunner.report`), read without writing anything.
struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Describe a project: its takes, sequence, markers, chapters, zoom, look and transcript.",
        discussion: "Times are seconds of the output as it plays now. Reading never changes the project.")

    @Argument(help: "The .toma package.")
    var package: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let report = try await ProjectRunner.report(try CLI.package(package), environment: CLI.environment)
        output.emit(report, text: CLIOutput.info)
    }
}
