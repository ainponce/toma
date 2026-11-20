// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import ProjectAPI

/// `toma validate <package>`: whether Toma reads the package whole (`ProjectRunner.validate`); exits with 1 if not.
struct ValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Check a project: that it opens, the rules of its document, its logs and the files it names.",
        discussion: "Exits with 0 for a valid project and 1 for one that is not, saying why. Writes nothing.")

    @Argument(help: "The .toma package.")
    var package: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let report: ValidationReport
        do {
            report = await ProjectRunner.validate(try CLI.package(package), environment: CLI.environment)
        } catch {
            report = ValidationReport(
                valid: false, formatVersion: nil, documentVersion: nil, problems: [error.description], skippedEventLines: 0,
                missingFiles: [])
        }
        output.emit(report, text: CLIOutput.validation)
        if !report.valid { throw ExitCode(1) }
    }
}
