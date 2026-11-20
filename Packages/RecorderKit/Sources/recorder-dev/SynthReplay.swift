// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import ArgumentParser
import Darwin
import Editing
import Foundation
import ProjectFormat
import Recording
import SyntheticCapture

/// `--save-at`'s seconds, comma-separated, each finite and not negative, in increasing order.
struct SaveSeconds: ExpressibleByArgument {
    var seconds: [Double]

    init?(argument: String) {
        let parsed = argument.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? false }) else { return nil }
        seconds = parsed.compactMap { $0 }.sorted()
    }
}

/// The context a save needs, as `export` and `edit-check` build it.
private func replayEditContext() -> EditContext {
    EditContext(
        app: AppInfo(name: "recorder-dev", version: "dev"), cachesRoot: FileManager.default.temporaryDirectory,
        defaultStyle: .toma, now: { Date() },
        makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) })
}

struct SynthReplay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "synth-replay",
        abstract: "Runs the Replay's ring on synthetic sources, saves it at the given seconds, then discards it. Needs no permission.",
        discussion: """
            Starts a ReplayCoordinator in <scratch-root> (current.toma inside) and prints "scratch: <path>" as the \
            first line once it records, with the sources of synth-record (one display, the microphone, and with \
            --camera and --system-audio those too) and its synthetic input. At each --save-at second after the \
            start it saves the last --seconds as a new project in --library and prints "saved: <path> <seconds>". \
            After --duration seconds it prints, with --report-disk, "on disk: <track> <seconds>" for each track (the \
            seconds of media its segment files hold in the ring) and ends with stopAndDiscard, which leaves no \
            current.toma. A kill -9 leaves it, for replay-cleanup.
            """
    )

    @Argument(help: "Folder for the working package (current.toma). Created if needed.")
    var scratchRoot: String

    @Option(help: "Folder the saved projects go in. Created if needed.")
    var library: String

    @Option(help: "Seconds to run.")
    var duration: Double

    @Option(help: "N: the seconds a save keeps.")
    var seconds: Int

    @Option(help: "Seconds of a segment, and of an event file.")
    var segment: Double = 10

    @Flag(help: "Also record a synthetic camera, 1280×720 at 30 fps.")
    var camera = false

    @Flag(help: "Also record synthetic system audio, stereo at 48 kHz.")
    var systemAudio = false

    @Option(help: "Save at these seconds after the start, comma-separated (15,40).")
    var saveAt: SaveSeconds?

    @Flag(help: "At the end, print the seconds of media each track holds on disk.")
    var reportDisk = false

    func validate() throws {
        guard duration > 0 else { throw ValidationError("--duration must be positive.") }
        guard seconds > 0 else { throw ValidationError("--seconds must be positive.") }
        guard segment > 0 else { throw ValidationError("--segment must be positive.") }
    }

    func run() async throws {
        let root = URL(fileURLWithPath: scratchRoot, isDirectory: true)
        let projects = URL(fileURLWithPath: library, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        var sources: [any CaptureSource] = [
            SyntheticVideoSource(
                trackID: "display-1", displayID: 1, globalOrigin: [0, 0], width: 640, height: 360, framesPerSecond: 30)
        ]
        if camera {
            sources.append(SyntheticVideoSource(
                trackID: "camera", kind: .camera, width: 1280, height: 720, framesPerSecond: 30))
        }
        sources.append(SyntheticAudioSource())
        if systemAudio {
            sources.append(SyntheticAudioSource(trackID: "system-audio", kind: .systemAudio, channels: 2, clockSkewPPM: -1500))
        }
        let coordinator = ReplayCoordinator(
            scratchRoot: root, app: AppInfo(name: "recorder-dev", version: "dev"), sources: sources,
            input: SyntheticInputRecorder(), diskMonitor: DiskSpaceMonitor(volumeURL: root),
            configuration: ReplayConfiguration(seconds: seconds, segmentDuration: .seconds(segment)))
        let package = try await coordinator.start()
        print("scratch: \(package.url.path)")
        fflush(stdout)
        let printer = Task {
            for await warning in coordinator.warnings { print("warning: \(warning)"); fflush(stdout) }
        }
        let started = ContinuousClock.now
        let seconds = seconds
        let context = replayEditContext()
        var failed = false
        for (n, second) in (saveAt?.seconds ?? []).enumerated() where second < duration {
            try? await Task.sleep(until: started + .seconds(second), clock: .continuous)
            do {
                let result = try await ReplaySaver.save(
                    from: coordinator,
                    ReplaySaveRequest(seconds: seconds, projectsFolder: projects, name: "Replay \(n + 1)", context: context))
                let parts = result.duration.components
                let length = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                print("saved: \(result.projectURL.path) \(String(format: "%.2f", length))")
            } catch {
                printError("error: cannot save the replay at \(second) s: \(error)")
                failed = true
            }
            fflush(stdout)
        }
        try? await Task.sleep(until: started + .seconds(duration), clock: .continuous)
        if reportDisk {
            for (track, length) in await Self.mediaOnDisk(of: package) {
                print("on disk: \(track) \(String(format: "%.2f", length))")
            }
            fflush(stdout)
        }
        await coordinator.stopAndDiscard()
        await printer.value
        if failed { throw ExitCode.failure }
    }

    /// Per track, the seconds of media of the segment files in the working package (the open segment, as far as it is
    /// readable), by track ID.
    static func mediaOnDisk(of package: ProjectPackage) async -> [(String, Double)] {
        let take = package.takeDirectory(ReplayScratch.takeID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: take.path))?.sorted() ?? []
        var result: [(String, Double)] = []
        for name in names {
            let directory = take.appending(path: name, directoryHint: .isDirectory)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasPrefix("seg-") }.sorted()
            guard !files.isEmpty else { continue }
            var total = 0.0
            for file in files {
                let asset = AVURLAsset(url: directory.appending(path: file))
                if let time = try? await asset.load(.duration), time.isNumeric { total += time.seconds }
            }
            result.append((name, total))
        }
        return result
    }
}

struct ReplayCleanup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replay-cleanup",
        abstract: "What the app does when it opens: deletes the Replay's leftover working package and the saves cut short.",
        discussion: """
            ReplayScratch.discardLeftovers on <scratch-root> and ReplaySaver.removeAbandonedSaves on --library. \
            Prints "removed: <path>" for each thing it removes.
            """
    )

    @Argument(help: "Folder of the working package.")
    var scratchRoot: String

    @Option(help: "The projects folder.")
    var library: String

    func run() throws {
        let removed = ReplayScratch.discardLeftovers(in: URL(fileURLWithPath: scratchRoot, isDirectory: true))
            + ReplaySaver.removeAbandonedSaves(in: URL(fileURLWithPath: library, isDirectory: true))
        for url in removed { print("removed: \(url.path)") }
    }
}
