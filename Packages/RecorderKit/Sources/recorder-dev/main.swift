// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import ArgumentParser
import CoreGraphics
import CryptoKit
import Darwin
import Editing
import Export
import Foundation
import ImageIO
import Library
import ProjectFormat
import Recording
import Recovery
import Synchronization
import SyntheticCapture

/// Development tool: records, recovers, verifies and exports takes from the command line, and edits them at random
/// and checks their edit, for the crash and endurance scripts in `scripts/`.
struct RecorderDev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recorder-dev",
        abstract: "Records, recovers, verifies, exports and stresses the editing of Toma takes from the command line.",
        subcommands: [
            SynthRecord.self, Record.self, ListSources.self, Recover.self, Verify.self, ExportMP4.self, BenchExport.self,
            EditStress.self, EditCheck.self, LibraryEmpty.self,
        ]
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

            The take's events.jsonl gets synthetic input, the same in every take: the cursor going round a circle \
            about (320, 180), a click every second from 0.5 s, the arrow and from 1 s the I-beam (their images in \
            the take's cursors/ folder), a scroll at 2 s and key activity from 3 to 4 s.
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
            sources: sources, input: SyntheticInputRecorder(),
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

            The cursor is sampled at 120 Hz, but clicks and the scroll may be missing: a command-line tool does \
            not run NSApplication's event loop, and the mouse-button and scroll monitors may not deliver there. Each \
            new shape of the cursor is saved in the take's cursors/ folder, as macOS gives it (none if it gives no \
            image). When keys are typed is noted in 250 ms windows (never which, and nothing while secure input is \
            on), unless --no-key-activity says not to; whether Input Monitoring is granted is only asked, without a \
            prompt, and goes to the macOS log (subsystem dev.toma.Toma, category KeyActivityRecorder). The \
            displays' geometry is logged when it changes, and the window's at 10 Hz.
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

    @Flag(help: "Do not note when keys are typed.")
    var noKeyActivity = false

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
        // Without an NSApplication, AppKit gives no arrow nor I-beam, and the cursor images would never get those kinds.
        await MainActor.run { _ = NSApplication.shared }
        var input: [any InputRecorder] = [CursorRecorder(), CursorImageRecorder(), ScrollRecorder()]
        if !noKeyActivity { input.append(KeyActivityRecorder()) }
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
        abstract: "Exports a package's last take as an MP4, with its edit: H.264 tagged Rec.709, and the audio mixed as AAC.",
        discussion: """
            Exports the edit the editor shows (EditSession.readDocument): a package of version 3 without an edit gets \
            the document a new project starts with, in memory, and nothing is written into the package. --raw \
            exports the take without its edit (the legacy document: what phase 0 and 1a export), for debugging. \
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

    @Flag(help: "Export the take without its edit (the legacy document), for debugging.")
    var raw = false

    func validate() throws {
        guard width > 0, height > 0, fps > 0 else { throw ValidationError("--width, --height and --fps must be positive.") }
    }

    func run() async throws {
        let (project, document) = try readProject(package, raw: raw)
        // As given, made absolute by hand: a relative file URL drops `..` lexically, while the exporter
        // resolves it (after a symlink included) the way the kernel does, as the shell would.
        let destination = URL(fileURLWithPath: output.hasPrefix("/") ? output : FileManager.default.currentDirectoryPath + "/" + output)
        let exporter = MP4Exporter(
            project: project, document: document, settings: ExportSettings(outputSize: [width, height], framesPerSecond: fps))
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

/// The last take of the package at `path` and the document it is exported with: its edit, as the editor shows it
/// (`EditSession.readDocument`, which writes nothing), or with `raw` the legacy document.
private func readProject(_ path: String, raw: Bool) throws -> (LoadedProject, EditDocument) {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    if raw {
        let project = try LoadedProject.load(url)
        return (project, .legacy(for: project))
    }
    let context = EditContext(
        app: AppInfo(name: "recorder-dev", version: "dev"), cachesRoot: FileManager.default.temporaryDirectory, defaultStyle: .toma,
        now: { Date() }, makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) })
    return try EditSession.readDocument(url, take: nil, context: context)
}

// MARK: - Benchmarks

struct BenchExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench-export",
        abstract: "Exports a package, or a synthetic take with everything on, and prints the speed and the peak memory.",
        discussion: """
            Exports the package's last take with its edit (as export does), or with --all-on with the benchmark's \
            document, into a temporary folder, and prints "speed: <x>× real time" (seconds of video over seconds \
            of the export) and "peak memory: <n> MB", the largest physical footprint of the process (what Activity \
            Monitor shows as its memory, the GPU's and the decoders' included). The MP4 is removed.

            --synthetic records a synthetic take of 10 s at --width × --height and --fps (3840 × 2160 at 60 fps by \
            default) with a camera, as synth-record --width <w> --height <h> --fps <f> --camera does, in a temporary \
            folder, and exports it with --all-on in a process of its own (so the recording's memory is not counted), \
            then removes the folder. The benchmark's document has everything on: the aurora-1 wallpaper (or, with \
            --background-image, a 7680 × 4320 image, the largest an asset is decoded to), a shadow, the macOS window \
            frame with a title, mipmapped sampling, a zoom camera that never rests (blocks of 0.25 s, 3 deep, \
            between two far points) with a motion blur of a whole frame, the smoothed cursor with a motion blur of a \
            whole frame, and the camera.
            """
    )

    @Argument(help: "The .toma package; leave it out with --synthetic.")
    var package: String?

    @Flag(help: "Record a synthetic take with a camera in a temporary folder and export it with --all-on.")
    var synthetic = false

    @Flag(help: "Export with the benchmark's document, everything on, instead of the package's edit.")
    var allOn = false

    @Flag(help: "With --all-on, a 7680 × 4320 image as the background instead of the wallpaper; it is written into the package's assets/, so use it with --synthetic, whose take is temporary.")
    var backgroundImage = false

    @Option(help: "Width of the video (and of the synthetic take), in pixels.")
    var width = 3840

    @Option(help: "Height of the video (and of the synthetic take), in pixels.")
    var height = 2160

    @Option(help: "Frames per second of the video (and of the synthetic take).")
    var fps = 60

    func validate() throws {
        guard width > 0, height > 0, fps > 0 else { throw ValidationError("--width, --height and --fps must be positive.") }
        guard synthetic != (package != nil) else { throw ValidationError("Give a package or --synthetic, not both.") }
        if backgroundImage, !(allOn || synthetic) { throw ValidationError("--background-image goes with --all-on or --synthetic.") }
    }

    func run() async throws {
        if synthetic {
            try runSynthetic()
            return
        }
        guard let package else { return }
        let (project, edit) = try readProject(package, raw: false)
        let document = allOn ? try BenchDocument.make(for: project, from: edit, backgroundImage: backgroundImage) : edit
        let folder = FileManager.default.temporaryDirectory.appending(path: "bench-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = ExportSettings(outputSize: [width, height], framesPerSecond: fps)
        let exporter = MP4Exporter(project: project, document: document, settings: settings)
        let started = Date()
        do {
            _ = try await exporter.export(to: folder.appending(path: "bench.mp4")) { _ in }
        } catch {
            printError("error: the export failed: \(error)")
            throw ExitCode.failure
        }
        let elapsed = Date().timeIntervalSince(started)
        let seconds = Double(TimeMap(sequence: document.sequence).frameCount(frameRate: fps)) / Double(fps)
        print(String(format: "exported: %.2f s of video, %d × %d at %d fps, in %.2f s", seconds, width, height, fps, elapsed))
        print(String(format: "speed: %.2f× real time", seconds / elapsed))
        print("peak memory: \(peakFootprint().map { "\($0 >> 20) MB" } ?? "unknown")")
    }

    /// Records the synthetic take with `synth-record` and benchmarks its export with `--all-on`, each in a process of
    /// its own, then removes the take.
    private func runSynthetic() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bench-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        print("recording a synthetic take of \(Int(BenchDocument.seconds)) s, \(width) × \(height) at \(fps) fps, with a camera")
        let recorded = try runThisTool([
            "synth-record", folder.path, "--duration", String(BenchDocument.seconds), "--width", String(width), "--height",
            String(height), "--fps", String(fps), "--camera",
        ])
        guard let take = recorded.split(separator: "\n").first.map(String.init), take.hasSuffix(".toma") else {
            printError("error: synth-record printed no package")
            throw ExitCode.failure
        }
        var arguments = ["bench-export", take, "--all-on", "--width", String(width), "--height", String(height), "--fps", String(fps)]
        if backgroundImage { arguments.append("--background-image") }
        print(try runThisTool(arguments), terminator: "")
    }
}

/// Runs this tool with `arguments`, waits for it and returns what it printed; throws `ExitCode.failure` if it fails.
private func runThisTool(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        printError("error: recorder-dev \(arguments.first ?? "") exited with \(process.terminationStatus)")
        throw ExitCode.failure
    }
    return String(decoding: output, as: UTF8.self)
}

/// The largest physical footprint of this process so far, in bytes (`ledger_phys_footprint_peak` of `TASK_VM_INFO`).
private func peakFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? UInt64(max(info.ledger_phys_footprint_peak, 0)) : nil
}

/// The benchmarks' document, everything on (design §7.9), and their synthetic take's length: what `bench-export
/// --synthetic` exports and `bench-preview --synthetic` plays.
enum BenchDocument {
    /// Seconds of the synthetic take.
    static let seconds = 10.0

    /// `edit` (the take's clips and screens) with everything on: see `BenchExport`'s discussion. With `backgroundImage`,
    /// a 7680 × 4320 PNG is written into the package's `assets/` (once) and is the background.
    static func make(for project: LoadedProject, from edit: EditDocument, backgroundImage: Bool) throws -> EditDocument {
        var document = edit
        document.style.background = backgroundImage
            ? .image(file: try writeBackgroundImage(into: project.package)) : .wallpaper("aurora-1")
        document.style.backgroundBlur = 0
        document.style.shadow = 0.6
        document.style.frame = .macWindow(appearance: .dark, title: "Toma — benchmark", buttons: true)
        document.style.screenSampling = .mipmapped
        document.cursor.show = true
        document.cursor.smoothing = .spring(SpringSpec(damping: 1, response: 0.16))
        document.cursor.hideWhenIdle = false
        document.cursor.motionBlur = 1
        document.zoom.show = true
        document.zoom.motionBlur = 1
        // A camera that never rests: blocks of 0.25 s, 3 deep, between two far points, over every clip.
        document.zoom.regions = document.sequence.flatMap { clip in
            stride(from: 0.0, to: clip.end.seconds(since: clip.start) - 0.25, by: 0.25).enumerated().map { k, offset in
                ZoomRegion(
                    id: String(format: "z-%08x", k + 1), take: clip.take, start: clip.start.adding(seconds: offset),
                    end: clip.start.adding(seconds: offset + 0.25), origin: .user, depth: 3,
                    focus: k % 2 == 0 ? .fixed(x: 0.2, y: 0.25) : .fixed(x: 0.8, y: 0.75), instant: false)
            }
        }
        document.camera.show = true
        return document
    }

    /// Writes a 7680 × 4320 PNG (a smooth gradient with a grid, so it stays small) into `package`'s `assets/`, named by
    /// its hash as an imported image is, unless it is there; returns its path in the package.
    private static func writeBackgroundImage(into package: ProjectPackage) throws -> String {
        let width = 7680, height = 4320
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(
                colorsSpace: space,
                colors: [CGColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1)] as CFArray,
                locations: [0, 1])
        else { throw ValidationError("cannot draw the background image") }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        context.setLineWidth(4)
        for x in stride(from: 0, through: width, by: 240) {
            context.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: height)])
        }
        for y in stride(from: 0, through: height, by: 240) {
            context.strokeLineSegments(between: [CGPoint(x: 0, y: y), CGPoint(x: width, y: y)])
        }
        let png = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)
        else { throw ValidationError("cannot encode the background image") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ValidationError("cannot encode the background image") }
        let name = SHA256.hash(data: png as Data).prefix(16).map { String(format: "%02x", $0) }.joined() + ".png"
        let folder = package.url.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) { try (png as Data).write(to: url) }
        return "assets/" + name
    }
}

// MARK: - Library

struct LibraryEmpty: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library-empty",
        abstract: "Empties the trash of a projects folder as the library does: every project in it, deleted forever.",
        discussion: """
            Deletes every package in <projects folder>/Trash/ with LibraryOperations.deleteForever: each is first \
            renamed to Trash/.deleting-<UUID> (from then on it is in no list), then deleted, never following a link. \
            Prints "deleted <n>" each time one more is deleted. Exits 1 if any could not be deleted (it is back under \
            its name in the trash) or has a lock taken.

            With --finish-only, it only finishes the deletions a crash left (LibraryOperations.finishPendingDeletions: \
            the Trash/.deleting-* folders), as the app does when it opens, and touches nothing else.

            No take is recording and no project is open here. The library's records (where each project of the trash \
            came from) are kept in a temporary folder, never the app's.
            """
    )

    @Argument(help: "The projects folder, which holds Trash/.")
    var projectsFolder: String

    @Flag(help: "Only finish the deletions a crash left (Trash/.deleting-*).")
    var finishOnly = false

    func validate() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectsFolder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("\(projectsFolder) is not a folder.")
        }
    }

    func run() async throws {
        let folder = URL(fileURLWithPath: projectsFolder, isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "recorder-dev-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fileSystem = SystemFileSystem()
        let operations = LibraryOperations(
            projectsFolder: folder, fileSystem: fileSystem,
            records: LibraryRecordsStore(url: scratch.appending(path: "library.json")), app: CommandLineApp())
        if finishOnly {
            await operations.finishPendingDeletions()
            return
        }
        let trash = ProjectTrash.folder(in: folder)
        let packages = ((try? fileSystem.list(trash)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension == ProjectPackage.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let printed = Mutex(0)
        let result = await operations.deleteForever(packages) { done, _, _ in
            printed.withLock { last in
                while last < done {
                    last += 1
                    print("deleted \(last)")
                }
            }
        }
        if case .failure(let failure) = result {
            printError("error: \(failure)")
            throw ExitCode.failure
        }
    }

    /// The app around the library, from the command line: nothing records, nothing is open.
    private struct CommandLineApp: LibraryAppState {
        func isRecording() -> Bool { false }
        func isOpenHere(_ url: URL) -> Bool { false }
        func hasUnsavedChanges(_ url: URL) -> Bool { false }
        func close(_ url: URL) async {}
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

func printError(_ message: String) {
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
