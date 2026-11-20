// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import ProjectAPI

/// `toma markers <package>`: the markers the output shows, with their times and ids (`ProjectRunner.markers`).
struct MarkersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markers",
        abstract: "List the markers: their time in the output, their id and their name.",
        discussion: "With --json, the markers, the chapters and the chapters as YouTube lists them.")

    @Argument(help: "The .toma package.")
    var package: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let report = try await ProjectRunner.markers(try CLI.package(package), environment: CLI.environment)
        output.emit(report, text: CLIOutput.markers)
    }
}

/// `toma chapters <package>`: the chapters of the markers with a name (`chapters-1`), as the export writes them.
struct ChaptersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chapters",
        abstract: "List the chapters the export writes, from the markers with a name.",
        discussion: "With --youtube, as a YouTube description lists them: 00:00 Intro, one a line.")

    @Argument(help: "The .toma package.")
    var package: String

    @Flag(help: "Print them as YouTube's description lists them.")
    var youtube = false

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let report = try await ProjectRunner.markers(try CLI.package(package), environment: CLI.environment)
        output.emit(report) { CLIOutput.chapters($0, youTube: youtube) }
    }
}
