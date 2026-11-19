// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
// Not @testable: the app uses only the public API.
import AppSupport
import Analysis
import ProjectFormat

// The Frame tab (phase 2 design §6.5 and §6.7, plan 2b task I14): its five frames, what a click on each one puts in the
// document, the devices' finish, and when Follow the Cursor is offered and why not.

@Suite struct FrameTabRulesTests {
    @Test func everyFrameIsOneChoice() {
        #expect(FrameChoice.allCases == [.none, .macWindow, .iPhone, .iPad, .macBook])
        #expect(FrameChoice(.none) == .none)
        #expect(FrameChoice(.macWindow(appearance: .light, title: "Demo", buttons: false)) == .macWindow)
        #expect(FrameChoice(.device(DeviceFrame(model: .iPhone, finish: .light))) == .iPhone)
        #expect(FrameChoice(.device(DeviceFrame(model: .iPad, finish: .dark))) == .iPad)
        #expect(FrameChoice(.device(DeviceFrame(model: .macBook, finish: .dark))) == .macBook)
        #expect(FrameChoice.none.device == nil)
        #expect(FrameChoice.macWindow.device == nil)
        #expect(FrameChoice.allCases.compactMap(\.device) == [.iPhone, .iPad, .macBook])
    }

    @Test func choosingTheFrameThereKeepsIt() {
        let window = WindowFrame.macWindow(appearance: .light, title: "Demo", buttons: false)
        #expect(FrameChoice.macWindow.frame(from: window) == window)
        let phone = WindowFrame.device(DeviceFrame(model: .iPhone, finish: .light))
        #expect(FrameChoice.iPhone.frame(from: phone) == phone)
        #expect(FrameChoice.none.frame(from: .none) == .none)
    }

    @Test func aNewWindowIsDarkUntitledWithItsButtons() {
        // Design §5.4.
        let new = WindowFrame.macWindow(appearance: .dark, title: "", buttons: true)
        #expect(FrameChoice.macWindow.frame(from: .none) == new)
        #expect(FrameChoice.macWindow.frame(from: .device(DeviceFrame(model: .iPad, finish: .light))) == new)
        #expect(FrameChoice.none.frame(from: new) == .none)
        #expect(FrameChoice.none.frame(from: .device(DeviceFrame(model: .iPad, finish: .light))) == .none)
    }

    @Test func aDeviceKeepsTheFinishThere() {
        // From another device, its finish; from a window, its appearance; from none, dark (design §6.7).
        #expect(FrameChoice.iPad.frame(from: .device(DeviceFrame(model: .iPhone, finish: .light)))
            == .device(DeviceFrame(model: .iPad, finish: .light)))
        #expect(FrameChoice.macBook.frame(from: .device(DeviceFrame(model: .iPad, finish: .dark)))
            == .device(DeviceFrame(model: .macBook, finish: .dark)))
        #expect(FrameChoice.iPhone.frame(from: .macWindow(appearance: .light, title: "", buttons: true))
            == .device(DeviceFrame(model: .iPhone, finish: .light)))
        #expect(FrameChoice.iPhone.frame(from: .none) == .device(DeviceFrame(model: .iPhone, finish: .dark)))
    }

    @Test func theFinishIsADevicesOnly() {
        #expect(FrameTabRules.frame(.device(DeviceFrame(model: .macBook, finish: .dark)), finish: .light)
            == .device(DeviceFrame(model: .macBook, finish: .light)))
        #expect(FrameTabRules.frame(.none, finish: .light) == nil)
        #expect(FrameTabRules.frame(.macWindow(appearance: .dark, title: "", buttons: true), finish: .light) == nil)
    }

    @Test func followTheCursorIsOfferedForContentMuchWiderThanTheOutput() {
        // 16:9 in 9:16, 1:1, 4:5, 3:4 and 4:3 (1.33 times): offered. In 16:9 and like the recording: not wide enough.
        let wide = 16.0 / 9
        for aspect in [Aspect.portrait, .square, .fourByFive, .threeByFour, .fourByThree] {
            #expect(FrameTabRules.reframeOffer(contentRatio: wide, outputRatio: aspect.ratio(contentRatio: wide), isDeviceTake: false)
                == .offered)
        }
        for aspect in [Aspect.landscape, .auto] {
            #expect(FrameTabRules.reframeOffer(contentRatio: wide, outputRatio: aspect.ratio(contentRatio: wide), isDeviceTake: false)
                == .notWideEnough)
        }
        // 16:10 in 4:3 is 1.2 times.
        #expect(FrameTabRules.reframeOffer(contentRatio: 1.6, outputRatio: 4.0 / 3, isDeviceTake: false) == .notWideEnough)
        // At exactly 1.3 times, offered; just under, not (`ReframePath.isOffered`).
        #expect(FrameTabRules.reframeOffer(contentRatio: 1.3, outputRatio: 1, isDeviceTake: false) == .offered)
        #expect(FrameTabRules.reframeOffer(contentRatio: 1.29, outputRatio: 1, isDeviceTake: false) == .notWideEnough)
        #expect(ReframePath.offeredFactor == 1.3)
    }

    @Test func withoutTheContentsRatioYetItIsNotKnown() {
        #expect(FrameTabRules.reframeOffer(contentRatio: nil, outputRatio: 9.0 / 16, isDeviceTake: false) == .unknown)
    }

    @Test func aDeviceTakeHasNoCursorToFollow() {
        // An iPhone on its side in 9:16 is wide enough, but nothing would move the window.
        #expect(FrameTabRules.reframeOffer(contentRatio: 2532.0 / 1170, outputRatio: 9.0 / 16, isDeviceTake: true) == .noCursor)
        #expect(FrameTabRules.reframeOffer(contentRatio: 1170.0 / 2532, outputRatio: 16.0 / 9, isDeviceTake: true) == .noCursor)
        #expect(FrameTabRules.reframeOffer(contentRatio: nil, outputRatio: 16.0 / 9, isDeviceTake: true) == .noCursor)
    }

    @Test func aDocumentThatFollowsTheCursorCanAlwaysGoBackToFit() {
        // The format changed under it, or a style brought it: the render still follows the cursor where the screen is
        // wider than the room, so the control stays usable to choose Fit.
        for offer in [ReframeOffer.notWideEnough, .noCursor, .unknown] {
            #expect(!FrameTabRules.reframeIsEnabled(offer: offer, reframe: .fit))
            #expect(FrameTabRules.reframeIsEnabled(offer: offer, reframe: .followCursor))
        }
        #expect(FrameTabRules.reframeIsEnabled(offer: .offered, reframe: .fit))
        #expect(FrameTabRules.reframeIsEnabled(offer: .offered, reframe: .followCursor))
    }

    @Test func followingTheCursorDrawsNoFrame() {
        var style = StageStyle(
            background: .tomaClassic, backgroundBlur: 0, padding: 0.05, cornerRadius: 0.01, shadow: 0.5,
            frame: .device(DeviceFrame(model: .iPhone, finish: .dark)), screenSampling: .mipmapped, geometryTransition: .spring)
        #expect(FrameTabRules.frameIsDrawn(style))
        style.reframe = .followCursor
        #expect(!FrameTabRules.frameIsDrawn(style))
        style.frame = .macWindow(appearance: .dark, title: "", buttons: true)
        #expect(!FrameTabRules.frameIsDrawn(style))
    }
}
