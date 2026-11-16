// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import Testing

@Suite struct PanelValuesTests {
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-12 }

    @Test func slidersMapToRenderMeasures() {
        #expect(close(PanelValues.padding(slider: 40), 0.08))
        #expect(PanelValues.slider(padding: 0.08) == 40)
        #expect(close(PanelValues.padding(slider: 100), 0.20) && close(PanelValues.padding(slider: 0), 0))
        #expect(close(PanelValues.cornerRadius(slider: 30), 0.012))
        #expect(PanelValues.slider(cornerRadius: 0.012) == 30)
        #expect(close(PanelValues.shadow(slider: 60), 0.6) && PanelValues.slider(shadow: 0.6) == 60)
        #expect(close(PanelValues.backgroundBlur(slider: 50), 0.5) && PanelValues.slider(backgroundBlur: 0.5) == 50)
        #expect(close(PanelValues.motionBlur(slider: 50), 0.5) && PanelValues.slider(motionBlur: 0.5) == 50)
        #expect(close(PanelValues.cursorScale(percent: 150), 1.5) && PanelValues.percent(cursorScale: 1.5) == 150)
        #expect(PanelValues.cursorScaleRange == 50...300)
    }

    @Test func theWayBackRoundsToTheNearestIntegerAndStaysInRange() {
        #expect(PanelValues.slider(padding: 0.0805) == 40)
        #expect(PanelValues.slider(padding: 0.0815) == 41)
        // A window cover past the corners' top (0.0465 for a 300 pt window) shows the top.
        #expect(PanelValues.slider(cornerRadius: 0.0465) == 100)
        #expect(PanelValues.slider(shadow: -1) == 0 && PanelValues.slider(shadow: .nan) == 0)
        #expect(PanelValues.percent(cursorScale: 10) == 300 && PanelValues.percent(cursorScale: 0.1) == 50)
    }

    @Test func everySliderStepComesBack() {
        for v in 0...100 {
            #expect(PanelValues.slider(padding: PanelValues.padding(slider: v)) == v)
            #expect(PanelValues.slider(cornerRadius: PanelValues.cornerRadius(slider: v)) == v)
            #expect(PanelValues.slider(shadow: PanelValues.shadow(slider: v)) == v)
        }
    }

    @Test func gradientEndsFollowTheCSSAngle() {
        let up = PanelValues.gradientEnds(angle: 0)
        #expect(close(up.start.x, 0.5) && close(up.start.y, 1) && close(up.end.x, 0.5) && close(up.end.y, 0))
        let right = PanelValues.gradientEnds(angle: 90)
        #expect(close(right.start.x, 0) && close(right.end.x, 1) && close(right.start.y, 0.5))
        let down = PanelValues.gradientEnds(angle: 180)
        #expect(close(down.start.y, 0) && close(down.end.y, 1))
        let classic = PanelValues.gradientEnds(angle: 135)
        #expect(classic.start.x < 0.5 && classic.start.y < 0.5 && classic.end.x > 0.5 && classic.end.y > 0.5)
    }

    @Test func cameraCursorAndAudioValuesMapAndStayInRange() {
        // Small, Medium and Large are on the bar.
        #expect(close(PanelValues.cameraSize(percent: 17), CameraStyle.small))
        #expect(close(PanelValues.cameraSize(percent: 24), CameraStyle.medium))
        #expect(close(PanelValues.cameraSize(percent: 33), CameraStyle.large))
        #expect(PanelValues.percent(cameraSize: CameraStyle.large) == 33)
        #expect(close(PanelValues.cameraSize(percent: 99), 0.45) && PanelValues.percent(cameraSize: 0.05) == 10)
        #expect(close(PanelValues.clickSoundGain(percent: 50), 0.5) && PanelValues.percent(clickSoundGain: 0.5) == 50)
        #expect(close(PanelValues.trackGain(percent: 200), 2) && PanelValues.percent(trackGain: 1) == 100)
        #expect(close(PanelValues.trackGain(percent: 250), 2) && PanelValues.percent(trackGain: .nan) == 0)
        #expect(PanelValues.idleDelayRange == 1...5 && PanelValues.idleDelayStep == 0.5)
    }

    @Test func cursorSmoothingPresetsAreTheDesignSprings() {
        #expect(CursorSmoothingPreset.allCases == [.off, .fast, .medium, .smooth])
        #expect(CursorSmoothingPreset.off.smoothing == .off)
        #expect(CursorSmoothingPreset.fast.smoothing == .spring(SpringSpec(damping: 1.0, response: 0.10)))
        #expect(CursorSmoothingPreset.medium.smoothing == .spring(SpringSpec(damping: 1.0, response: 0.16)))
        #expect(CursorSmoothingPreset.smooth.smoothing == .spring(SpringSpec(damping: 0.92, response: 0.26)))
        // The project's default is Medium; a spring that is none of them is none.
        #expect(CursorSmoothingPreset(DefaultStyle.toma.cursor.smoothing) == .medium)
        #expect(CursorSmoothingPreset(.spring(SpringSpec(damping: 0.5, response: 0.5))) == nil)
    }

    @Test func borderShadowAndShareSliders() {
        #expect(close(PanelValues.cameraBorder(slider: 50), 0.5))
        #expect(close(PanelValues.cameraShadow(slider: 40), 0.4))
        #expect(PanelValues.slider(cameraBorder: 0.5) == 50)
        #expect(PanelValues.slider(cameraShadow: 0.4) == 40)
        #expect(PanelValues.slider(cameraShadow: 7) == 100)
        #expect(close(PanelValues.splitShare(percent: 34), 0.34))
        #expect(close(PanelValues.splitShare(percent: 10), 0.25))
        #expect(PanelValues.percent(splitShare: 0.6) == 60)
        #expect(PanelValues.percent(splitShare: 0.9) == 60)
        #expect(PanelValues.percent(splitShare: 0.1) == 25)
    }
}
