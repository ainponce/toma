// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import SyntheticCapture
import Synchronization
import Testing

// The iPhone mode (design §7.6): a take of an iPhone or iPad connected by cable records its screen (`device`, the take's
// only screen) and its sound (`deviceAudio`), then the Mac's camera, microphone and system audio by the rules of the
// other modes, and nothing of the Mac's input. It needs the camera's permission, never screen recording nor Input
// Monitoring.

@MainActor @Suite(.serialized) struct DeviceTakePlanTests {
    private static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isMain: true, maximumFramesPerSecond: 120),
        DisplayInfo(id: 2, frame: Rect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1, isMain: false, maximumFramesPerSecond: 60),
    ]

    /// An iPhone, with the Mac's camera and microphone.
    private static let iPhone = CaptureSelection(
        mode: .device, displayIDs: [1], camera: .systemDefault, microphone: .systemDefault, systemAudio: .off,
        deviceUniqueID: "iphone-1")

    /// The iPhone alone.
    private static let alone: CaptureSelection = {
        var selection = iPhone
        selection.camera = .off
        selection.microphone = .off
        return selection
    }()

    @Test func deviceModeRecordsTheDeviceAndItsAudio() throws {
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(
            Self.iPhone, settings: QuickSettings(cameraPreset: .p720), displays: Self.displays, granted: [.camera, .microphone],
            factory: factory)
        #expect(plan.sources.map(\.trackID) == ["device", "deviceAudio", "camera", "mic"])
        #expect(plan.sources.map(\.kind) == [.device, .deviceAudio, .camera, .microphone])
        // The device is what the take is about: only the Mac's camera and microphone can be left out.
        #expect(plan.optional.map(\.kind) == [.camera, .microphone])
        let device = try #require(factory.devices.first)
        #expect(factory.devices.count == 1 && plan.sources[0] === device.video && plan.sources[1] === device.audio)
        // Nothing of the Mac's input: no cursor, no keys, no geometry of a display.
        #expect(plan.input is NoInputRecorder)
        #expect(factory.calls == [
            .device(uniqueID: "iphone-1"), .camera(.systemDefault, preset: .p720, framesPerSecond: 30), .microphone(.systemDefault),
        ])
        #expect(plan.microphoneMeter != nil)

        // System audio too, by the same rules; a camera skipped (or not allowed) is left out.
        var withSystemAudio = Self.iPhone
        withSystemAudio.systemAudio = .all
        let all = try TakePlanner.plan(
            withSystemAudio, settings: QuickSettings(), displays: Self.displays, granted: [.camera, .microphone, .systemAudio],
            skipping: [.camera], factory: FakeFactory())
        #expect(all.sources.map(\.trackID) == ["device", "deviceAudio", "mic", "system-audio"])
        #expect(all.optional.map(\.kind) == [.microphone, .systemAudio])

        // Alone, with no display of the Mac connected.
        let aloneFactory = FakeFactory()
        let only = try TakePlanner.plan(Self.alone, settings: QuickSettings(), displays: [], granted: [.camera], factory: aloneFactory)
        #expect(only.sources.map(\.kind) == [.device, .deviceAudio] && only.optional.isEmpty)
        #expect(aloneFactory.calls == [.device(uniqueID: "iphone-1")])
    }

    @Test func theAppRecordsTheDeviceScreenAndSound() throws {
        let factory = LiveCaptureSourceFactory(cameraHost: CameraSessionHost(), noteKeyActivity: true, recordKeys: true) { _ in }
        let (video, audio) = factory.device(uniqueID: "iphone-1")
        // Made without asking the device anything (that is never done on the main thread): its `sourceInfo` is read by
        // the take's coordinator.
        #expect(video is ExternalDeviceCaptureSource && audio is ExternalDeviceAudioSource)
        #expect(video.trackID == "device" && video.kind == .device && video.media == .video(framesPerSecond: 60))
        #expect(audio.trackID == "deviceAudio" && audio.kind == .deviceAudio && audio.media == .audio)
        #expect(TakePlanner.deviceFramesPerSecond == 60)
    }

    @Test func deviceModeWithoutADeviceIsAProblem() {
        var none = Self.iPhone
        none.deviceUniqueID = nil
        let factory = FakeFactory()
        #expect(TakePlanner.problem(with: none, displays: Self.displays) == .noDeviceChosen)
        #expect(throws: TakePlanError.noDeviceChosen) {
            try TakePlanner.plan(none, settings: QuickSettings(), displays: Self.displays, granted: [.camera], factory: factory)
        }
        #expect(factory.calls.isEmpty)
        // With a device chosen the Mac's displays do not matter: none connected, or the one saved gone.
        var gone = Self.iPhone
        gone.displayIDs = [9]
        #expect(TakePlanner.problem(with: gone, displays: []) == nil)
        #expect(TakePlanner.problem(with: Self.iPhone, displays: Self.displays) == nil)
    }

    @Test func deviceModeNeedsCameraNotScreenRecording() async throws {
        // The check: the camera is what an iPhone's take cannot do without.
        let allowed = DeviceProbe([.screenRecording: .denied, .camera: .granted, .microphone: .granted])
        #expect(RecordingPreflight.evaluate(probe: allowed, wanted: [.camera, .microphone], required: .camera)
            == PreflightResult(missing: [], granted: [.microphone, .camera], canRecord: true))
        let refused = DeviceProbe([.screenRecording: .granted, .camera: .denied])
        #expect(RecordingPreflight.evaluate(probe: refused, wanted: [.camera], required: .camera)
            == PreflightResult(missing: [.camera], granted: [], canRecord: false))
        // What is required is asked about even if it is not among the wanted; the Mac's modes still need screen recording.
        #expect(!RecordingPreflight.evaluate(probe: refused, wanted: [], required: .camera).canRecord)
        #expect(RecordingPreflight.evaluate(probe: refused, wanted: [.screenRecording, .camera]).canRecord)
        #expect(!RecordingPreflight.evaluate(probe: allowed, wanted: [.screenRecording, .camera]).canRecord)

        // A take with screen recording refused and the camera allowed records, in a package raised to 4 for its tracks.
        try await withDeviceRig(states: [.screenRecording: .denied, .camera: .granted, .microphone: .granted]) { rig in
            rig.controller.startRecording(selection: Self.iPhone, settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.controller.notices.isEmpty && rig.onboardingOpenings == 0 && rig.controller.recordsMicrophone)
            try await Task.sleep(for: .milliseconds(300))
            await rig.controller.stop(openingEditor: false)
            #expect(rig.grants == [[.camera, .microphone]])
            #expect(!rig.probe.states.contains(.screenRecording) && rig.probe.requests.isEmpty)
            let manifest = try rig.manifest(try #require(rig.packages.first))
            #expect(manifest.formatVersion == 4)
            let take = try #require(manifest.takes.first)
            #expect(take.tracks.map(\.kind) == [.device, .deviceAudio, .camera, .microphone])
            #expect(take.track("device")?.source.deviceUniqueID == "iphone-1" && take.status == .complete)
        }

        // The camera never asked: asked for as the take starts, as it always is, and the take records once allowed.
        try await withDeviceRig(states: [.camera: .notDetermined], answers: [.camera: .granted]) { rig in
            rig.controller.startRecording(selection: Self.alone, settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.probe.requests == [.camera] && rig.onboardingOpenings == 0)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.grants == [[.camera]])
        }

        // Refused: nothing records, and the permissions open, as without screen recording in the Mac's modes.
        try await withDeviceRig(states: [.screenRecording: .granted, .camera: .denied]) { rig in
            rig.controller.startRecording(selection: Self.alone, settings: QuickSettings())
            #expect(rig.onboardingOpenings == 1 && rig.controller.phase == .idle)
            #expect(rig.grants.isEmpty && rig.probe.requests.isEmpty)
        }
        try await withDeviceRig(states: [.camera: .notDetermined], answers: [.camera: .denied]) { rig in
            rig.controller.startRecording(selection: Self.alone, settings: QuickSettings())
            #expect(await eventually { rig.onboardingOpenings == 1 && rig.controller.phase == .idle })
            #expect(rig.grants.isEmpty && rig.probe.requests == [.camera])
        }
    }

    @Test func deviceModeNeverWantsInputMonitoring() async throws {
        for inputMonitoring in [PermissionState.denied, .notDetermined, .granted] {
            try await withDeviceRig(states: [.camera: .granted, .inputMonitoring: inputMonitoring], recordKeys: true, countdown: 1) { rig in
                rig.controller.startRecording(selection: Self.alone, settings: QuickSettings())
                #expect(await eventually { rig.controller.phase.isRecordingATake })
                // No `.keysNotRecorded`: an iPhone's take records no keys of the Mac.
                #expect(rig.controller.notices.isEmpty)
                rig.controller.restartTake()
                #expect(await eventually { rig.grants.count == 2 && rig.controller.phase.isRecordingATake })
                #expect(rig.controller.notices.isEmpty)
                await rig.controller.stop(openingEditor: false)
                // Not even its state is read, nor screen recording's.
                #expect(!rig.probe.states.contains(.inputMonitoring) && !rig.probe.states.contains(.screenRecording), "\(inputMonitoring)")
                #expect(rig.probe.requests.isEmpty && rig.grants == [[.camera], [.camera]])
            }
        }
    }

    @Test func aPausedDeviceIsTheScreenPausedUntilItComesBack() async throws {
        try await withDeviceRig(states: [.camera: .granted], restartBackoff: [.milliseconds(20)]) { rig in
            rig.controller.startRecording(selection: Self.alone, settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            let device = try #require(rig.factory.devices.first).video
            // Its restarts fail: the take's only screen is paused, and says so.
            device.failOnStart = 99
            device.failNow(domain: "AVFoundationErrorDomain", code: -11819)
            #expect(await eventually { rig.controller.notices.contains(.screenPaused) })
            // It comes back: the notice goes, as for a display.
            device.failOnStart = 0
            #expect(await eventually { rig.controller.notices.contains(.streamResumed(.device)) })
            #expect(!rig.controller.notices.contains(.screenPaused))
            #expect(!rig.controller.notices.contains(.streamInterrupted(.device)))
            await rig.controller.stop(openingEditor: false)
        }
    }

    @Test func deviceLoadCounts() throws {
        let settings = QuickSettings(cameraPreset: .p1080, cameraFramesPerSecond: 30)
        // At the device's size when it is known, at 60 frames a second, then the camera; the Mac's displays weigh nothing.
        #expect(TakePlanner.loadItems(
            Self.iPhone, settings: settings, displays: Self.displays, windowSize: nil, deviceSize: CGSize(width: 1179, height: 2556)) == [
            VideoLoadItem(source: .device, width: 1179, height: 2556, framesPerSecond: 60),
            VideoLoadItem(source: .camera, width: 1920, height: 1080, framesPerSecond: 30),
        ])
        // Before its first run the device has no size (and it is never asked on the main thread): it weighs as the largest
        // screen an iPhone or iPad sends.
        #expect(TakePlanner.unknownDeviceSize == CGSize(width: 2064, height: 2752))
        #expect(TakePlanner.loadItems(Self.alone, settings: settings, displays: Self.displays, windowSize: nil)
            == [VideoLoadItem(source: .device, width: 2064, height: 2752, framesPerSecond: 60)])
        let plan = try TakePlanner.plan(
            Self.iPhone, settings: settings, displays: Self.displays, granted: [.camera, .microphone], factory: FakeFactory())
        #expect(plan.load == .ok(ratio: Double(2064 * 2752 * 60 + 1920 * 1080 * 30) / Double(EncoderLoad.defaultBudgetPixelsPerSecond)))
        // Without the camera's permission (or skipped), only the device.
        let skipped = try TakePlanner.plan(
            Self.iPhone, settings: settings, displays: Self.displays, granted: [.camera, .microphone], skipping: [.camera],
            factory: FakeFactory())
        #expect(skipped.load == .ok(ratio: Double(2064 * 2752 * 60) / Double(EncoderLoad.defaultBudgetPixelsPerSecond)))

        // A device is never asked to go lower: it is what the take is about.
        let heavy = [
            VideoLoadItem(source: .device, width: 2064, height: 2752, framesPerSecond: 60),
            VideoLoadItem(source: .camera, width: 3840, height: 2160, framesPerSecond: 60),
        ]
        let pixels = 2064 * 2752 * 60 + 3840 * 2160 * 60
        #expect(EncoderLoad.evaluate(heavy, mainDisplayID: 1) == .over(
            ratio: Double(pixels) / 800_000_000, suggestions: [.lowerCameraPreset(to: .p1080), .lowerCameraRate(to: 30)]))
        #expect(EncoderLoad.evaluate([heavy[0]], mainDisplayID: 1, budget: 100_000_000)
            == .over(ratio: Double(2064 * 2752 * 60) / 100_000_000, suggestions: []))
    }

    @Test func selectionWithADeviceRoundTrips() throws {
        #expect(CaptureMode.allCases.last == .device && CaptureMode.device.rawValue == "device")
        #expect(CaptureSelection.mainDisplay(1).deviceUniqueID == nil)
        let data = try JSONEncoder().encode(Self.iPhone)
        #expect(try JSONDecoder().decode(CaptureSelection.self, from: data) == Self.iPhone)
        // Saved before there was a device to choose: none chosen.
        let old = try JSONEncoder().encode(CaptureSelection.mainDisplay(1))
        #expect(!String(decoding: old, as: UTF8.self).contains("deviceUniqueID"))
        #expect(try JSONDecoder().decode(CaptureSelection.self, from: old) == .mainDisplay(1))

        let suite = "DeviceTakePlanTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var settings = store.settings
        settings.selection = Self.iPhone
        store.settings = settings
        #expect(SettingsStore(defaults: defaults).settings.selection == Self.iPhone)
    }

    @Test func theMacKeepsNoWallpaperAndTheBubbleStaysInSight() {
        // Nothing of the Mac is recorded: no wallpaper is kept.
        #expect(WallpaperSnapshot.displayIDs(recording: Self.iPhone, displays: Self.displays, windowFrame: nil).isEmpty)
        // The camera's bubble shows on the display with the pointer, else on the main one.
        let pointerOnTheSecond = CGPoint(x: 2000, y: 10)
        #expect(CameraBubbleLayout.region(for: Self.iPhone, displays: Self.displays, pointer: pointerOnTheSecond, windowFrame: nil)
            == Self.displays[1].frame)
        #expect(CameraBubbleLayout.region(for: Self.iPhone, displays: Self.displays, pointer: nil, windowFrame: nil)
            == Self.displays[0].frame)
        #expect(CameraBubbleLayout.region(for: Self.iPhone, displays: [], pointer: nil, windowFrame: nil) == nil)
    }
}

