// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
@testable import AppSupport
import Foundation
import Synchronization
import Testing

/// Answers with fixed states; a request answers the same state.
struct FakeProbe: PermissionProbe {
    var screen: PermissionState
    var mic: PermissionState
    var accessibility: PermissionState = .notDetermined
    var camera: PermissionState = .notDetermined
    var systemAudio: PermissionState = .notDetermined

    func state(of kind: PermissionKind) -> PermissionState {
        switch kind {
        case .screenRecording: screen
        case .microphone: mic
        case .camera: camera
        case .systemAudio: systemAudio
        case .accessibility: accessibility
        }
    }

    func request(_ kind: PermissionKind) async -> PermissionState {
        state(of: kind)
    }
}

// MARK: - Preflight

@Test func cannotRecordWithoutScreenPermission() {
    let r = RecordingPreflight.evaluate(probe: FakeProbe(screen: .denied, mic: .granted), wanted: [.screenRecording, .microphone])
    #expect(r.canRecord == false && r.missing == [.screenRecording])
}

@Test func recordsWithoutMicWhenMicDenied() {
    let r = RecordingPreflight.evaluate(probe: FakeProbe(screen: .granted, mic: .denied), wanted: [.screenRecording, .microphone])
    #expect(r.canRecord && r.recordMicrophone == false && r.missing == [.microphone])
}

@Test func recordsScreenAndMicWhenBothAreGranted() {
    let r = RecordingPreflight.evaluate(probe: FakeProbe(screen: .granted, mic: .granted), wanted: [.screenRecording, .microphone])
    #expect(r == PreflightResult(missing: [], granted: [.screenRecording, .microphone], canRecord: true))
    #expect(r.recordMicrophone)
}

@Test func missingListsEveryPermissionNotGrantedYetInOrder() {
    let r = RecordingPreflight.evaluate(
        probe: FakeProbe(screen: .notDetermined, mic: .notDetermined), wanted: [.screenRecording, .microphone])
    #expect(r == PreflightResult(missing: [.screenRecording, .microphone], granted: [], canRecord: false))
    #expect(!r.recordMicrophone)
}

@Test func microphoneNotWantedIsNeitherMissingNorRecorded() {
    let r = RecordingPreflight.evaluate(probe: FakeProbe(screen: .granted, mic: .denied), wanted: [.screenRecording])
    #expect(r == PreflightResult(missing: [], granted: [.screenRecording], canRecord: true))
    #expect(!r.recordMicrophone)
}

@Test func optionalPermissionsAreNeverMissing() {
    for (accessibility, camera) in [(PermissionState.notDetermined, PermissionState.notDetermined), (.denied, .denied)] {
        let probe = FakeProbe(screen: .granted, mic: .granted, accessibility: accessibility, camera: camera, systemAudio: camera)
        #expect(RecordingPreflight.evaluate(probe: probe, wanted: [.screenRecording, .microphone])
            == PreflightResult(missing: [], granted: [.screenRecording, .microphone], canRecord: true))
        let missing = FakeProbe(screen: .denied, mic: .notDetermined, accessibility: accessibility, camera: camera, systemAudio: camera)
        #expect(RecordingPreflight.evaluate(probe: missing, wanted: [.screenRecording, .microphone]).missing == [.screenRecording, .microphone])
    }
}

@Test func systemAudioCountsOnlyWhenWantedAndNeverBlocks() {
    let unasked = FakeProbe(screen: .granted, mic: .granted, systemAudio: .notDetermined)
    #expect(RecordingPreflight.evaluate(probe: unasked, wanted: [.screenRecording, .systemAudio])
        == PreflightResult(missing: [.systemAudio], granted: [.screenRecording], canRecord: true))
    let requested = FakeProbe(screen: .granted, mic: .granted, systemAudio: .granted)
    #expect(RecordingPreflight.evaluate(probe: requested, wanted: [.systemAudio, .microphone, .screenRecording])
        == PreflightResult(missing: [], granted: [.screenRecording, .microphone, .systemAudio], canRecord: true))
    // Without screen recording nothing records, system audio or not.
    let noScreen = FakeProbe(screen: .denied, mic: .granted, systemAudio: .granted)
    #expect(!RecordingPreflight.evaluate(probe: noScreen, wanted: [.screenRecording, .systemAudio]).canRecord)
}

