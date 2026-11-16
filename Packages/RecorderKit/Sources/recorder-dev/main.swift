// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
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
        subcommands: [SynthRecord.self, Record.self, ListSources.self, Recover.self, Verify.self, ExportMP4.self]
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
        abstract: "Records displays (the main one by default) or a window, a camera (--camera), the default microphone and system audio (--system-audio).",
        discussion: """
            Needs Screen Recording and Microphone permission for the terminal that runs it, Camera permission \
            with --camera, and System Audio Recording with --system-audio. Creates \
            <directory>/record-<date>-<time>.toma and prints its absolute path as the first line once recording \
            has started, like synth-record. Sleep and screen lock pause the take, as in the app.

            The tracks, in this order: each --display in the order given (the main display when there is neither \
            --display nor --window), or the --window (a take records displays or one window, never both), at \
            --fps (60 by default), camera at 30 fps (--camera), at \
            1080p unless --camera-preset says otherwise, mic, and system-audio (--system-audio). The display and \
            window IDs are the ones list-sources prints. --area x,y,w,h (global points) marks the area of an Area \
            take on its one --display: the track still records the whole display, and the manifest keeps the area. \
            --points records one pixel per point instead of the display's own pixels (half of them on Retina). \
            Notification Center (the notifications and the desktop widgets) is never recorded, nor is this tool. \
            A display that changes resolution, or a window that is resized, goes on in a new segment at its new size.

            With --window, a "visibility: <visible|otherSpace|hidden>" line is printed each time the window's \
            visibility changes: otherSpace while it is in another Space and still recorded, hidden once no frame \
            has come for a second while it is not on screen (minimized, or still in another Space).

            The camera records in the smallest of its formats that covers the preset at 30 fps, or its largest at \
            30 fps if none does; the macOS log (subsystem dev.toma.Toma, category CameraSessionHost) says when the \
            session changed that format or rate and it was set again. --camera default records the system's \
            preferred camera; --camera <uniqueID> (from list-sources) that camera, or the system's preferred one \
            while it is not connected. A camera that is disconnected, taken by another app or suspended (a closed \
            lid) is restarted as in the app, on the system's preferred camera while it is gone: "warning:" lines \
            say so, and the take's events.jsonl logs a deviceChanged event when another camera takes over.

            --system-audio all records every app but this tool and the notification and alert sounds; \
            --system-audio <bundleID,…> (from list-sources) only those apps and their helpers, silence while \
            none of them runs, and an app opened during the take from then on. The track is stereo, mixed from \
            the apps' sound. macOS does not say whether System Audio Recording was allowed: if it was refused, \
            the track is silent.

            The cursor is sampled at 120 Hz, but clicks may be missing: a command-line tool has no \
            NSApplication, and the mouse-button monitors may not deliver there. The displays' geometry is logged \
            when it changes, and the window's at 10 Hz.
            """
    )

    @Argument(help: "Folder for the new package. Created if needed.")
    var directory: String

    @Option(help: "Seconds to record.")
    var duration: Double

    @Option(name: .customLong("display"), help: "A display to record, by its ID from list-sources. Repeat it for more displays.")
    var displays: [UInt32] = []

    @Option(help: "A window to record, by its ID from list-sources.")
    var window: UInt32?

    @Option(help: "The area of an Area take, x,y,w,h in global points; needs one --display.")
    var area: String?

    @Option(help: "Frames per second of the displays and the window.")
    var fps = 60

    @Flag(help: "Record one pixel per point instead of the display's own pixels.")
    var points = false

    @Option(help: "Also record a camera: default, or a camera's uniqueID from list-sources.")
    var camera: String?

    @Option(help: "The camera's quality: p720 (1280×720), p1080 (1920×1080, when left out) or p2160 (3840×2160).")
    var cameraPreset: CameraPreset?

    @Option(help: "Also record system audio: all, or the bundle IDs of the apps to record, separated by commas.")
    var systemAudio: String?

    func validate() throws {
        guard duration > 0 else { throw ValidationError("--duration must be positive.") }
        guard fps > 0 else { throw ValidationError("--fps must be positive.") }
        guard Set(displays).count == displays.count else { throw ValidationError("Each --display can be given once.") }
        if window != nil, !displays.isEmpty { throw ValidationError("--window records no display: leave out --display.") }
        if let area {
            guard Self.rect(area) != nil else { throw ValidationError("--area takes x,y,w,h in points, with w and h positive.") }
            guard displays.count == 1 else { throw ValidationError("--area needs exactly one --display.") }
        }
        if let camera, camera.isEmpty { throw ValidationError("--camera takes default or a camera's uniqueID.") }
        if cameraPreset != nil, camera == nil { throw ValidationError("--camera-preset needs --camera.") }
        if let systemAudio, Self.scope(systemAudio) == nil {
            throw ValidationError("--system-audio takes all or bundle IDs separated by commas.")
        }
    }

    /// `all`, or the bundle IDs of a comma-separated list; `nil` if it names none.
    static func scope(_ argument: String) -> SystemAudioScope? {
        if argument == "all" { return .all }
        let bundleIDs = argument.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return bundleIDs.isEmpty ? nil : .applications(bundleIDs)
    }

    /// `x,y,w,h`, with `w` and `h` positive; `nil` otherwise.
    static func rect(_ argument: String) -> Rect? {
        let values = argument.split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return Rect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    func run() async throws {
        let scale: CaptureScale = points ? .points : .native
        let displayIDs = displays.isEmpty && window == nil ? [CGMainDisplayID()] : displays
        let captureArea = area.flatMap(Self.rect)
        let fps = fps
        // On the main thread a display gets its user-visible name.
        var sources: [any CaptureSource] = await MainActor.run {
            displayIDs.map { DisplayCaptureSource(displayID: $0, framesPerSecond: fps, scale: scale, captureArea: captureArea) }
        }
        var input: [any InputRecorder] = [CursorRecorder()]
        if !displayIDs.isEmpty {
            // The scale the tracks record, as their first displayGeometry says.
            input.append(DisplayGeometryRecorder(displayIDs: displayIDs, query: { displayID in
                DisplayGeometryRecorder.liveQuery(displayID).flatMap { geometry in
                    ScreenCapture.recordedPixelScale(displayScale: geometry.scale, scale: scale).map { (geometry.frame, $0) }
                }
            }))
        }
        if let window {
            let source = WindowCaptureSource(windowID: window, framesPerSecond: fps, scale: scale)
            sources.append(source)
            input.append(WindowGeometryRecorder(
                trackID: source.trackID, windowID: window, lastCompleteFrame: { source.lastCompleteFrameTime },
                onVisibilityChange: { print("visibility: \($0.rawValue)") }))
        }
        if let camera {
            sources.append(CameraCaptureSource(
                host: CameraSessionHost(), preferredDeviceUniqueID: camera == "default" ? nil : camera,
                preset: cameraPreset ?? .p1080))
        }
        sources.append(MicrophoneCaptureSource(preferredDeviceUniqueID: nil))
        if let scope = systemAudio.flatMap(Self.scope) {
            sources.append(ProcessTapSource(scope: scope))
        }
        try await recordTake(
            in: directory, prefix: "record", duration: duration,
            sources: sources, input: CompositeInputRecorder(input),
            systemActivity: SystemActivityMonitor.live())
    }
}