// MARK: - Rig

extension RecordingController.Phase {
    fileprivate var isRecordingATake: Bool {
        if case .recording = self { true } else { false }
    }
}

/// A controller whose takes record what `FakeFactory` makes (an iPhone of 36 × 64 and its sound, the camera and the
/// microphone) into a fresh folder, with no display of the Mac connected, the permissions in `states` (each one a
/// request answers changing to its `answers`), "Record Keys to Show Them" as `recordKeys`, a countdown of `countdown`
/// seconds that waits for nothing, and the coordinators waiting `restartBackoff` between restarts, if given.
@MainActor private func withDeviceRig(
    states: [PermissionKind: PermissionState], answers: [PermissionKind: PermissionState] = [:], recordKeys: Bool = false,
    countdown: Int = 0, restartBackoff: [Duration]? = nil, _ body: (DeviceRig) async throws -> Void
) async throws {
    try await withTemporaryDirectory { directory in
        let suite = "DeviceTakePlanTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsStore(defaults: defaults).settings = RecorderSettings(countdownSeconds: countdown, recordKeys: recordKeys)
        try await body(DeviceRig(
            folder: directory.appendingPathComponent("Movies/Toma", isDirectory: true), defaults: defaults,
            probe: DeviceProbe(states, answers: answers),
            configuration: restartBackoff.map { RecordingConfiguration(restartBackoff: $0) } ?? RecordingConfiguration()))
    }
}

