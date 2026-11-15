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

    func state(of kind: PermissionKind) -> PermissionState {
        switch kind {
        case .screenRecording: screen
        case .microphone: mic
        case .accessibility: accessibility
        }
    }

    func request(_ kind: PermissionKind) async -> PermissionState {
        state(of: kind)
    }
}

// MARK: - Preflight

@Test func cannotRecordWithoutScreenPermission() {
    let r = RecordingPreflight.evaluate(probe: FakeProbe(screen: .denied, mic: .granted), wantsMicrophone: true)
    #expect(r.canRecord == false && r.missing == [.screenRecording])
}

@Test func recordsWithoutMicWhenMicDenied() {
    let r = RecordingPreflight.evaluate(probe: FakeProbe(screen: .granted, mic: .denied), wantsMicrophone: true)
    #expect(r.canRecord && r.recordMicrophone == false && r.missing == [.microphone])
}

@Test func recordsScreenAndMicWhenBothAreGranted() {
    let r = RecordingPreflight.evaluate(probe: FakeProbe(screen: .granted, mic: .granted), wantsMicrophone: true)
    #expect(r == PreflightResult(missing: [], recordMicrophone: true, canRecord: true))
}

@Test func missingListsEveryPermissionNotGrantedYetInOrder() {
    let r = RecordingPreflight.evaluate(probe: FakeProbe(screen: .notDetermined, mic: .notDetermined), wantsMicrophone: true)
    #expect(r == PreflightResult(missing: [.screenRecording, .microphone], recordMicrophone: false, canRecord: false))
}

@Test func microphoneNotWantedIsNeitherMissingNorRecorded() {
    let r = RecordingPreflight.evaluate(probe: FakeProbe(screen: .granted, mic: .denied), wantsMicrophone: false)
    #expect(r == PreflightResult(missing: [], recordMicrophone: false, canRecord: true))
}

@Test func optionalPermissionsAreNeverMissing() {
    for accessibility in [PermissionState.notDetermined, .denied] {
        let probe = FakeProbe(screen: .granted, mic: .granted, accessibility: accessibility)
        #expect(RecordingPreflight.evaluate(probe: probe, wantsMicrophone: true) == PreflightResult(missing: [], recordMicrophone: true, canRecord: true))
        let missing = FakeProbe(screen: .denied, mic: .notDetermined, accessibility: accessibility)
        #expect(RecordingPreflight.evaluate(probe: missing, wantsMicrophone: true).missing == [.screenRecording, .microphone])
    }
}

// MARK: - System Settings

@Test func settingsOpenThePrivacyPaneOfEachPermission() {
    #expect(PermissionSettings.url(for: .screenRecording).absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    #expect(PermissionSettings.url(for: .microphone).absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    #expect(PermissionSettings.url(for: .accessibility).absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
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
