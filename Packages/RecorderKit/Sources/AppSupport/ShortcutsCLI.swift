// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Synchronization

/// A shortcut of the user's Shortcuts app.
public struct ShortcutInfo: Equatable, Sendable {
    public var name: String
    /// What runs it: it stays the same when the user renames the shortcut.
    public var identifier: String

    public init(name: String, identifier: String) {
        self.name = name
        self.identifier = identifier
    }
}

/// Runs the user's shortcuts: `ShortcutsCLI` in the app, a fake in tests.
public protocol ShortcutRunning: Sendable {
    /// Runs the shortcut with `input` as its input, and returns its output without the spaces and line breaks around
    /// it ("" when it has none).
    func run(shortcut identifier: String, input: String) async throws -> String
    /// The user's shortcuts, as Shortcuts lists them.
    func list() async throws -> [ShortcutInfo]
}

public enum ShortcutsCLIError: Error, Equatable {
    /// The command did not end within its time limit (a dialog of Shortcuts would keep it waiting forever): it was
    /// terminated.
    case timedOut
    /// The command ended with `status` (or the signal that ended it); `message` is what it said on its standard error.
    case failed(status: Int32, message: String)
}

/// `shortcuts`, the command line of the Shortcuts app. Every command runs to its end or to `timeLimit`, also when the
/// task that waits for it is cancelled: a shortcut stopped halfway would leave Do Not Disturb as nobody knows.
public struct ShortcutsCLI: ShortcutRunning {
    /// A command still running this long after it was terminated is killed.
    private static let killDelay = Duration.seconds(1)

    private let executable: URL
    private let timeLimit: Duration

    public init(executable: URL = URL(filePath: "/usr/bin/shortcuts"), timeLimit: Duration = .seconds(5)) {
        self.executable = executable
        self.timeLimit = timeLimit
    }

    /// `shortcuts run <identifier> --input-path <a file with input> --output-path <a file>`: the shortcut answers in
    /// the output file. Its standard output goes nowhere.
    public func run(shortcut identifier: String, input: String) async throws -> String {
        try await withScratchFolder { folder in
            let inputURL = folder.appending(path: "input.txt")
            let outputURL = folder.appending(path: "output.txt")
            try Data(input.utf8).write(to: inputURL)
            try await execute(
                ["run", identifier, "--input-path", inputURL.path, "--output-path", outputURL.path], output: .nullDevice, in: folder)
            // No file: the shortcut answered nothing.
            let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// `shortcuts list --show-identifiers`.
    public func list() async throws -> [ShortcutInfo] {
        try await withScratchFolder { folder in
            // A file rather than a pipe: a long list never fills it and blocks the command.
            let listURL = folder.appending(path: "list.txt")
            let output = try FileHandle.creatingFile(at: listURL)
            defer { try? output.close() }
            try await execute(["list", "--show-identifiers"], output: output, in: folder)
            return Self.shortcuts(listed: try String(contentsOf: listURL, encoding: .utf8))
        }
    }

    /// What `shortcuts list --show-identifiers` printed: one shortcut a line, `<name> (<identifier>)`. A name may have
    /// parentheses of its own; lines of any other form are left out.
    static func shortcuts(listed: String) -> [ShortcutInfo] {
        listed.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) else { return nil }
            let name = String(line[..<open.lowerBound])
            let identifier = String(line[open.upperBound..<line.index(before: line.endIndex)])
            guard !name.isEmpty, !identifier.isEmpty else { return nil }
            return ShortcutInfo(name: name, identifier: identifier)
        }
    }

    /// Runs the command with `arguments`, its standard output to `output` and its standard error to a file in `folder`,
    /// and returns once it has exited with status 0. At `timeLimit` it is terminated (and killed if it is still running
    /// `killDelay` later), and this throws `timedOut` once it has exited: it is always waited for, so it never outlives
    /// the call.
    private func execute(_ arguments: [String], output: FileHandle, in folder: URL) async throws {
        let errorsURL = folder.appending(path: "errors.txt")
        let errors = try FileHandle.creatingFile(at: errorsURL)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let exit = ProcessExit()
        process.terminationHandler = { exit.finish(status: $0.terminationStatus, reason: $0.terminationReason) }
        try process.run()
        // Not a child task: the caller's cancellation does not cut the command short.
        let watchdog = Task { [timeLimit] in
            // Cancelled once the command has exited.
            guard (try? await Task.sleep(for: timeLimit)) != nil, exit.markTimedOut() else { return }
            process.terminate()
            guard (try? await Task.sleep(for: Self.killDelay)) != nil, !exit.hasExited else { return }
            kill(process.processIdentifier, SIGKILL)
        }
        let ended = await exit.wait()
        watchdog.cancel()
        if ended.timedOut { throw ShortcutsCLIError.timedOut }
        guard ended.reason == .exit, ended.status == 0 else {
            let message = (try? String(contentsOf: errorsURL, encoding: .utf8)) ?? ""
            throw ShortcutsCLIError.failed(status: ended.status, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// A new folder for the files of one command, removed with them once `body` returns.
    private func withScratchFolder<T>(_ body: (URL) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Shortcuts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await body(folder)
    }
}

extension FileHandle {
    /// A new empty file at `url`, open for writing.
    fileprivate static func creatingFile(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try FileHandle(forWritingTo: url)
    }
}

/// How a command ended, told by its termination handler to whoever waits for it.
private final class ProcessExit: Sendable {
    struct Ended {
        var status: Int32
        var reason: Process.TerminationReason
        /// It was terminated at the time limit.
        var timedOut: Bool
    }

    private struct State {
        var ended: Ended?
        var timedOut = false
        var waiting: [CheckedContinuation<Ended, Never>] = []
    }

    private let state = Mutex(State())

    var hasExited: Bool { state.withLock { $0.ended != nil } }

    func finish(status: Int32, reason: Process.TerminationReason) {
        let (ended, waiting) = state.withLock { state in
            let ended = Ended(status: status, reason: reason, timedOut: state.timedOut)
            state.ended = ended
            defer { state.waiting = [] }
            return (ended, state.waiting)
        }
        for continuation in waiting { continuation.resume(returning: ended) }
    }

    /// The command reached its time limit: `true` unless it has exited already.
    func markTimedOut() -> Bool {
        state.withLock { state in
            guard state.ended == nil else { return false }
            state.timedOut = true
            return true
        }
    }

    /// Returns once the command has exited; a cancellation does not end the wait.
    func wait() async -> Ended {
        await withCheckedContinuation { continuation in
            let ended = state.withLock { state in
                if state.ended == nil { state.waiting.append(continuation) }
                return state.ended
            }
            if let ended { continuation.resume(returning: ended) }
        }
    }
}
