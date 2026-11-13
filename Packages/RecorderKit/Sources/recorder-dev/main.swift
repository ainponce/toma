// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import CoreGraphics
import Darwin
import Foundation
import ProjectFormat
import Recording
import Recovery
import SyntheticCapture

/// Development tool: records, recovers and verifies takes from the command line, for the crash and
/// endurance scripts in `scripts/`.
struct RecorderDev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recorder-dev",
        abstract: "Records, recovers and verifies Toma takes from the command line.",
        subcommands: [SynthRecord.self, Record.self, Recover.self, Verify.self]
    )
}

// MARK: - Recording

struct SynthRecord: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "synth-record",
        abstract: "Records a take from a synthetic display and microphone. Needs no permission.",
        discussion: """
            Creates <directory>/synth-<date>-<time>.toma and prints its absolute path as the first line \
            once recording has started. Warnings follow as "warning: …" lines, and a summary of the take \
            once it is closed.
            """
    )

    @Argument(help: "Folder for the new package. Created if needed.")
    var directory: String

    @Option(help: "Seconds to record.")
    var duration: Double

    @Option(help: "Frames per second of the synthetic display.")
    var fps = 30

    @Option(help: "Width of the synthetic display, in pixels.")
    var width = 640

    @Option(help: "Height of the synthetic display, in pixels.")
    var height = 360

    @Option(help: "Seconds after which the synthetic screen stops changing; heartbeats keep its track going.")
    var staticAfter: Double?

    func validate() throws {
        guard duration > 0 else { throw ValidationError("--duration must be positive.") }
        guard fps > 0, width > 0, height > 0 else { throw ValidationError("--fps, --width and --height must be positive.") }
        if let staticAfter, staticAfter < 0 { throw ValidationError("--static-after cannot be negative.") }
    }

    func run() async throws {
        let display = SyntheticVideoSource(width: width, height: height, framesPerSecond: fps)
        let staticAfter = staticAfter
        try await recordTake(
            in: directory, prefix: "synth", duration: duration,
            sources: [display, SyntheticAudioSource()], input: NoInputRecorder(),
            systemActivity: AsyncStream { $0.finish() },
            whileRecording: {
                guard let staticAfter else { return }
                do {
                    try await Task.sleep(for: .seconds(staticAfter))
                } catch {
                    return  // the take ended first
                }
                display.pauseFrames(true)
            })
    }
}

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Records the main display and the default microphone.",
        discussion: """
            Needs Screen Recording and Microphone permission for the terminal that runs it. Creates \
            <directory>/record-<date>-<time>.toma and prints its absolute path as the first line once \
            recording has started, like synth-record. Sleep and screen lock pause the take, as in the app.

            The cursor is sampled at 120 Hz, but clicks may be missing: a command-line tool has no \
            NSApplication, and the mouse-button monitors may not deliver there.
            """
    )

    @Argument(help: "Folder for the new package. Created if needed.")
    var directory: String

    @Option(help: "Seconds to record.")
    var duration: Double

    func validate() throws {
        guard duration > 0 else { throw ValidationError("--duration must be positive.") }
    }

    func run() async throws {
        // On the main thread the display gets its user-visible name.
        let display = await MainActor.run { DisplayCaptureSource(displayID: CGMainDisplayID(), framesPerSecond: 60) }
        try await recordTake(
            in: directory, prefix: "record", duration: duration,
            sources: [display, MicrophoneCaptureSource(preferredDeviceUniqueID: nil)], input: CursorRecorder(),
            systemActivity: SystemActivityMonitor.live())
    }
}

/// Creates a package in `directory` and records one take into it for `duration` seconds, or until the
/// take stops by itself because the disk is full. Prints the package's absolute path as the first line
/// once recording has started, then the take's warnings, then a summary of the closed take.
private func recordTake(
    in directory: String,
    prefix: String,
    duration: Double,
    sources: [any CaptureSource],
    input: any InputRecorder,
    systemActivity: AsyncStream<SystemActivity>,
    whileRecording: @escaping @Sendable () async -> Void = {}
) async throws {
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let package = try createPackage(in: folder, prefix: prefix)
    let coordinator = RecordingCoordinator(
        package: package, sources: sources, input: input,
        diskMonitor: DiskSpaceMonitor(volumeURL: folder), systemActivity: systemActivity)
    _ = try await coordinator.start()
    print(package.url.path)
    fflush(stdout)

    // Whichever comes first: `duration` passes, or the take closes by itself and its warnings end.
    let (ended, endedContinuation) = AsyncStream.makeStream(of: Void.self)
    let printer = Task {
        for await warning in coordinator.warnings { print("warning: \(warning)") }
        endedContinuation.yield()
    }
    let timer = Task {
        try? await Task.sleep(for: .seconds(duration))
        endedContinuation.yield()
    }
    let sideTask = Task { await whileRecording() }
    for await _ in ended { break }
    timer.cancel()
    sideTask.cancel()

    let take: TakeRecord
    do {
        take = try await coordinator.stop()
    } catch {
        await printer.value
        printError("error: the take was closed, but not cleanly: \(error)")
        throw ExitCode.failure
    }
    await printer.value
    print("\(take.id) \(take.status.rawValue)")
    for track in take.tracks { print(summary(of: track)) }
}

