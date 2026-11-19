// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation

/// The system's microphone mode (Control Center ▸ Mic Mode) as the island names it. The mode is the system's:
/// Toma shows the active one and opens the system picker, it never sets it.
public enum MicrophoneModeKind: Equatable, Sendable, CaseIterable {
    case standard, voiceIsolation, wideSpectrum

    /// A mode this macOS adds later reads as Standard.
    public init(_ mode: AVCaptureDevice.MicrophoneMode) {
        switch mode {
        case .voiceIsolation: self = .voiceIsolation
        case .wideSpectrum: self = .wideSpectrum
        default: self = .standard
        }
    }
}
