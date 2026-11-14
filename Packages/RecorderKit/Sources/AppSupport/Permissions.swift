// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import Foundation

/// A system permission a recording needs.
public enum PermissionKind: String, CaseIterable, Sendable {
    /// Required: without it nothing can be recorded.
    case screenRecording
    /// Optional: without it the take is recorded without audio.
    case microphone
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
/// Settings after the app is opened again. The microphone follows `AVCaptureDevice`'s authorization status.
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

    public init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            screenPreflight: { CGPreflightScreenCaptureAccess() },
            screenRequest: { CGRequestScreenCaptureAccess() },
            microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
            microphoneRequest: { await AVCaptureDevice.requestAccess(for: .audio) })
    }

    /// For tests: the system calls replaced.
    init(
        defaults: UserDefaults,
        screenPreflight: @escaping @Sendable () -> Bool,
        screenRequest: @escaping @Sendable () -> Bool,
        microphoneStatus: @escaping @Sendable () -> AVAuthorizationStatus,
        microphoneRequest: @escaping @Sendable () async -> Bool
    ) {
        self.defaults = Defaults(value: defaults)
        self.screenPreflight = screenPreflight
        self.screenRequest = screenRequest
        self.microphoneStatus = microphoneStatus
        self.microphoneRequest = microphoneRequest
    }

    public func state(of kind: PermissionKind) -> PermissionState {
        switch kind {
        case .screenRecording:
            if screenPreflight() { return .granted }
            return defaults.value.bool(forKey: Self.requestedKey(kind)) ? .denied : .notDetermined
        case .microphone:
            switch microphoneStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default: return .denied
            }
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .screenRecording:
            defaults.value.set(true, forKey: Self.requestedKey(kind))
            return screenRequest() ? .granted : .denied
        case .microphone:
            return await microphoneRequest() ? .granted : .denied
        }
    }

    /// The defaults key that says `kind` has been requested at least once.
    static func requestedKey(_ kind: PermissionKind) -> String {
        "permissionRequested.\(kind.rawValue)"
    }
}

/// Where System Settings lets the user change a permission.
public enum PermissionSettings {
    public static func url(for kind: PermissionKind) -> URL {
        let pane = switch kind {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// Whether a take can start, and with which sources.
public struct PreflightResult: Equatable, Sendable {
    /// The permissions wanted that are not granted, in `PermissionKind.allCases` order.
    public var missing: [PermissionKind]
    /// Whether to record the microphone: wanted and granted.
    public var recordMicrophone: Bool
    /// Whether screen recording is granted.
    public var canRecord: Bool

    public init(missing: [PermissionKind], recordMicrophone: Bool, canRecord: Bool) {
        self.missing = missing
        self.recordMicrophone = recordMicrophone
        self.canRecord = canRecord
    }
}

/// The check before every take: screen recording is required, the microphone is optional.
public enum RecordingPreflight {
    /// `wantsMicrophone` is false when the take should not record audio (for example, the Mac has no
    /// microphone): the microphone is then neither missing nor recorded.
    public static func evaluate(probe: any PermissionProbe, wantsMicrophone: Bool) -> PreflightResult {
        let wanted = PermissionKind.allCases.filter { $0 != .microphone || wantsMicrophone }
        let states = Dictionary(uniqueKeysWithValues: wanted.map { ($0, probe.state(of: $0)) })
        return PreflightResult(
            missing: wanted.filter { states[$0] != .granted },
            recordMicrophone: states[.microphone] == .granted,
            canRecord: states[.screenRecording] == .granted)
    }
}
