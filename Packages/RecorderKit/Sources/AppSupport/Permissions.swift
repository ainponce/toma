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
            })
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
        accessibilityPrompt: @escaping @Sendable () -> Void
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
    /// Whether screen recording is granted.
    public var canRecord: Bool

    public init(missing: [PermissionKind], granted: Set<PermissionKind>, canRecord: Bool) {
        self.missing = missing
        self.granted = granted
        self.canRecord = canRecord
    }

    /// Whether to record the microphone: wanted and granted.
    public var recordMicrophone: Bool { granted.contains(.microphone) }
}

/// The check before every take: screen recording is required, every other permission is optional (the take is
/// recorded without that source). Only the permissions wanted are asked about: a take never needs
/// Accessibility, and a microphone, a camera or system audio that is off is neither missing nor recorded.
public enum RecordingPreflight {
    /// `wanted` holds screen recording, plus the microphone, the camera and system audio when the take would
    /// record them (for example, not when the Mac has no microphone).
    public static func evaluate(probe: any PermissionProbe, wanted: Set<PermissionKind>) -> PreflightResult {
        let kinds = PermissionKind.allCases.filter(wanted.contains)
        let granted = Set(kinds.filter { probe.state(of: $0) == .granted })
        return PreflightResult(
            missing: kinds.filter { !granted.contains($0) },
            granted: granted,
            canRecord: granted.contains(.screenRecording))
    }
}