struct ListSources: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-sources",
        abstract: "Lists the displays, windows, cameras, microphones and audio processes that can be recorded, with their IDs.",
        discussion: """
            One line per source: "display <CGDirectDisplayID>: <name>, <width>×<height> pt at (<x>, <y>), \
            <scale>x", "window <CGWindowID>: <bundle ID or app name>, \"<title>\", <width>×<height> pt at \
            (<x>, <y>)" for each window on screen in the normal layer (titles need the Screen Recording \
            permission; without it they are empty), "camera <uniqueID>: <name>" and "microphone <uniqueID>: \
            <name>", followed by "main", "asleep" (it records nothing until it wakes), "system preferred", \
            "Continuity Camera" or "default" where they apply. Then one line per process connected to the audio \
            system: "audio process <pid>: bundle <bundle ID or none>, path <executable or unknown>", followed by \
            "playing" while it plays audio and "excluded" when system audio never records it (notification and \
            alert sounds). The display and window IDs, the camera uniqueIDs and the bundle IDs are what record \
            takes (--display, --window, --camera, --system-audio). Needs no permission.
            """
    )

    func run() async throws {
        let main = CGMainDisplayID()
        for displayID in onlineDisplayIDs() {
            // On the main thread the display gets its user-visible name.
            let info = await MainActor.run { DisplayCaptureSource(displayID: displayID).sourceInfo }
            var line = "display \(displayID): \(info.name)"
            if let frame = info.globalFrame {
                line += ", \(format(frame.width))×\(format(frame.height)) pt at (\(format(frame.x)), \(format(frame.y)))"
            }
            if let scale = info.pixelScale { line += ", \(format(scale))x" }
            if displayID == main { line += ", main" }
            if CGDisplayIsAsleep(displayID) != 0 { line += ", asleep" }
            print(line)
        }
        for line in windowLines() { print(line) }
        for camera in CameraCatalog.devices() {
            var line = "camera \(camera.uniqueID): \(camera.name)"
            if camera.isSystemPreferred { line += ", system preferred" }
            if camera.isContinuity { line += ", Continuity Camera" }
            print(line)
        }
        let defaultMicrophone = AVCaptureDevice.default(for: .audio)?.uniqueID
        let microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        for microphone in microphones {
            let marker = microphone.uniqueID == defaultMicrophone ? ", default" : ""
            print("microphone \(microphone.uniqueID): \(microphone.localizedName)\(marker)")
        }
        do {
            for process in try AudioProcessCatalog.processes().sorted(by: { $0.pid < $1.pid }) {
                var line = "audio process \(process.pid): bundle \(process.bundleIdentifier ?? "none"), path \(process.executablePath ?? "unknown")"
                if process.isPlayingAudio { line += ", playing" }
                if SystemAudioExclusions.matches(process) { line += ", excluded" }
                print(line)
            }
        } catch {
            printError("warning: the audio processes can't be listed: \(error)")
        }
    }

    /// The windows on screen in the normal layer (0), front to back, as `CGWindowListCopyWindowInfo` lists them.
    private func windowLines() -> [String] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] ?? []
        return windows.compactMap { window in
            guard window[kCGWindowLayer] as? Int == 0, let id = (window[kCGWindowNumber] as? NSNumber)?.uint32Value,
                  let boundsDictionary = window[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            let pid = (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value
            let app = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
                ?? window[kCGWindowOwnerName] as? String ?? "unknown"
            let title = window[kCGWindowName] as? String ?? ""
            return "window \(id): \(app), \"\(title)\", \(format(bounds.width))×\(format(bounds.height)) pt at "
                + "(\(format(bounds.minX)), \(format(bounds.minY)))"
        }
    }

    /// Asleep ones included: the active list leaves them out, and with the only display asleep it is empty.
    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// A whole number without decimals, anything else with two.
    private func format(_ value: CGFloat) -> String {
        format(Double(value))
    }

    /// A whole number without decimals, anything else with two.
    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

extension CameraPreset: ExpressibleByArgument {}

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
        abstract: "Exports a package's last take as an MP4: H.264 tagged Rec.709, and the microphone mixed with system audio as AAC.",
        discussion: """
            Draws every frame as the editor preview does. Writes <out.mp4>.partial.mp4 next to the \
            destination and moves it into place once it is complete, replacing a file already there in one \
            step; if the export fails or is killed, the destination is left as it was (a partial file left by \
            a kill is removed by the next export). Never writes into a .toma package. Prints the progress \
            every 10 % as "progress: <n> %", then "exported: <path>", then a "warning: no audio of <track> …" \
            line for each span where recorded microphone or system audio could not be read and that track is \
            silent in the MP4, and a "warning: no video of <track> …" line for each span where the screen or the \
            camera could not be decoded and the MP4 shows the frame before it.
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
            print("warning: no audio of \(missing.track) from \(missing.file) from \(String(format: "%.2f", missing.start)) s to "
                + "\(String(format: "%.2f", missing.end)) s: \(missing.reason)")
        }
        for missing in summary.missingVideo {
            print("warning: no video of \(missing.track) from \(missing.file) from \(String(format: "%.2f", missing.start)) s to "
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
