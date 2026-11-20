// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Dispatch
import Foundation
import ProjectAPI
import Sharing
import Synchronization

/// `toma share <package> [--list | --delete <id>] [--json]`: the project's video uploaded to the storage Toma ▸ Settings ▸
/// Share has (the secret key from the Keychain: the first time, macOS asks), and the link. `--list` the project's links,
/// `--delete <id>` one removed from the storage. Progress goes to standard error as `progress: <n> %`; Control-C cancels
/// and removes what was uploaded. Never writes into the package but its `shares.json`.
struct ShareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "share",
        abstract: "Upload a project's video to your own storage and print the link.",
        discussion: """
            Uses what Toma ▸ Settings ▸ Share has saved (the secret key is in the Keychain, where macOS asks the first \
            time) and exports the video as Toma's Share does: H.264, 1080p. Without Share set up it says so and does \
            nothing. --list prints the links of the project (it connects to nothing); --delete <id> removes one from \
            the storage and from the project.
            """)

    @Argument(help: "The .toma package.")
    var package: String

    @Flag(help: "List the project's links instead of sharing.")
    var list = false

    @Option(help: "Delete the link with this id from the storage and the project.")
    var delete: String?

    @OptionGroup var output: OutputOptions

    func validate() throws {
        if list, delete != nil { throw ValidationError("--list and --delete cannot be used together.") }
        if let delete, !ShareID.isValid(delete) {
            throw ValidationError("--delete takes a link's id: \(ShareID.length) letters and digits, as --list shows.")
        }
    }

    func run() async throws {
        try await Self.perform(self, setup: .live)
    }

    /// `run` with `setup`, which a test replaces.
    static func perform(_ command: ShareCommand, setup: ShareSetup) async throws {
        let url = try CLI.package(command.package)
        let output = command.output
        if command.list {
            let records = try ShareRun.list(package: url)
            if output.json {
                Terminal.out(CLIOutput.json(records.map(ShareOutput.init)))
            } else {
                Terminal.out(records.map { "\($0.id)  \($0.url)  \(ShareOutput.lifetime($0))" }.joined(separator: "\n"))
            }
            return
        }
        if let id = command.delete {
            try await ShareRun.delete(id: id, package: url, setup: setup)
            Terminal.out(output.json ? CLIOutput.json(Deleted(deleted: id)) : "Deleted \(id).")
            return
        }
        let progress = ShareProgressLine()
        let environment = CLI.environment
        let task = Task { @MainActor in
            try await ShareRun.share(package: url, setup: setup, environment: environment) { progress.report($0) }
        }
        let interruptions = ShareInterruptions { task.cancel() }
        defer { interruptions.stop() }
        let record: ShareRecord
        do {
            record = try await task.value
        } catch is CancellationError {
            throw APIError(.uploadFailed, "cancelled: what was uploaded was removed")
        }
        output.emit(record, text: { "\($0.url)\n\(ShareOutput.lifetime($0))" }, json: ShareOutput(record))
    }

    private struct Deleted: Encodable { var deleted: String }
}

extension OutputOptions {
    /// `emit` with the JSON of another value than the one the text is made of.
    func emit<T>(_ value: T, text: (T) -> String, json document: some Encodable) {
        Terminal.out(json ? CLIOutput.json(document) : text(value))
    }
}

/// `progress: <n> %` on standard error, each time the whole percent rises.
private final class ShareProgressLine: Sendable {
    private let last = Mutex(-1)

    func report(_ progress: ShareProgress) {
        let percent = Int((min(max(progress.fraction, 0), 1) * 100).rounded(.down))
        let rose = last.withLock { last in
            guard percent > last else { return false }
            last = percent
            return true
        }
        if rose { Terminal.error("progress: \(percent) %") }
    }
}

/// Control-C and a `kill` call `cancel` instead of ending the process, while it lives.
private final class ShareInterruptions: Sendable {
    private let sources: [any DispatchSourceSignal]

    init(_ cancel: @escaping @Sendable () -> Void) {
        sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: cancel)
            source.resume()
            return source
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
