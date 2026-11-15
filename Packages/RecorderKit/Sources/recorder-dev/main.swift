// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import CoreGraphics
import Darwin
import Export
import Foundation
import ProjectFormat
import Recording
import Recovery
import Synchronization
import SyntheticCapture

/// Development tool: records, recovers, verifies and exports takes from the command line, for the crash
/// and endurance scripts in `scripts/`.
struct RecorderDev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recorder-dev",
        abstract: "Records, recovers, verifies and exports Toma takes from the command line.",
        subcommands: [SynthRecord.self, Record.self, Recover.self, Verify.self, ExportMP4.self]
    )
}

// MARK: - Recording

struct SynthRecord: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "synth-record",
        abstract: "Records a take from synthetic displays or a window, microphone, camera and system audio. Needs no permission.",
        discussion: """
            Creates <directory>/synth-<date>-<time>.toma and prints its absolute path as the first line \
            once recording has started. Warnings follow as "warning: …" lines, and a summary of the take \
            once it is closed.

            The tracks, in this order: display-1 at the origin of the global space (or, with --window, \
            window-4242 at (100, 80)), display-2 and further ones each to the left of the one before (--displays), camera \
            at 1280×720 and 30 fps (--camera), mic, and system-audio in stereo at 48 kHz with a clock that \
            runs 1500 ppm slow (--system-audio).
            """
    )

    @Argument(help: "Folder for the new package. Created if needed.")
    var directory: String

    @Option(help: "Seconds to record.")
    var duration: Double

    @Option(help: "Frames per second of the synthetic displays or window.")
    var fps = 30

    @Option(help: "Width of the synthetic displays or window, in pixels.")
    var width = 640

    @Option(help: "Height of the synthetic displays or window, in pixels.")
    var height = 360

    @Option(help: "Seconds after which the synthetic screens stop changing; heartbeats keep their tracks going.")
    var staticAfter: Double?

    @Option(help: "Synthetic displays to record, each --width × --height; the second and later ones to the left of the first.")
    var displays = 1

    @Flag(help: "Record a synthetic window, window-4242, instead of the displays.")
    var window = false

    @Flag(help: "Also record a synthetic camera, 1280×720 at 30 fps.")
    var camera = false

    @Flag(help: "Also record synthetic system audio, stereo at 48 kHz, with a clock 1500 ppm slow.")
    var systemAudio = false

    func validate() throws {
        guard duration > 0 else { throw ValidationError("--duration must be positive.") }
        guard fps > 0, width > 0, height > 0 else { throw ValidationError("--fps, --width and --height must be positive.") }
        if let staticAfter, staticAfter < 0 { throw ValidationError("--static-after cannot be negative.") }
        guard displays > 0 else { throw ValidationError("--displays must be positive.") }
        if window, displays > 1 { throw ValidationError("--window records no display: leave out --displays.") }
    }

    func run() async throws {
        let screens = window
            ? [SyntheticVideoSource(
                trackID: "window-4242", kind: .window, globalOrigin: [100, 80], width: width, height: height,
                framesPerSecond: fps)]
            : (1...displays).map { n in
                SyntheticVideoSource(
                    trackID: "display-\(n)", displayID: UInt32(n), globalOrigin: [-Double((n - 1) * width), 0],
                    width: width, height: height, framesPerSecond: fps)
            }
        var sources: [any CaptureSource] = screens
        if camera {
            sources.append(SyntheticVideoSource(trackID: "camera", kind: .camera, width: 1280, height: 720, framesPerSecond: 30))
        }
        sources.append(SyntheticAudioSource())
        if systemAudio {
            sources.append(SyntheticAudioSource(trackID: "system-audio", kind: .systemAudio, channels: 2, clockSkewPPM: -1500))
        }
        let staticAfter = staticAfter
        try await recordTake(
            in: directory, prefix: "synth", duration: duration,
            sources: sources, input: NoInputRecorder(),
            systemActivity: AsyncStream { $0.finish() },
            whileRecording: {
                guard let staticAfter else { return }
                do {
                    try await Task.sleep(for: .seconds(staticAfter))
                } catch {
                    return  // the take ended first
                }
                for screen in screens { screen.pauseFrames(true) }
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
            "needs repair: <package>: <reason>" for a package it cannot read safely (left untouched), \
            "skipped: <package> <take>: being recorded" for a take whose lock is held and "skipped: \
            <package> <take>: another take in this package is recording" while a recorder writes that \
            package's manifest. Never deletes raw data. Exits 1 if a recovery failed; run it again once \
            the cause (for example a segment file it may not read) is fixed.
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
                } catch RecoveryError.anotherTakeRecording {
                    print("skipped: \(package.url.path) \(takeID): another take in this package is recording")
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
            least --min-duration seconds, and neither the track nor any of its segments ends more than a \
            tolerance before it should: the take's latest readable media for the track, the manifest's \
            endHostTime for a segment. The tolerance is 1 s in a take the recorder closed (complete) and \
            2 s in one a crash left open (recovered, or still recording), whose tracks end at their last \
            complete 1 s fragment.

            --max-drop-ratio is optional: without it, dropped frames are reported but not checked. With \
            it, a track fails when dropped / (frames + dropped) is above the ratio. dropped is the sum of \
            droppedFrames in the manifest; after a crash, recovery takes it from the last droppedSamples \
            event, so the drops of up to the last 2 s may be missing. frames are the frames that were \
            written: for a display, the video samples in its files, heartbeat repeats included; for a \
            microphone, its readable seconds × 100, one per 10 ms block (the synthetic microphone's \
            block; a real microphone's blocks are longer, so its ratio reads lower than it is).
            """
    )

    @Argument(help: "The .toma package.")
    var package: String

    @Option(help: "Minimum seconds of readable media per track.")
    var minDuration: Double

    @Option(help: "Maximum dropped / (frames + dropped) per track, for example 0.01. Not checked when omitted.")
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

// MARK: - Export

struct ExportMP4: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Exports a package's last take as an MP4: H.264 tagged Rec.709, and the microphone as AAC.",
        discussion: """
            Draws every frame as the editor preview does. Writes <out.mp4>.partial.mp4 next to the \
            destination and moves it into place once it is complete, replacing a file already there in one \
            step; if the export fails or is killed, the destination is left as it was (a partial file left by \
            a kill is removed by the next export). Never writes into a .toma package. Prints the progress \
            every 10 % as "progress: <n> %", then "exported: <path>", then a "warning: no audio …" line for \
            each span where recorded microphone audio could not be read and the MP4 is silent, and a \
            "warning: no video …" line for each span where the screen could not be decoded and the MP4 \
            shows the frame before it.
            """
    )

    @Argument(help: "The .toma package.")
    var package: String

    @Argument(help: "The MP4 to write.")
    var output: String

    @Option(help: "Width of the video, in pixels.")
    var width = 1920

    @Option(help: "Height of the video, in pixels.")
    var height = 1080

    @Option(help: "Frames per second of the video.")
    var fps = 60

    func validate() throws {
        guard width > 0, height > 0, fps > 0 else { throw ValidationError("--width, --height and --fps must be positive.") }
    }

    func run() async throws {
        let project = try LoadedProject.load(URL(fileURLWithPath: package, isDirectory: true))
        // As given, made absolute by hand: a relative file URL drops `..` lexically, while the exporter
        // resolves it (after a symlink included) the way the kernel does, as the shell would.
        let destination = URL(fileURLWithPath: output.hasPrefix("/") ? output : FileManager.default.currentDirectoryPath + "/" + output)
        let exporter = MP4Exporter(project: project, settings: ExportSettings(outputSize: [width, height], framesPerSecond: fps))
        let printed = Mutex(-1)  // tenths of the export last printed
        let summary: ExportSummary
        do {
            summary = try await exporter.export(to: destination) { progress in
                let tenths = Int(progress * 10)
                let reached = printed.withLock { last in
                    defer { last = max(last, tenths) }
                    return tenths > last
                }
                if reached { print("progress: \(tenths * 10) %") }
            }
        } catch {
            printError("error: the export failed: \(error)")
            throw ExitCode.failure
        }
        print("exported: \(destination.path)")
        for missing in summary.missingAudio {
            print("warning: no audio from \(missing.file) from \(String(format: "%.2f", missing.start)) s to "
                + "\(String(format: "%.2f", missing.end)) s: \(missing.reason)")
        }
        for missing in summary.missingVideo {
            print("warning: no video from \(missing.file) from \(String(format: "%.2f", missing.start)) s to "
                + "\(String(format: "%.2f", missing.end)) s: \(missing.reason)")
        }
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
