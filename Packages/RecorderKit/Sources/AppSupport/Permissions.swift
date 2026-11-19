// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation
import Recording

/// A system permission the app asks for.
public enum PermissionKind: String, CaseIterable, Sendable {
    /// Required: without it nothing can be recorded.
    case screenRecording
    /// Optional: without it the take is recorded without audio.
    case microphone
    /// Optional: without it there is no camera bubble (and, once the camera is recorded, no camera track).
    /// Asked for when the camera is turned on in the island.
    case camera
    /// Optional: without it the system audio track is silent. macOS never says whether it was allowed, so once it
    /// was asked for it reads as granted, meaning requested (`SystemPermissionProbe`).
    case systemAudio
    /// Optional, and never needed to record: only to switch desktops from the island, by posting ⌃← and ⌃→
    /// (`SpaceJumper`). Asked for only when the user asks to (plan decision 27).
    case accessibility
    /// Optional, and no take wants it until the keys on screen (phase 2): only to read the keys pressed. Like
    /// Accessibility it only answers yes or no (`CGPreflightListenEventAccess`).
    case inputMonitoring
}

public enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    /// Never asked: asking shows the system prompt.
    case notDetermined
}

/// Reads and requests the permissions a recording needs.
public protocol PermissionProbe: Sendable {
    func state(of kind: PermissionKind) -> PermissionState
    /// Asks the system, which may show its prompt, and returns the state after asking.
    func request(_ kind: PermissionKind) async -> PermissionState
}

/// The permissions as macOS reports them.
///
/// Screen recording only answers yes or no (`CGPreflightScreenCaptureAccess`), so a "no" is
/// `notDetermined` until it has been requested once, and `denied` after that; the first request is
/// remembered in `defaults`. macOS may only report a screen recording permission given in System
/// Settings after the app is opened again. The microphone and the camera follow `AVCaptureDevice`'s
/// authorization status for audio and video.
/// Accessibility also only answers yes or no (`AXIsProcessTrusted`), and is remembered the same way: so
/// the second "Give Permission…" opens System Settings instead of the prompt again.
/// Input Monitoring is the same (`CGPreflightListenEventAccess`), asked for with `CGRequestListenEventAccess`.
/// System audio cannot be read at all without private API: it is `notDetermined` until it has been requested
/// once (remembered in `defaults`), and `granted` after that, which here means requested. Requesting runs a tap of
/// every app for 1 s, which makes macOS show its prompt the first time; a refused tap records silence.
public struct SystemPermissionProbe: PermissionProbe {
    /// `UserDefaults` is documented as thread-safe, but not annotated `Sendable`.
    private struct Defaults: @unchecked Sendable {
        let value: UserDefaults
    }

    private let defaults: Defaults
    private let screenPreflight: @Sendable () -> Bool
    private let screenRequest: @Sendable () -> Bool
    private let microphoneStatus: @Sendable () -> AVAuthorizationStatus
    private let microphoneRequest: @Sendable () async -> Bool
    private let cameraStatus: @Sendable () -> AVAuthorizationStatus
    private let cameraRequest: @Sendable () async -> Bool
    private let systemAudioRequest: @Sendable () async -> Void
    private let accessibilityTrusted: @Sendable () -> Bool
    private let accessibilityPrompt: @Sendable () -> Void
    private let listenPreflight: @Sendable () -> Bool
    private let listenRequest: @Sendable () -> Bool

