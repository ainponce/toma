// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Synchronization
import Testing

// "Follow Keyboard Focus" (`RecorderSettings.recordFocus`): off unless the user turns it on, an `AccessibilityFocusRecorder`
// in the take's input only then, and Accessibility wanted by the take's check but never asked for by it: without it the
// take records all the same, without focus, and says so (`TakeNotice.keyboardFocusNotRecorded`).

@MainActor @Suite(.serialized) struct RecordFocusTests {
    @Test func recordFocusIsOffByDefaultAndReadsOldSettings() throws {
        #expect(!RecorderSettings().recordFocus)
        try withFocusDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(!store.settings.recordFocus)

            // Saved by the phase 3 version, and by the one with share and replay: no setting, the rest is kept.
            defaults.set(Data(#"{"countdownSeconds":5,"noteKeyActivity":false}"#.utf8), forKey: SettingsStore.key)
            #expect(!store.settings.recordFocus && store.settings.countdownSeconds == 5 && !store.settings.noteKeyActivity)
            defaults.set(
                Data(#"{"countdownSeconds":3,"recordKeys":true,"share":{},"replay":{}}"#.utf8), forKey: SettingsStore.key)
            #expect(!store.settings.recordFocus && store.settings.countdownSeconds == 3 && store.settings.recordKeys)

            var settings = store.settings
            settings.recordFocus = true
            store.settings = settings
            #expect(SettingsStore(defaults: defaults).settings == settings)
            #expect(SettingsStore(defaults: defaults).settings.recordFocus)

            // A value this version cannot read: off, and the rest is kept.
            defaults.set(Data(#"{"countdownSeconds":10,"recordFocus":"yes"}"#.utf8), forKey: SettingsStore.key)
            #expect(!store.settings.recordFocus && store.settings.countdownSeconds == 10)
        }
    }

    @Test func inputHasTheFocusRecorderOnlyWhenAsked() throws {
        for recordFocus in [false, true] {
            let factory = LiveCaptureSourceFactory(
                cameraHost: CameraSessionHost(), noteKeyActivity: true, recordKeys: true, recordFocus: recordFocus) { _ in }
            let input = try #require(factory.input(windowTrack: nil, displayIDs: []) as? CompositeInputRecorder)
            #expect(input.recorders.count { $0 is AccessibilityFocusRecorder } == (recordFocus ? 1 : 0), "recordFocus \(recordFocus)")
            // The keys do not change.
            #expect(input.recorders.count { $0 is KeyPressRecorder } == 1)
            #expect(input.recorders.count { $0 is KeyActivityRecorder } == 1)
        }
        // Off unless asked for.
        let factory = LiveCaptureSourceFactory(cameraHost: CameraSessionHost(), noteKeyActivity: false) { _ in }
        let input = try #require(factory.input(windowTrack: nil, displayIDs: []) as? CompositeInputRecorder)
        #expect(!input.recorders.contains { $0 is AccessibilityFocusRecorder })
    }

    @Test func focusOnWithoutAccessibilityRecordsWithANotice() async throws {
        try await withFocusRig(recordFocus: true, accessibility: .denied) { rig in
            rig.controller.startRecording(selection: rig.selection, settings: QuickSettings())
            #expect(await eventually { rig.controller.isRecordingATake })
            #expect(rig.controller.notices == [.keyboardFocusNotRecorded])
            #expect(rig.grants == [[.screenRecording]])
            // A restart records without focus again, and says so again.
            rig.controller.restartTake()
            #expect(await eventually { rig.grants.count == 2 && rig.controller.isRecordingATake })
            #expect(rig.controller.notices.last == .keyboardFocusNotRecorded)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.grants == [[.screenRecording], [.screenRecording]])
            #expect(rig.probe.requests.isEmpty)
        }
    }

    @Test func focusOnWithAccessibilityGivesItToTheTake() async throws {
        try await withFocusRig(recordFocus: true, accessibility: .granted) { rig in
            rig.controller.startRecording(selection: rig.selection, settings: QuickSettings())
            #expect(await eventually { rig.controller.isRecordingATake })
            #expect(rig.controller.notices.isEmpty)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.grants == [[.screenRecording, .accessibility]])
            #expect(rig.probe.requests.isEmpty)
        }
    }

    @Test func focusOffNeverAsksAboutAccessibility() async throws {
        for accessibility in [PermissionState.granted, .denied, .notDetermined] {
            try await withFocusRig(recordFocus: false, accessibility: accessibility) { rig in
                rig.controller.startRecording(selection: rig.selection, settings: QuickSettings())
                #expect(await eventually { rig.controller.isRecordingATake })
                #expect(rig.controller.notices.isEmpty)
                await rig.controller.stop(openingEditor: false)
                // Not even its state is read: the take does not want it.
                #expect(!rig.probe.states.contains(.accessibility), "\(accessibility)")
                #expect(rig.grants == [[.screenRecording]])
                #expect(rig.probe.requests.isEmpty)
            }
        }
    }

    @Test func theTakeNeverPromptsForAccessibility() async throws {
        // Never asked: a system prompt would be in the video. Not even while the countdown shows.
        try await withFocusRig(recordFocus: true, accessibility: .notDetermined, countdown: 3) { rig in
            rig.controller.startRecording(selection: rig.selection, settings: QuickSettings())
            #expect(await eventually { rig.controller.isRecordingATake })
            #expect(rig.controller.notices == [.keyboardFocusNotRecorded])
            #expect(!rig.controller.isAskingPermission)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.probe.requests.isEmpty)
            #expect(rig.grants == [[.screenRecording]])
        }
    }

    @Test func keysAndFocusLiveTogether() async throws {
        try await withFocusRig(recordFocus: true, recordKeys: true, accessibility: .granted, inputMonitoring: .granted) { rig in
            rig.controller.startRecording(selection: rig.selection, settings: QuickSettings())
            #expect(await eventually { rig.controller.isRecordingATake })
            #expect(rig.controller.notices.isEmpty)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.grants == [[.screenRecording, .accessibility, .inputMonitoring]])
        }
    }

    @Test func hasFocusNeedsAFocusEvent() {
        let others: [InputEvent] = [
            InputEvent(t: HostTime(nanoseconds: 0), kind: .keyActivity), InputEvent(t: HostTime(nanoseconds: 1), kind: .mouseDown(.left, x: 1, y: 2))
        ]
        #expect(!ZoomPanelRules.hasFocus(events: []))
        #expect(!ZoomPanelRules.hasFocus(events: others))
        #expect(ZoomPanelRules.hasFocus(
            events: others + [InputEvent(t: HostTime(nanoseconds: 2), kind: .focus(x: 1, y: 2, width: 3, height: 4, kind: .element))]))
        #expect(ZoomPanelRules.hasFocus(events: [InputEvent(t: HostTime(nanoseconds: 2), kind: .focus(x: 1, y: 2, width: 0, height: 4, kind: .caret))]))
    }
}

// MARK: - Rig

extension RecordingController {
    fileprivate var isRecordingATake: Bool {
        if case .recording = phase { true } else { false }
    }
}

/// A defaults suite of its own, removed afterwards.
@MainActor private func withFocusDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
    let suite = "RecordFocusTests-\(UUID().uuidString)"
    let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
    defer { defaults.removePersistentDomain(forName: suite) }
    return try body(defaults)
}

/// A controller whose takes record a synthetic main display (no microphone, camera or system audio) into a fresh folder,
/// with "Follow Keyboard Focus" as `recordFocus` and Accessibility as `accessibility` (screen recording allowed).
@MainActor private func withFocusRig(
    recordFocus: Bool, recordKeys: Bool = false, accessibility: PermissionState, inputMonitoring: PermissionState = .granted,
    countdown: Int = 0, _ body: (FocusRig) async throws -> Void
) async throws {
    try await withTemporaryDirectory { directory in
        let suite = "RecordFocusTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsStore(defaults: defaults).settings = RecorderSettings(
            countdownSeconds: countdown, recordKeys: recordKeys, recordFocus: recordFocus)
        try await body(FocusRig(
            folder: directory.appendingPathComponent("Movies/Toma", isDirectory: true), defaults: defaults,
            probe: FocusProbe([.screenRecording: .granted, .accessibility: accessibility, .inputMonitoring: inputMonitoring])))
    }
}

@MainActor private final class FocusRig {
    private static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 64, height: 36), scale: 1, isMain: true, maximumFramesPerSecond: 60)
    ]

    let selection: CaptureSelection = {
        var selection = CaptureSelection.mainDisplay(1)
        selection.microphone = .off
        return selection
    }()
    let probe: FocusProbe
    let controller: RecordingController
    /// The permissions granted to each take, in order.
    private(set) var grants: [Set<PermissionKind>] = []
    private let disk = FakeDisk()

    init(folder: URL, defaults: UserDefaults, probe: FocusProbe) {
        self.probe = probe
        weak var rig: FocusRig?
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
            termination: FocusNoTermination(),
            now: { Date() },
            sleep: { _ in })
        controller = RecordingController(probe: probe, environment: environment, defaults: defaults)
        rig = self
    }
}

private struct FocusNoTermination: TerminationGuarding {
    func takeBegan() {}
    func takeEnded() {}
}

/// Fixed states; it notes every permission whose state is read and every request, and a request changes nothing.
private final class FocusProbe: PermissionProbe {
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
