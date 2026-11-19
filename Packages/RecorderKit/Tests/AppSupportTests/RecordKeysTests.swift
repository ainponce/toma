// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Synchronization
import Testing

// "Record Keys to Show Them" (`RecorderSettings.recordKeys`): off unless the user turns it on, a `KeyPressRecorder` in the
// take's input only then, and Input Monitoring wanted by the take's check but never asked for by it: without it the take
// records all the same, without keys, and says so (`TakeNotice.keysNotRecorded`).

@MainActor @Suite(.serialized) struct RecordKeysTests {
    @Test func recordKeysIsOffByDefaultAndReadsOldSettings() throws {
        #expect(!RecorderSettings().recordKeys)
        try withKeysDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(!store.settings.recordKeys)

            // Saved by a version without the setting.
            defaults.set(Data(#"{"countdownSeconds":5,"noteKeyActivity":false}"#.utf8), forKey: SettingsStore.key)
            #expect(!store.settings.recordKeys && store.settings.countdownSeconds == 5 && !store.settings.noteKeyActivity)

            var settings = store.settings
            settings.recordKeys = true
            store.settings = settings
            #expect(SettingsStore(defaults: defaults).settings == settings)
            #expect(SettingsStore(defaults: defaults).settings.recordKeys)

            // A value this version cannot read: off, and the rest is kept.
            defaults.set(Data(#"{"countdownSeconds":10,"recordKeys":"sometimes"}"#.utf8), forKey: SettingsStore.key)
            #expect(!store.settings.recordKeys && store.settings.countdownSeconds == 10)
        }
    }

    @Test func inputHasKeyPressesOnlyWhenAsked() throws {
        for recordKeys in [false, true] {
            let factory = LiveCaptureSourceFactory(
                cameraHost: CameraSessionHost(), noteKeyActivity: true, recordKeys: recordKeys) { _ in }
            let input = try #require(factory.input(windowTrack: nil, displayIDs: []) as? CompositeInputRecorder)
            #expect(input.recorders.count { $0 is KeyPressRecorder } == (recordKeys ? 1 : 0), "recordKeys \(recordKeys)")
            // When keys are typed is noted either way: the two live alongside.
            #expect(input.recorders.count { $0 is KeyActivityRecorder } == 1)
        }
        // Off unless asked for.
        let factory = LiveCaptureSourceFactory(cameraHost: CameraSessionHost(), noteKeyActivity: false) { _ in }
        let input = try #require(factory.input(windowTrack: nil, displayIDs: []) as? CompositeInputRecorder)
        #expect(!input.recorders.contains { $0 is KeyPressRecorder || $0 is KeyActivityRecorder })
    }

    @Test func keysOnWithoutPermissionRecordsWithANotice() async throws {
        try await withKeysRig(recordKeys: true, inputMonitoring: .denied) { rig in
            rig.controller.startRecording(selection: rig.selection, settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.controller.notices == [.keysNotRecorded])
            #expect(rig.grants == [[.screenRecording]])
            // A restart records without keys again, and says so again.
            rig.controller.restartTake()
            #expect(await eventually { rig.grants.count == 2 && rig.controller.phase.isRecordingATake })
            #expect(rig.controller.notices.last == .keysNotRecorded)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.grants == [[.screenRecording], [.screenRecording]])
            #expect(rig.probe.requests.isEmpty)
        }
    }

    @Test func keysOnWithPermissionGivesItToTheTake() async throws {
        try await withKeysRig(recordKeys: true, inputMonitoring: .granted) { rig in
            rig.controller.startRecording(selection: rig.selection, settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.controller.notices.isEmpty)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.grants == [[.screenRecording, .inputMonitoring]])
            #expect(rig.probe.requests.isEmpty)
        }
    }

    @Test func keysOffNeverAsksAboutInputMonitoring() async throws {
        for inputMonitoring in [PermissionState.granted, .denied, .notDetermined] {
            try await withKeysRig(recordKeys: false, inputMonitoring: inputMonitoring) { rig in
                rig.controller.startRecording(selection: rig.selection, settings: QuickSettings())
                #expect(await eventually { rig.controller.phase.isRecordingATake })
                #expect(rig.controller.notices.isEmpty)
                await rig.controller.stop(openingEditor: false)
                // Not even its state is read: the take does not want it.
                #expect(!rig.probe.states.contains(.inputMonitoring), "\(inputMonitoring)")
                #expect(rig.grants == [[.screenRecording]])
                #expect(rig.probe.requests.isEmpty)
            }
        }
    }

    @Test func theTakeNeverPromptsForInputMonitoring() async throws {
        // Never asked: the take does not ask (only Settings ▸ Recording does), not even while the countdown shows.
        try await withKeysRig(recordKeys: true, inputMonitoring: .notDetermined, countdown: 3) { rig in
            rig.controller.startRecording(selection: rig.selection, settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.controller.notices == [.keysNotRecorded])
            #expect(!rig.controller.isAskingPermission)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.probe.requests.isEmpty)
            #expect(rig.grants == [[.screenRecording]])
        }
    }
}

// MARK: - Rig

extension RecordingController.Phase {
    fileprivate var isRecordingATake: Bool {
        if case .recording = self { true } else { false }
    }
}

/// A defaults suite of its own, removed afterwards.
@MainActor private func withKeysDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
    let suite = "RecordKeysTests-\(UUID().uuidString)"
    let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
    defer { defaults.removePersistentDomain(forName: suite) }
    return try body(defaults)
}

/// A controller whose takes record a synthetic main display (no microphone, camera or system audio) into a fresh folder,
/// with "Record Keys to Show Them" as `recordKeys` and Input Monitoring as `inputMonitoring` (screen recording allowed).
@MainActor private func withKeysRig(
    recordKeys: Bool, inputMonitoring: PermissionState, countdown: Int = 0, _ body: (KeysRig) async throws -> Void
) async throws {
    try await withTemporaryDirectory { directory in
        let suite = "RecordKeysTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsStore(defaults: defaults).settings = RecorderSettings(countdownSeconds: countdown, recordKeys: recordKeys)
        try await body(KeysRig(
            folder: directory.appendingPathComponent("Movies/Toma", isDirectory: true), defaults: defaults,
            probe: KeysProbe([.screenRecording: .granted, .inputMonitoring: inputMonitoring])))
    }
}

@MainActor private final class KeysRig {
    private static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 64, height: 36), scale: 1, isMain: true, maximumFramesPerSecond: 60)
    ]

    let selection: CaptureSelection = {
        var selection = CaptureSelection.mainDisplay(1)
        selection.microphone = .off
        return selection
    }()
    let probe: KeysProbe
    let controller: RecordingController
    /// The permissions granted to each take, in order.
    private(set) var grants: [Set<PermissionKind>] = []
    private let disk = FakeDisk()

    init(folder: URL, defaults: UserDefaults, probe: KeysProbe) {
        self.probe = probe
        weak var rig: KeysRig?
        let disk = disk
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
                let plan = try TakePlanner.plan(
                    request.selection, settings: request.settings, displays: Self.displays, granted: granted,
                    skipping: request.skipping, includedWindowIDs: request.includedWindowIDs, factory: FakeFactory())
                let coordinator = RecordingCoordinator(
                    package: package, sources: plan.sources, input: plan.input,
                    diskMonitor: disk.monitor(volume: package.url), systemActivity: AsyncStream { $0.finish() },
                    cameraStyle: request.cameraStyle)
                return PreparedTake(
                    recording: coordinator, optional: plan.optional,
                    kinds: Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.trackID, $0.kind) }), load: plan.load,
                    microphoneMeter: plan.microphoneMeter)
            },
            termination: NoTermination(),
            now: { Date() },
            sleep: { _ in })
        controller = RecordingController(probe: probe, environment: environment, defaults: defaults)
        rig = self
    }
}

private struct NoTermination: TerminationGuarding {
    func takeBegan() {}
    func takeEnded() {}
}

/// Fixed states; it notes every permission whose state is read and every request, and a request changes nothing.
private final class KeysProbe: PermissionProbe {
    private let fixed: [PermissionKind: PermissionState]
    private let log = Mutex<(read: [PermissionKind], requested: [PermissionKind])>(([], []))

    init(_ fixed: [PermissionKind: PermissionState]) {
        self.fixed = fixed
    }

    /// The permissions whose state was read.
    var states: Set<PermissionKind> { Set(log.withLock { $0.read }) }
    /// What was requested, in order.
    var requests: [PermissionKind] { log.withLock { $0.requested } }

    func state(of kind: PermissionKind) -> PermissionState {
        log.withLock { $0.read.append(kind) }
        return fixed[kind] ?? .notDetermined
    }

    func request(_ kind: PermissionKind) async -> PermissionState {
        log.withLock { $0.requested.append(kind) }
        return fixed[kind] ?? .notDetermined
    }
}