    public init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            screenPreflight: { CGPreflightScreenCaptureAccess() },
            screenRequest: { CGRequestScreenCaptureAccess() },
            microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
            microphoneRequest: { await AVCaptureDevice.requestAccess(for: .audio) },
            cameraStatus: { AVCaptureDevice.authorizationStatus(for: .video) },
            cameraRequest: { await AVCaptureDevice.requestAccess(for: .video) },
            systemAudioRequest: { await Self.tapEveryAppBriefly() },
            accessibilityTrusted: { AXIsProcessTrusted() },
            accessibilityPrompt: {
                // The key as text, its documented value: `kAXTrustedCheckOptionPrompt` is a global C `var`, which
                // Swift 6 refuses to read ("not concurrency-safe"), with or without `takeUnretainedValue()`.
                // The prompt adds Toma to the list in System Settings and offers to open it; it returns at once.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            },
            listenPreflight: { CGPreflightListenEventAccess() },
            listenRequest: { CGRequestListenEventAccess() })
    }

    /// For tests: the system calls replaced.
    init(
        defaults: UserDefaults,
        screenPreflight: @escaping @Sendable () -> Bool,
        screenRequest: @escaping @Sendable () -> Bool,
        microphoneStatus: @escaping @Sendable () -> AVAuthorizationStatus,
        microphoneRequest: @escaping @Sendable () async -> Bool,
        cameraStatus: @escaping @Sendable () -> AVAuthorizationStatus,
        cameraRequest: @escaping @Sendable () async -> Bool,
        systemAudioRequest: @escaping @Sendable () async -> Void,
        accessibilityTrusted: @escaping @Sendable () -> Bool,
        accessibilityPrompt: @escaping @Sendable () -> Void,
        listenPreflight: @escaping @Sendable () -> Bool = { false },
        listenRequest: @escaping @Sendable () -> Bool = { false }
    ) {
        self.defaults = Defaults(value: defaults)
        self.screenPreflight = screenPreflight
        self.screenRequest = screenRequest
        self.microphoneStatus = microphoneStatus
        self.microphoneRequest = microphoneRequest
        self.cameraStatus = cameraStatus
        self.cameraRequest = cameraRequest
        self.systemAudioRequest = systemAudioRequest
        self.accessibilityTrusted = accessibilityTrusted
        self.accessibilityPrompt = accessibilityPrompt
        self.listenPreflight = listenPreflight
        self.listenRequest = listenRequest
    }

    public func state(of kind: PermissionKind) -> PermissionState {
        switch kind {
        case .screenRecording:
            if screenPreflight() { return .granted }
            return defaults.value.bool(forKey: Self.requestedKey(kind)) ? .denied : .notDetermined
        case .microphone:
            return Self.state(microphoneStatus())
        case .camera:
            return Self.state(cameraStatus())
        case .systemAudio:
            return defaults.value.bool(forKey: Self.requestedKey(kind)) ? .granted : .notDetermined
        case .accessibility:
            if accessibilityTrusted() { return .granted }
            return defaults.value.bool(forKey: Self.requestedKey(kind)) ? .denied : .notDetermined
        case .inputMonitoring:
            if listenPreflight() { return .granted }
            return defaults.value.bool(forKey: Self.requestedKey(kind)) ? .denied : .notDetermined
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .screenRecording:
            defaults.value.set(true, forKey: Self.requestedKey(kind))
            return screenRequest() ? .granted : .denied
        case .microphone:
            return await microphoneRequest() ? .granted : .denied
        case .camera:
            return await cameraRequest() ? .granted : .denied
        case .systemAudio:
            defaults.value.set(true, forKey: Self.requestedKey(kind))
            await systemAudioRequest()
            return state(of: kind)
        case .accessibility:
            defaults.value.set(true, forKey: Self.requestedKey(kind))
            accessibilityPrompt()
            return state(of: kind)
        case .inputMonitoring:
            defaults.value.set(true, forKey: Self.requestedKey(kind))
            return listenRequest() ? .granted : .denied
        }
    }

    private static func state(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// The defaults key that says `kind` has been requested at least once.
    static func requestedKey(_ kind: PermissionKind) -> String {
        "permissionRequested.\(kind.rawValue)"
    }

    /// Taps every app for 1 s and throws the sound away: the first tap makes macOS ask for the permission. Returns
    /// once the tap is torn down, also when it could not start.
    private static func tapEveryAppBriefly() async {
        let tap = ProcessTapSource(scope: .all)
        do {
            try await tap.start(on: DispatchSerialQueue(label: "dev.toma.SystemPermissionProbe.systemAudio"), sink: DiscardingSink())
            try await Task.sleep(for: .seconds(1))
        } catch {
            // Refused, or the tap could not be made: there is nothing more to ask.
        }
        await tap.stop()
    }
}

/// Throws away what a source delivers.
private final class DiscardingSink: CaptureSink {
    func source(_ trackID: String, didOutput sample: CMSampleBuffer) {}
    func source(_ trackID: String, didStopWithError error: any Error) {}
}

/// What asking for a permission does, by its state (plan decision 27): the system's prompt the first time,
/// which already offers to open System Settings; System Settings once it was asked for (macOS prompts only
/// once); never both. Nothing once it is granted.
public enum PermissionAction: Equatable, Sendable {
    case prompt
    case openSettings

    public init?(for state: PermissionState) {
        switch state {
        case .granted: return nil
        case .notDetermined: self = .prompt
        case .denied: self = .openSettings
        }
    }
}