@Test func cameraDeniedRecordsWithoutCamera() {
    let probe = FakeProbe(screen: .granted, mic: .granted, camera: .denied)
    let r = RecordingPreflight.evaluate(probe: probe, wanted: [.screenRecording, .camera])
    #expect(r.canRecord && r.missing == [.camera] && r.granted == [.screenRecording])
    #expect(!r.recordMicrophone)
}

@Test func missingFollowsThePermissionOrderWhateverTheWantedOrder() {
    let probe = FakeProbe(screen: .notDetermined, mic: .denied, camera: .notDetermined)
    let r = RecordingPreflight.evaluate(probe: probe, wanted: [.camera, .microphone, .screenRecording])
    #expect(r == PreflightResult(missing: [.screenRecording, .microphone, .camera], granted: [], canRecord: false))
    let granted = FakeProbe(screen: .granted, mic: .granted, camera: .granted)
    #expect(RecordingPreflight.evaluate(probe: granted, wanted: [.camera, .screenRecording, .microphone])
        == PreflightResult(missing: [], granted: [.screenRecording, .microphone, .camera], canRecord: true))
}

// MARK: - System Settings

@Test func askingPromptsFirstThenOpensSettings() {
    #expect(PermissionAction(for: .notDetermined) == .prompt)
    #expect(PermissionAction(for: .denied) == .openSettings)
    #expect(PermissionAction(for: .granted) == nil)
}

@Test func settingsOpenThePrivacyPaneOfEachPermission() {
    #expect(PermissionSettings.url(for: .screenRecording).absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    #expect(PermissionSettings.url(for: .microphone).absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    #expect(PermissionSettings.url(for: .accessibility).absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    #expect(PermissionSettings.url(for: .camera).absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    // System audio is in the same pane as screen recording ("Screen & System Audio Recording").
    #expect(PermissionSettings.url(for: .systemAudio).absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
}

/// A probe that counts its requests and answers `answer` to each.
final class AskedProbe: PermissionProbe, @unchecked Sendable {
    let base: FakeProbe
    let answer: PermissionState?
    private let lock = Mutex<[PermissionKind]>([])
    var requests: [PermissionKind] { lock.withLock { $0 } }

    init(_ base: FakeProbe, answer: PermissionState? = nil) {
        self.base = base
        self.answer = answer
    }

    func state(of kind: PermissionKind) -> PermissionState {
        answer.map { requests.contains(kind) ? $0 : base.state(of: kind) } ?? base.state(of: kind)
    }

    func request(_ kind: PermissionKind) async -> PermissionState {
        lock.withLock { $0.append(kind) }
        return state(of: kind)
    }
}

/// Opens System Settings with `probe`; `promptComesUp` puts another app in front between asking and settling.
@MainActor
func openSettings(_ kind: PermissionKind, probe: AskedProbe, promptComesUp: Bool = false) async -> [URL] {
    var front: Int32 = 100
    var opened: [URL] = []
    let opener = PermissionSettingsOpener(
        probe: probe,
        frontmostApp: {
            defer { if promptComesUp { front = 200 } }
            return front
        },
        settle: {}, openURL: { opened.append($0) })
    await opener.open(kind)
    return opened
}

@Test func screenRecordingIsAskedForAgainBeforeSystemSettingsSoTomaIsBackInTheList() async {
    for kind in [PermissionKind.screenRecording, .accessibility] {
        let probe = AskedProbe(FakeProbe(screen: .denied, mic: .granted, accessibility: .denied))
        #expect(await openSettings(kind, probe: probe) == [PermissionSettings.url(for: kind)])
        #expect(probe.requests == [kind])
    }
}

@Test func systemSettingsStayClosedWhenTheSystemPromptCameUp() async {
    let probe = AskedProbe(FakeProbe(screen: .denied, mic: .granted))
    #expect(await openSettings(.screenRecording, probe: probe, promptComesUp: true).isEmpty)
    #expect(probe.requests == [.screenRecording])
}

