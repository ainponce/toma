// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Testing

@Test(arguments: [(0, false, NSApplication.ActivationPolicy.accessory), (1, false, .regular), (1, true, .accessory), (0, true, .accessory)])
func activationPolicy(windows: Int, recording: Bool, expected: NSApplication.ActivationPolicy) {
    #expect(ActivationPolicyDecision.policy(openWindows: windows, isRecording: recording) == expected)
}

@Test func severalWindowsMakeARegularAppUntilRecording() {
    #expect(ActivationPolicyDecision.policy(openWindows: 3, isRecording: false) == .regular)
    #expect(ActivationPolicyDecision.policy(openWindows: 3, isRecording: true) == .accessory)
}
