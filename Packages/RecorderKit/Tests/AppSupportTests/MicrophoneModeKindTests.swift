// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Testing

@testable import AppSupport

@Suite struct MicrophoneModeKindTests {
    @Test func systemModesMapToTheirKinds() {
        #expect(MicrophoneModeKind(.standard) == .standard)
        #expect(MicrophoneModeKind(.voiceIsolation) == .voiceIsolation)
        #expect(MicrophoneModeKind(.wideSpectrum) == .wideSpectrum)
    }

    @Test func aModeFromTheFutureReadsAsStandard() {
        #expect(MicrophoneModeKind(AVCaptureDevice.MicrophoneMode(rawValue: 99)!) == .standard)
    }
}