@MainActor private final class DeviceRig {
    let probe: DeviceProbe
    let factory = FakeFactory()
    let controller: RecordingController
    /// The permissions granted to each take, in order.
    private(set) var grants: [Set<PermissionKind>] = []
    /// The packages of the takes made.
    private(set) var packages: [ProjectPackage] = []
    private(set) var onboardingOpenings = 0
    private let disk = FakeDisk()

    init(folder: URL, defaults: UserDefaults, probe: DeviceProbe, configuration: RecordingConfiguration) {
        self.probe = probe
        weak var rig: DeviceRig?
        let (disk, factory) = (disk, factory)
        let environment = TakeEnvironment(
            projectsFolder: folder,
            app: AppInfo(name: "Tests", version: "0"),
            projectNamePrefix: "Recording",
            hasMicrophone: { true },
            createPackage: { folder, prefix, app, now in
                try ProjectFolder.createPackage(in: folder, prefix: prefix, app: app, now: now)
            },
            prepareTake: { package, request, granted in
                rig?.grants.append(granted)
                rig?.packages.append(package)
                let plan = try TakePlanner.plan(
                    request.selection, settings: request.settings, displays: [], granted: granted, skipping: request.skipping,
                    includedWindowIDs: request.includedWindowIDs, factory: factory)
                let coordinator = RecordingCoordinator(
                    package: package, sources: plan.sources, input: plan.input,
                    diskMonitor: disk.monitor(volume: package.url), systemActivity: AsyncStream { $0.finish() },
                    configuration: configuration, cameraStyle: request.cameraStyle)
                return PreparedTake(
                    recording: coordinator, optional: plan.optional,
                    kinds: Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.trackID, $0.kind) }), load: plan.load,
                    microphoneMeter: plan.microphoneMeter)
            },
            termination: NoDeviceTermination(),
            now: { Date() },
            sleep: { _ in })
        controller = RecordingController(probe: probe, environment: environment, defaults: defaults)
        rig = self
        controller.openOnboarding = { [weak self] in self?.onboardingOpenings += 1 }
    }

    func manifest(_ package: ProjectPackage) throws -> Manifest {
        try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
    }
}

