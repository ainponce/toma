// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation
import ProjectAPI

/// `--json`, which every subcommand takes (plan 4b decision 11): the result as exactly one JSON document on standard
/// output, or `{"error": {"code", "message"}}`; without it, a text for a person. Progress always goes to standard error.
struct OutputOptions: ParsableArguments {
    @Flag(help: "Print the result as one JSON document, or {\"error\": {\"code\", \"message\"}}.")
    var json = false

    /// Writes `value` to standard output: its JSON with `--json`, `text(value)` otherwise.
    func emit<T: Encodable>(_ value: T, text: (T) -> String) {
        Terminal.out(json ? CLIOutput.json(value) : text(value))
    }
}

/// The places and the rules every subcommand shares.
enum CLI {
    /// The app's folders, each replaced by its `TOMA_*` variable when it is set (plan 4b decision 13).
    static var environment: APIEnvironment { .standard }

    static var workingDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// The package at `path`, from the working directory (`ProjectPaths.package`: `notAProject` otherwise).
    static func package(_ path: String) throws(APIError) -> URL {
        try ProjectPaths.package(path, relativeTo: workingDirectory)
    }

    /// The exit code of an `APIError` (plan 4b decision 11): 2 for a command that is not one, 3 for a project another
    /// process is editing, 1 for the rest.
    static func exitCode(_ code: APIErrorCode) -> Int32 {
        switch code {
        case .invalidCommand: 2
        case .locked: 3
        default: 1
        }
    }
}

/// Standard output and standard error, written at once (never held in a buffer): what a line says was done is out
/// before the next step starts, even if the process is killed then.
enum Terminal {
    static func out(_ text: String) {
        write(text, to: FileHandle.standardOutput)
    }

    static func error(_ text: String) {
        write(text, to: FileHandle.standardError)
    }

    private static func write(_ text: String, to handle: FileHandle) {
        guard !text.isEmpty else { return }
        let line = text.hasSuffix("\n") ? text : text + "\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