@Test func nothingOpensWhenAskingAgainAllowedIt() async {
    let probe = AskedProbe(FakeProbe(screen: .denied, mic: .granted), answer: .granted)
    #expect(await openSettings(.screenRecording, probe: probe).isEmpty)
}

@Test func theMicrophoneAndTheCameraGoStraightToSystemSettings() async {
    for kind in [PermissionKind.microphone, .camera] {
        let probe = AskedProbe(FakeProbe(screen: .granted, mic: .denied, camera: .denied))
        #expect(await openSettings(kind, probe: probe) == [PermissionSettings.url(for: kind)])
        #expect(probe.requests.isEmpty)
    }
}

// MARK: - System probe

/// A defaults suite of its own, removed when `body` returns.
func withDefaults<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
    let name = "AppSupportTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    return try await body(defaults)
}

/// What the probe asks the system, with answers the test sets.
final class FakeSystem: Sendable {
    let screenAllowed = Atomic(false)
    let screenRequests = Atomic(0)
    let microphone = Mutex(AVAuthorizationStatus.notDetermined)
    let microphoneAnswer = Atomic(false)
    let camera = Mutex(AVAuthorizationStatus.notDetermined)
    let cameraAnswer = Atomic(false)
    let cameraRequests = Atomic(0)
    let systemAudioRequests = Atomic(0)
    let accessibilityTrusted = Atomic(false)
    let accessibilityPrompts = Atomic(0)

    func probe(_ defaults: UserDefaults) -> SystemPermissionProbe {
        SystemPermissionProbe(
            defaults: defaults,
            screenPreflight: { self.screenAllowed.load(ordering: .relaxed) },
            screenRequest: {
                self.screenRequests.add(1, ordering: .relaxed)
                return self.screenAllowed.load(ordering: .relaxed)
            },
            microphoneStatus: { self.microphone.withLock { $0 } },
            microphoneRequest: { self.microphoneAnswer.load(ordering: .relaxed) },
            cameraStatus: { self.camera.withLock { $0 } },
            cameraRequest: {
                self.cameraRequests.add(1, ordering: .relaxed)
                return self.cameraAnswer.load(ordering: .relaxed)
            },
            systemAudioRequest: { self.systemAudioRequests.add(1, ordering: .relaxed) },
            accessibilityTrusted: { self.accessibilityTrusted.load(ordering: .relaxed) },
            accessibilityPrompt: { self.accessibilityPrompts.add(1, ordering: .relaxed) })
    }
}

@Test func screenRecordingIsNotDeterminedUntilRequestedThenDenied() async {
    await withDefaults { defaults in
        let system = FakeSystem()
        let probe = system.probe(defaults)
        #expect(probe.state(of: .screenRecording) == .notDetermined)
        #expect(await probe.request(.screenRecording) == .denied)
        #expect(system.screenRequests.load(ordering: .relaxed) == 1)
        #expect(probe.state(of: .screenRecording) == .denied)
        // Remembered in the defaults, not in the probe.
        #expect(system.probe(defaults).state(of: .screenRecording) == .denied)
    }
}

@Test func screenRecordingAllowedIsGrantedWithOrWithoutARequest() async {
    await withDefaults { defaults in
        let system = FakeSystem()
        system.screenAllowed.store(true, ordering: .relaxed)
        let probe = system.probe(defaults)
        #expect(probe.state(of: .screenRecording) == .granted)
        #expect(await probe.request(.screenRecording) == .granted)
        #expect(probe.state(of: .screenRecording) == .granted)
    }
}

@Test(arguments: [
    (AVAuthorizationStatus.notDetermined, PermissionState.notDetermined),
    (.authorized, .granted),
    (.denied, .denied),
    (.restricted, .denied),
])
func microphoneFollowsTheAuthorizationStatus(status: AVAuthorizationStatus, expected: PermissionState) async {
    await withDefaults { defaults in
        let system = FakeSystem()
        system.microphone.withLock { $0 = status }
        #expect(system.probe(defaults).state(of: .microphone) == expected)
    }
}

