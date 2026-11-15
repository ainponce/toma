// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
import Foundation
import Testing

@Suite struct TeleprompterTests {
    @Test func scrollAdvancesAt24PointsPerSecondAtOneX() {
        var scroll = TeleprompterScroll()
        #expect(scroll.offset == 0)
        scroll.advance(seconds: 1, speed: 1, isRunning: true, maximum: 1000)
        #expect(scroll.offset == 24)
        scroll.advance(seconds: 2, speed: 2.5, isRunning: true, maximum: 1000)
        #expect(scroll.offset == 144)
        #expect(TeleprompterSettings.pointsPerSecondAtOneX == 24)
    }

    @Test func scrollStopsWhilePausedAndAtTheEnd() {
        var scroll = TeleprompterScroll()
        scroll.advance(seconds: 1, speed: 1, isRunning: true, maximum: 1000)
        scroll.advance(seconds: 3, speed: 2, isRunning: false, maximum: 1000)
        #expect(scroll.offset == 24)

        var end = TeleprompterScroll()
        for _ in 0..<10 {
            end.advance(seconds: 1, speed: 3, isRunning: true, maximum: 100)
            #expect(end.offset <= 100)
        }
        #expect(end.offset == 100)
        // A text shorter than what is visible never scrolls.
        var short = TeleprompterScroll()
        short.advance(seconds: 1, speed: 1, isRunning: true, maximum: -40)
        #expect(short.offset == 0)
    }

    @Test func resetGoesBackToTheTop() {
        var scroll = TeleprompterScroll()
        scroll.advance(seconds: 1, speed: 1, isRunning: true, maximum: 1000)
        scroll.advance(seconds: 2, speed: 2.5, isRunning: true, maximum: 1000)
        #expect(scroll.offset == 144)
        scroll.reset()
        #expect(scroll.offset == 0)
        #expect(scroll == TeleprompterScroll())
    }

    @Test func settingsClampToTheirRanges() {
        func size(_ value: Double) -> Double { TeleprompterSettings(fontSize: value).clamped().fontSize }
        #expect(size(13) == 14)
        #expect(size(41) == 40)
        #expect(size(23) == 24)  // a tie goes away from zero
        #expect(size(22) == 22)
        #expect(size(14.9) == 14 && size(15.1) == 16)

        func speed(_ value: Double) -> Double { TeleprompterSettings(speed: value).clamped().speed }
        #expect(speed(0.1) == 0.3)
        #expect(speed(5) == 3)
        #expect(speed(1.7) == 1.7)

        func opacity(_ value: Double) -> Double { TeleprompterSettings(opacity: value).clamped().opacity }
        #expect(opacity(0.05) == 0.2)
        #expect(opacity(1.5) == 1)
        #expect(opacity(0.5) == 0.5)

        // The switch and the script are kept as they are.
        let settings = TeleprompterSettings(isOn: true, script: "Hello", fontSize: 50, speed: 0, opacity: 0)
        #expect(settings.clamped() == TeleprompterSettings(isOn: true, script: "Hello", fontSize: 40, speed: 0.3, opacity: 0.2))
        #expect(TeleprompterSettings().clamped() == TeleprompterSettings())
        #expect(TeleprompterSettings() == TeleprompterSettings(isOn: false, script: "", fontSize: 22, speed: 1, opacity: 0.85))
        #expect(TeleprompterSettings.fontSizes == 14.0...40.0 && TeleprompterSettings.fontStep == 2)
        #expect(TeleprompterSettings.speeds == 0.3...3.0 && TeleprompterSettings.opacities == 0.2...1.0)
    }

    @Test func teleprompterHangsTenPointsBelowTheIsland() {
        #expect(TeleprompterLayout.frame(below: CGRect(x: 406, y: 582, width: 700, height: 400)) == CGRect(x: 436, y: 412, width: 640, height: 160))
        // The wings of a 188 pt notch on the same screen: still centered, 10 pt under their bottom edge.
        #expect(TeleprompterLayout.frame(below: CGRect(x: 578, y: 950, width: 356, height: 32)) == CGRect(x: 436, y: 780, width: 640, height: 160))
        #expect(TeleprompterLayout.width == 640 && TeleprompterLayout.height == 160 && TeleprompterLayout.gap == 10)
    }

    @Test func teleprompterShowsOnlyWhereTheDesignDoes() {
        let saved = SavedTake(
            projectURL: URL(fileURLWithPath: "/tmp/Recording.toma"), duration: .seconds(5), markers: 0, trackKinds: [.display],
            openedEditor: false)
        let shown: [IslandState] = [.open, .countdown(remaining: 3), .recording, .recordingOpen, .notice(.microphoneSilent)]
        let hidden: [IslandState] = [.rest, .peek, .choosing, .saving, .saved(saved)]
        for state in shown + hidden {
            #expect(!TeleprompterLayout.isVisible(isOn: false, island: state))
        }
        for state in shown {
            #expect(TeleprompterLayout.isVisible(isOn: true, island: state))
        }
        for state in hidden {
            #expect(!TeleprompterLayout.isVisible(isOn: true, island: state))
        }
    }
}