/// "Open System Settings" for a permission that was asked for and is still not allowed.
///
/// macOS can forget an app it was asked about: after `tccutil reset`, or when a new build without a stable
/// signature counts as another app. Toma is then missing from the list in System Settings, or listed under a
/// switch that no longer applies to it, and there is nothing to turn on. So screen recording, Accessibility and Input Monitoring
/// are asked for again first: that puts Toma back in the list, and shows the system's prompt if macOS had
/// forgotten it. System Settings opens only when no prompt came up (the prompt already offers to open it), so
/// never both; nothing opens once asking again allowed it. The microphone and the camera go straight to System
/// Settings: macOS reports when it forgot them (`notDetermined`), and asking again after a no shows nothing.
@MainActor
public struct PermissionSettingsOpener {
    private let probe: any PermissionProbe
    /// The app in front, to tell whether the system's prompt came up: it comes up in front.
    private let frontmostApp: @MainActor () -> Int32?
    /// Waits for the prompt, which comes up a moment after the request returns.
    private let settle: @Sendable () async -> Void
    private let openURL: @MainActor (URL) -> Void

    public init(
        probe: any PermissionProbe,
        frontmostApp: @escaping @MainActor () -> Int32?,
        settle: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(600)) },
        openURL: @escaping @MainActor (URL) -> Void
    ) {
        self.probe = probe
        self.frontmostApp = frontmostApp
        self.settle = settle
        self.openURL = openURL
    }

    /// Whether macOS needs to be asked again before System Settings is of any use for `kind`.
    static func asksAgain(_ kind: PermissionKind) -> Bool {
        kind == .screenRecording || kind == .accessibility || kind == .inputMonitoring
    }

    /// Asks again when that helps, then opens System Settings unless a prompt came up or the permission is now
    /// allowed. Returns the permission's state after asking.
    @discardableResult
    public func open(_ kind: PermissionKind) async -> PermissionState {
        guard Self.asksAgain(kind) else {
            openURL(PermissionSettings.url(for: kind))
            return probe.state(of: kind)
        }
        let before = frontmostApp()
        let state = await probe.request(kind)
        guard state != .granted else { return state }
        await settle()
        guard frontmostApp() == before else { return probe.state(of: kind) }
        openURL(PermissionSettings.url(for: kind))
        return probe.state(of: kind)
    }
}

/// Where System Settings lets the user change a permission.
public enum PermissionSettings {
    public static func url(for kind: PermissionKind) -> URL {
        let pane = switch kind {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        // "Screen & System Audio Recording": an app that only records audio is listed there, under "System Audio
        // Recording Only".
        case .systemAudio: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// Whether a take can start, and with which sources.
public struct PreflightResult: Equatable, Sendable {
    /// The permissions wanted that are not granted, in the order of `PermissionKind.allCases`.
    public var missing: [PermissionKind]
    /// The permissions wanted that are granted: the sources the take can record.
    public var granted: Set<PermissionKind>
    /// Whether the permission the take cannot do without is granted: screen recording, or the camera's for an iPhone.
    public var canRecord: Bool

    public init(missing: [PermissionKind], granted: Set<PermissionKind>, canRecord: Bool) {
        self.missing = missing
        self.granted = granted
        self.canRecord = canRecord
    }

    /// Whether to record the microphone: wanted and granted.
    public var recordMicrophone: Bool { granted.contains(.microphone) }
}

/// The check before every take: one permission is required (screen recording; for an iPhone or iPad, the camera's),
/// every other permission is optional (the take is recorded without that source). Only the permissions wanted are
/// asked about: a take never needs Accessibility, and a microphone, a camera or system audio that is off is neither
/// missing nor recorded.
public enum RecordingPreflight {
    /// `wanted` holds the `required` permission, plus the microphone, the camera and system audio when the take would
    /// record them (for example, not when the Mac has no microphone); `required` is asked about even if it does not.
    public static func evaluate(
        probe: any PermissionProbe, wanted: Set<PermissionKind>, required: PermissionKind = .screenRecording
    ) -> PreflightResult {
        let kinds = PermissionKind.allCases.filter { wanted.contains($0) || $0 == required }
        let granted = Set(kinds.filter { probe.state(of: $0) == .granted })
        return PreflightResult(
            missing: kinds.filter { !granted.contains($0) },
            granted: granted,
            canRecord: granted.contains(required))
    }
}