/// `<folder>/<prefix>-<date>-<time>.toma`, with a number added if that name is taken.
private func createPackage(in folder: URL, prefix: String) throws -> ProjectPackage {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stem = "\(prefix)-\(formatter.string(from: Date()))"
    var attempt = 1
    while true {
        let name = attempt == 1 ? stem : "\(stem)-\(attempt)"
        do {
            return try ProjectPackage.create(in: folder, name: name, app: AppInfo(name: "recorder-dev", version: "dev"), now: Date())
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            attempt += 1
        }
    }
}

// MARK: - Recovery and verification

struct Recover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Recovers the takes left open by a crash in the packages directly inside a folder.",
        discussion: """
            Prints "recovered: <package> <take>" and one line per track for each take it closes, \
            "needs repair: <package>: <reason>" for a package it cannot read safely (left untouched) and \
            "skipped: <package> <take>: being recorded" for a take whose lock is held. Never deletes raw \
            data. Exits 1 if a recovery failed.
            """
    )

    @Argument(help: "Folder that holds the .toma packages.")
    var directory: String

    func validate() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("\(directory) is not a folder.")
        }
    }

    func run() async throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let results = RecoveryScanner.scan(directory: folder)
        if results.isEmpty { print("nothing to recover in \(folder.path)") }
        var failed = false
        for result in results {
            switch result {
            case let .recoverable(package, takeID):
                do {
                    let take = try await TakeRecovery.recover(package: package, takeID: takeID)
                    print("recovered: \(package.url.path) \(takeID)")
                    for track in take.tracks { print("  " + summary(of: track)) }
                } catch RecoveryError.lockHeld {
                    print("skipped: \(package.url.path) \(takeID): being recorded")
                } catch {
                    printError("error: \(package.url.path) \(takeID): \(error)")
                    failed = true
                }
            case let .needsRepair(package, reason):
                print("needs repair: \(package.url.path): \(reason)")
            }
        }
        if failed { throw ExitCode.failure }
    }
}

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Checks every track of a package's last take. Exits 1 if any track fails.",
        discussion: """
            Prints "OK: <track> <seconds> s, dropped <n>" or "FAIL: <track> <reason>" for each track. A \
            track passes when every segment file can be read and has media, its readable media lasts at \
            least --min-duration seconds, and it ends at most 1 s before the take's latest readable media.

            With --max-drop-ratio, a track also fails when its dropped frames (droppedFrames in the \
            manifest) are more than that fraction of the frames that reached the recorder: the frames \
            in its files plus the dropped ones. Display frames are counted from the video samples in \
            the files, heartbeat repeats included. Microphone frames are its readable seconds × 100, one \
            per 10 ms block (the synthetic microphone's block; a real microphone's blocks are longer, so \
            its ratio reads lower than it is).
            """
    )

    @Argument(help: "The .toma package.")
    var package: String

    @Option(help: "Minimum seconds of readable media per track.")
    var minDuration: Double

    @Option(help: "Maximum fraction of dropped frames per track, for example 0.01. Not checked when omitted.")
    var maxDropRatio: Double?

    func run() async throws {
        let project = try LoadedProject.load(URL(fileURLWithPath: package, isDirectory: true))
        let results = await TakeVerifier.verify(project, minDuration: minDuration, maxDropRatio: maxDropRatio)
        guard !results.isEmpty else {
            print("FAIL: \(project.take.id) has no tracks")
            throw ExitCode.failure
        }
        for result in results {
            if result.ok {
                print("OK: \(result.trackID) \(String(format: "%.2f", result.seconds)) s, dropped \(result.droppedFrames)")
            } else {
                print("FAIL: \(result.trackID) \(result.reason ?? "failed")")
            }
        }
        if results.contains(where: { !$0.ok }) { throw ExitCode.failure }
    }
}

// MARK: - Output

/// `<track>: <n> segments, <s> s, dropped <n>, last ended <reason>`, from the manifest.
private func summary(of track: TrackRecord) -> String {
    let seconds = track.segments.reduce(0.0) { total, segment in
        total + (segment.endHostTime.map { $0.seconds(since: segment.startHostTime) } ?? 0)
    }
    let dropped = track.segments.reduce(0) { $0 + $1.droppedFrames }
    let last = track.segments.last?.endReason.map { "\($0)" } ?? "open"
    return "\(track.id): \(track.segments.count) segment(s), \(String(format: "%.2f", seconds)) s, "
        + "dropped \(dropped), last ended \(last)"
}

private func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Runs the command line. Called from an async function so that the `async` `main()` of
/// `AsyncParsableCommand` is chosen: top-level code picks the synchronous overload.
private func runCommandLine() async {
    await RecorderDev.main()
}

// Line-buffered even into a pipe or a file, so a script reads the package path as soon as it is printed.
setvbuf(stdout, nil, _IOLBF, 0)
await runCommandLine()
