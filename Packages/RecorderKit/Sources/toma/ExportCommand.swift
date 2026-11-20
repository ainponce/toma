// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Dispatch
import Export
import Foundation
import ProjectAPI
import Synchronization

/// `toma export <package> <output>`: the project as it is on disk, exported as the app exports it
/// (`ProjectRunner.export`, plan 4b decision 12), never writing into the package. Progress goes to standard error as
/// `progress: <n> %`; Control-C cancels it and leaves nothing.
struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a project to a video or a GIF, as Toma exports it.",
        discussion: """
            Codecs: \(ExportRequest.codecs.keys.sorted().joined(separator: ", ")) (h264 and hevc write an .mp4; the \
            ProRes ones and hevc-alpha a .mov). Without an extension, the codec's is added; another one is an error. \
            --size is the shorter side of a video (720, 1080, 1440 or 2160; 1080 by default) and the longer side of a \
            GIF (800 by default); --fps is the project's by default, 15 for a GIF.
            """)

    @Argument(help: "The .toma package.")
    var package: String

    @Argument(help: "Where the file goes. Never inside a .toma package.")
    var destination: String

    @Option(help: "The video's codec: \(ExportRequest.codecs.keys.sorted().joined(separator: ", ")). h264 by default.")
    var codec: String?

    @Option(help: "The shorter side of a video, the longer side of a GIF, in pixels.")
    var size: Int?

    @Option(help: "Frames per second.")
    var fps: Int?

    @Option(help: "standard or high.")
    var quality = "standard"

    @Flag(help: "Export an animated GIF of the whole output.")
    var gif = false

    @OptionGroup var output: OutputOptions

    func validate() throws {
        if let codec {
            guard !gif else { throw ValidationError("A GIF has no codec: leave --codec out with --gif.") }
            guard ExportRequest.codecs[codec] != nil else {
                throw ValidationError("--codec is one of \(ExportRequest.codecs.keys.sorted().joined(separator: ", ")).")
            }
        }
        guard ExportRequest.qualities.contains(quality) else {
            throw ValidationError("--quality is one of \(ExportRequest.qualities.joined(separator: ", ")).")
        }
        let given = (destination as NSString).pathExtension
        let expected = expectedExtension
        if !given.isEmpty, given.lowercased() != expected {
            throw ValidationError("\(gif ? "A GIF" : "--codec \(codec ?? "h264")") is written as a .\(expected) file, not a .\(given) one.")
        }
    }

    /// The extension of the file the codec (or a GIF) writes.
    private var expectedExtension: String {
        gif ? "gif" : (ExportRequest.codecs[codec ?? "h264"] ?? .h264).fileExtension
    }

    func run() async throws {
        let url = try CLI.package(package)
        let target = try ProjectPaths.output(destination, relativeTo: CLI.workingDirectory)
        let request = ExportRequest(kind: gif ? .gif : .video, codec: codec ?? "h264", size: size, fps: fps, quality: quality)
        let progress = ProgressLine()
        let environment = CLI.environment
        let export = Task {
            try await ProjectRunner.export(url, to: target, request: request, environment: environment) { progress.report($0) }
        }
        let interruptions = Interruptions { export.cancel() }
        defer { interruptions.stop() }
        let result: ExportResult
        do {
            result = try await export.value
        } catch is CancellationError {
            throw APIError(.exportFailed, "the export was cancelled: nothing was written")
        }
        output.emit(result, text: CLIOutput.export)
        for warning in result.warnings { Terminal.error("warning: \(warning)") }
    }
}

/// `progress: <n> %` on standard error, each time the whole percent rises.
private final class ProgressLine: Sendable {
    private let last = Mutex(-1)

    func report(_ fraction: Double) {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        let rose = last.withLock { last in
            guard percent > last else { return false }
            last = percent
            return true
        }
        if rose { Terminal.error("progress: \(percent) %") }
    }
}

/// Control-C and a `kill` (SIGINT, SIGTERM) call `cancel` instead of ending the process, while it lives.
private final class Interruptions: Sendable {
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
