// SPDX-License-Identifier: GPL-3.0-or-later
import Recording
import Testing

@testable import AppSupport

@Suite struct ExternalDeviceChoiceTests {
    private let phone = ExternalDeviceInfo(uniqueID: "phone", name: "iPhone de Ana", modelID: "iOS Device")
    private let pad = ExternalDeviceInfo(uniqueID: "pad", name: "iPad de Ana", modelID: "iOS Device")

    @Test func theChosenDeviceStaysWhileItIsConnected() {
        #expect(ExternalDeviceChoice.reconciled("pad", connected: [phone, pad]) == "pad")
        #expect(ExternalDeviceChoice.reconciled("phone", connected: [phone]) == "phone")
    }

    @Test func theOnlyDeviceConnectedIsChosen() {
        #expect(ExternalDeviceChoice.reconciled(nil, connected: [phone]) == "phone")
        // The chosen one was unplugged, and another is the only one there.
        #expect(ExternalDeviceChoice.reconciled("pad", connected: [phone]) == "phone")
    }

    @Test func withSeveralConnectedNoneIsChosenForTheUser() {
        #expect(ExternalDeviceChoice.reconciled(nil, connected: [phone, pad]) == nil)
    }

    @Test func aChosenDeviceThatIsNotConnectedIsKept() {
        // Nothing connected yet (the devices show up a moment after the mode opens), or it may come back.
        #expect(ExternalDeviceChoice.reconciled("pad", connected: []) == "pad")
        #expect(ExternalDeviceChoice.reconciled("gone", connected: [phone, pad]) == "gone")
        #expect(ExternalDeviceChoice.reconciled(nil, connected: []) == nil)
    }

    @Test func recordNeedsTheChosenDeviceConnected() {
        #expect(ExternalDeviceChoice.problem(chosen: "phone", connected: [phone, pad]) == nil)
        #expect(ExternalDeviceChoice.problem(chosen: "gone", connected: [phone]) == .noDeviceChosen)
        #expect(ExternalDeviceChoice.problem(chosen: nil, connected: [phone]) == .noDeviceChosen)
        #expect(ExternalDeviceChoice.problem(chosen: "phone", connected: []) == .noDeviceChosen)
    }

    @Test func theKindIsTheModelsThenTheNames() {
        #expect(ExternalDeviceKind(ExternalDeviceInfo(uniqueID: "a", name: "Ana", modelID: "iPad13,4")) == .iPad)
        #expect(ExternalDeviceKind(ExternalDeviceInfo(uniqueID: "a", name: "Ana", modelID: "iPhone17,1")) == .iPhone)
        // A screen device's model is often only "iOS Device": its name says it.
        #expect(ExternalDeviceKind(pad) == .iPad)
        #expect(ExternalDeviceKind(phone) == .iPhone)
        #expect(ExternalDeviceKind(ExternalDeviceInfo(uniqueID: "a", name: "Ana's IPAD", modelID: "iOS Device")) == .iPad)
        #expect(ExternalDeviceKind(ExternalDeviceInfo(uniqueID: "a", name: "Ana", modelID: "iOS Device")) == .unknown)
    }

    @Test func eachKindHasItsSymbol() {
        #expect(ExternalDeviceKind.iPhone.symbol == "iphone")
        #expect(ExternalDeviceKind.iPad.symbol == "ipad")
        #expect(ExternalDeviceKind.unknown.symbol == "ipad.and.iphone")
    }
}
