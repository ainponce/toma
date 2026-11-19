// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@testable import AppSupport

/// What the Camera tab's Background, Framing and Color say and do (phase 2 design §6.1 to §6.3).
@Suite struct CameraPictureRulesTests {
    @Test func analysisStatusSaysHowFarItIs() {
        // Not needed (an Original background, a framing that is not Follow the Face): nothing to say.
        #expect(CameraPictureRules.status(progress: nil, failed: false) == .none)
        #expect(CameraPictureRules.status(progress: 0, failed: false) == .preparing(percent: 0))
        #expect(CameraPictureRules.status(progress: 0.304, failed: false) == .preparing(percent: 30))
        // Never "100 %" while a part is still running.
        #expect(CameraPictureRules.status(progress: 0.999, failed: false) == .preparing(percent: 99))
        #expect(CameraPictureRules.status(progress: 1, failed: false) == .none)
        // A job that failed counts whole in the progress: its reason comes first.
        #expect(CameraPictureRules.status(progress: 1, failed: true) == .failed)
        #expect(CameraPictureRules.status(progress: 0.5, failed: true) == .failed)
        #expect(CameraPictureRules.status(progress: .nan, failed: false) == .preparing(percent: 0))
    }

    @Test func customWithoutItsCubeIsNatural() {
        let custom = CameraColor(preset: .custom, lut: "assets/0123456789abcdef0123456789abcdef.cube", intensity: 1)
        let lost = CameraColor(preset: .custom, lut: nil, intensity: 1)
        #expect(CameraPictureRules.selectedLook(custom) == .custom)
        #expect(CameraPictureRules.selectedLook(lost) == .natural)
        #expect(CameraPictureRules.selectedLook(CameraColor(preset: .warm, lut: nil, intensity: 0.5)) == .warm)
    }

    @Test func intensityOnlyForALook() {
        #expect(!CameraPictureRules.intensityApplies(.natural))
        #expect(!CameraPictureRules.intensityApplies(CameraColor(preset: .custom, lut: nil, intensity: 1)))
        #expect(CameraPictureRules.intensityApplies(CameraColor(preset: .mono, lut: nil, intensity: 0)))
        #expect(CameraPictureRules.intensityApplies(CameraColor(preset: .custom, lut: "assets/a.cube", intensity: 1)))
    }

    @Test func customAsksForAFileOnlyWithoutOne() {
        let none = CameraColor.natural
        let kept = CameraColor(preset: .vivid, lut: "assets/0123456789abcdef0123456789abcdef.cube", intensity: 1)
        #expect(CameraPictureRules.action(choosing: .custom, in: none) == .chooseFile)
        // The `.cube` brought in before is still in the document: choosing Custom again uses it.
        #expect(CameraPictureRules.action(choosing: .custom, in: kept) == .setPreset(.custom))
        #expect(CameraPictureRules.action(choosing: .soft, in: none) == .setPreset(.soft))
    }

    @Test func thePresetsInTheirOrder() {
        #expect(CameraPictureRules.presets == [.natural, .warm, .cool, .vivid, .soft, .mono])
    }

    @Test func zoomIsShownAsTheRenderReadsIt() {
        #expect(CameraPictureRules.zoomStep == 0.1)
        #expect(CameraPictureRules.snappedZoom(1.44) == 1.4)
        #expect(CameraPictureRules.snappedZoom(1.46) == 1.5)
        #expect(CameraPictureRules.snappedZoom(0.2) == 1)
        #expect(CameraPictureRules.snappedZoom(3) == 2.5)
        #expect(CameraPictureRules.snappedZoom(.nan) == 1)
    }

    @Test func percentsForVoiceOver() {
        #expect(CameraPictureRules.percent(0.504) == 50)
        #expect(CameraPictureRules.percent(1.2) == 100)
        #expect(CameraPictureRules.percent(-1) == 0)
        #expect(CameraPictureRules.percent(.nan) == 50)
    }
}