private struct NoDeviceTermination: TerminationGuarding {
    func takeBegan() {}
    func takeEnded() {}
}

/// Permissions in fixed states, each one a request answers changing to its answer; it notes every permission whose
/// state is read and every request.
private final class DeviceProbe: PermissionProbe {
    private struct Log {
        var states: [PermissionKind: PermissionState]
        var read: [PermissionKind] = []
        var requested: [PermissionKind] = []
    }

    private let log: Mutex<Log>
    private let answers: [PermissionKind: PermissionState]

    init(_ states: [PermissionKind: PermissionState], answers: [PermissionKind: PermissionState] = [:]) {
        log = Mutex(Log(states: states))
        self.answers = answers
    }

    /// The permissions whose state was read.
    var states: Set<PermissionKind> { Set(log.withLock { $0.read }) }
    /// What was requested, in order.
    var requests: [PermissionKind] { log.withLock { $0.requested } }

    func state(of kind: PermissionKind) -> PermissionState {
        log.withLock { log in
            log.read.append(kind)
            return log.states[kind] ?? .notDetermined
        }
    }

    func request(_ kind: PermissionKind) async -> PermissionState {
        log.withLock { log in
            log.requested.append(kind)
            if let answer = answers[kind] { log.states[kind] = answer }
            return log.states[kind] ?? .notDetermined
        }
    }
}
