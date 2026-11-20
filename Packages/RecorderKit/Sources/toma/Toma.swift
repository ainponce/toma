// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import ProjectAPI

/// The `toma` command: Toma's projects from the terminal. Milestone 4b adds the subcommands.
@main
struct Toma: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toma",
        abstract: "Works with Toma projects from the command line.",
        version: ProjectAPI.version,
        subcommands: [])
}