@Test(arguments: [(true, PermissionState.granted), (false, .denied)])
func microphoneRequestGivesTheAnswer(answer: Bool, expected: PermissionState) async {
    await withDefaults { defaults in
        let system = FakeSystem()
        system.microphoneAnswer.store(answer, ordering: .relaxed)
        let probe = system.probe(defaults)
        #expect(await probe.request(.microphone) == expected)
        // Asking about the microphone leaves the screen recording state alone.
        #expect(probe.state(of: .screenRecording) == .notDetermined)
    }
}

@Test(arguments: [
    (AVAuthorizationStatus.notDetermined, PermissionState.notDetermined),
    (.authorized, .granted),
    (.denied, .denied),
    (.restricted, .denied),
])
func cameraFollowsTheAuthorizationStatus(status: AVAuthorizationStatus, expected: PermissionState) async {
    await withDefaults { defaults in
        let system = FakeSystem()
        system.camera.withLock { $0 = status }
        // Its own status: the microphone's says nothing about it.
        system.microphone.withLock { $0 = .authorized }
        #expect(system.probe(defaults).state(of: .camera) == expected)
    }
}

@Test(arguments: [(true, PermissionState.granted), (false, .denied)])
func cameraRequestGivesTheAnswer(answer: Bool, expected: PermissionState) async {
    await withDefaults { defaults in
        let system = FakeSystem()
        system.cameraAnswer.store(answer, ordering: .relaxed)
        let probe = system.probe(defaults)
        #expect(await probe.request(.camera) == expected)
        #expect(system.cameraRequests.load(ordering: .relaxed) == 1)
        // Asking about the camera leaves the others alone.
        #expect(probe.state(of: .microphone) == .notDetermined && probe.state(of: .screenRecording) == .notDetermined)
    }
}

@Test func systemAudioPermissionIsUnknownUntilRequested() async {
    await withDefaults { defaults in
        let system = FakeSystem()
        let probe = system.probe(defaults)
        #expect(probe.state(of: .systemAudio) == .notDetermined)
        #expect(system.systemAudioRequests.load(ordering: .relaxed) == 0)
        // macOS never says whether it was allowed: once asked, it is "granted", meaning requested.
        #expect(await probe.request(.systemAudio) == .granted)
        #expect(system.systemAudioRequests.load(ordering: .relaxed) == 1)
        #expect(probe.state(of: .systemAudio) == .granted)
        #expect(defaults.bool(forKey: "permissionRequested.systemAudio"))
        // Remembered in the defaults; the other permissions are left alone.
        #expect(system.probe(defaults).state(of: .systemAudio) == .granted)
        #expect(probe.state(of: .screenRecording) == .notDetermined && probe.state(of: .accessibility) == .notDetermined)
        #expect(system.screenRequests.load(ordering: .relaxed) == 0 && system.accessibilityPrompts.load(ordering: .relaxed) == 0)
    }
}

@Test func accessibilityFollowsTrust() async {
    await withDefaults { defaults in
        let system = FakeSystem()
        let probe = system.probe(defaults)
        #expect(probe.state(of: .accessibility) == .notDetermined)
        // The prompt only adds Toma to the list: the user has not allowed it yet.
        #expect(await probe.request(.accessibility) == .denied)
        #expect(system.accessibilityPrompts.load(ordering: .relaxed) == 1)
        #expect(probe.state(of: .accessibility) == .denied)
        #expect(defaults.bool(forKey: "permissionRequested.accessibility"))
        // Remembered in the defaults; the other permissions are left alone.
        #expect(system.probe(defaults).state(of: .accessibility) == .denied)
        #expect(probe.state(of: .screenRecording) == .notDetermined)

        system.accessibilityTrusted.store(true, ordering: .relaxed)
        #expect(probe.state(of: .accessibility) == .granted)
        #expect(await probe.request(.accessibility) == .granted)
    }
    await withDefaults { defaults in
        // Allowed in System Settings without being asked.
        let system = FakeSystem()
        system.accessibilityTrusted.store(true, ordering: .relaxed)
        #expect(system.probe(defaults).state(of: .accessibility) == .granted)
        #expect(system.accessibilityPrompts.load(ordering: .relaxed) == 0)
    }
}
