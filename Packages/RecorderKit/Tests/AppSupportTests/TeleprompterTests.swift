// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
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

    /// Where the teleprompter shows, and where it does not.
    private static let shown: [IslandState] = [.open, .countdown(remaining: 3), .recording, .recordingOpen, .notice(.microphoneSilent)]
    private static let hidden: [IslandState] = [
        .rest, .peek, .choosing, .saving,
        .saved(SavedTake(
            projectURL: URL(fileURLWithPath: "/tmp/Recording.toma"), duration: .seconds(5), markers: 0, trackKinds: [.display],
            openedEditor: false)),
    ]

    @Test func teleprompterShowsOnlyWhereTheDesignDoes() {
        let (shown, hidden) = (Self.shown, Self.hidden)
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

    @Test func scrollKeepsItsPlaceWhenTheTextReflows() {
        var scroll = TeleprompterScroll()
        for _ in 0..<5 { scroll.advance(seconds: 1, speed: 1, isRunning: true, maximum: 1000) }
        #expect(scroll.offset == 120)
        // A larger size: the text is twice as tall, and so is the way it went.
        scroll.contentHeightChanged(from: 400, to: 800, maximum: 678)
        #expect(scroll.offset == 240)
        // A smaller one: back to the same place.
        scroll.contentHeightChanged(from: 800, to: 400, maximum: 278)
        #expect(scroll.offset == 120)
        // A script made shorter than where it was: at its new end, not past it.
        scroll.contentHeightChanged(from: 400, to: 200, maximum: 50)
        #expect(scroll.offset == 50)
        // Shorter than what is visible: at the top.
        scroll.contentHeightChanged(from: 200, to: 100, maximum: -22)
        #expect(scroll.offset == 0)
        // Measured for the first time: nothing to scale from.
        var first = TeleprompterScroll()
        first.contentHeightChanged(from: 0, to: 500, maximum: 378)
        #expect(first.offset == 0)
    }

    @Test func scrollKnowsWhenItReachedTheEnd() {
        var scroll = TeleprompterScroll()
        #expect(!scroll.isAtEnd(maximum: 100))
        #expect(scroll.isAtEnd(maximum: 0) && scroll.isAtEnd(maximum: -40))  // nothing to scroll
        for _ in 0..<4 { scroll.advance(seconds: 1, speed: 1, isRunning: true, maximum: 100) }
        #expect(scroll.offset == 96 && !scroll.isAtEnd(maximum: 100))
        scroll.advance(seconds: 1, speed: 1, isRunning: true, maximum: 100)
        #expect(scroll.isAtEnd(maximum: 100))
        // The text grew: there is more to read.
        #expect(!scroll.isAtEnd(maximum: 300))
    }

    @Test func scriptGoesUpOnlyWhileTheTakeRecordsUnpaused() {
        let recording = RecordingController.Phase.recording(since: Date())
        #expect(TeleprompterRules.scrolls(phase: recording, isUserPaused: false, isPaused: false, isEditing: false))
        #expect(!TeleprompterRules.scrolls(phase: recording, isUserPaused: true, isPaused: false, isEditing: false))
        #expect(!TeleprompterRules.scrolls(phase: recording, isUserPaused: false, isPaused: true, isEditing: false))
        #expect(!TeleprompterRules.scrolls(phase: recording, isUserPaused: false, isPaused: false, isEditing: true))
        for phase: RecordingController.Phase in [.idle, .countingDown(remaining: 3), .starting, .stopping] {
            #expect(!TeleprompterRules.scrolls(phase: phase, isUserPaused: false, isPaused: false, isEditing: false))
        }
    }

    @Test func teleprompterStartsFromTheTopWhenItComesBackWithoutATake() {
        // Back on the screen for a new take's panel or countdown, or a restart's countdown.
        #expect(TeleprompterRules.startsFromTheTop(returning: true, isRecording: false))
        // Turned off and on again during the take: where it was.
        #expect(!TeleprompterRules.startsFromTheTop(returning: true, isRecording: true))
        // Already on the screen.
        #expect(!TeleprompterRules.startsFromTheTop(returning: false, isRecording: false))
        #expect(!TeleprompterRules.startsFromTheTop(returning: false, isRecording: true))
    }

    @Test func countdownEndsEditing() {
        for state in Self.shown + Self.hidden where state != .countdown(remaining: 3) {
            #expect(TeleprompterRules.endsEditing(from: state, to: .countdown(remaining: 3)))
            #expect(!TeleprompterRules.endsEditing(from: .countdown(remaining: 3), to: state))
        }
        // One second of the countdown to the next.
        #expect(!TeleprompterRules.endsEditing(from: .countdown(remaining: 3), to: .countdown(remaining: 2)))
        #expect(!TeleprompterRules.endsEditing(from: .recordingOpen, to: .recording))
        #expect(!TeleprompterRules.endsEditing(from: .recording, to: .notice(.microphoneSilent)))
    }

    @Test func editingEndsWhenTheKeyboardLeaves() {
        // Recording (or counting down), the script would stay frozen until Done.
        for state: IslandState in [.countdown(remaining: 3), .recording, .recordingOpen, .notice(.microphoneSilent)] {
            #expect(TeleprompterRules.endsEditingOnLosingKeyboard(island: state))
        }
        // The open island keeps it: a click in another app closes the island, and the teleprompter with it.
        #expect(!TeleprompterRules.endsEditingOnLosingKeyboard(island: .open))
        #expect(!TeleprompterRules.endsEditingOnLosingKeyboard(island: .choosing))
    }

    @Test func capsuleHangsUnderTheTeleprompterWhileItIsOnScreen() {
        let island = CGRect(x: 578, y: 950, width: 356, height: 32)
        #expect(TeleprompterLayout.capsuleAnchor(island: island, teleprompterOnScreen: true) == CGRect(x: 436, y: 780, width: 640, height: 160))
        #expect(TeleprompterLayout.capsuleAnchor(island: island, teleprompterOnScreen: false) == island)
    }

    @Test func followsVoiceDefaultsOffAndDecodesOldSettings() throws {
        #expect(!TeleprompterSettings().followsVoice)
        // What phase 2 saved: no `followsVoice`.
        let old = Data(#"{"isOn":true,"script":"Hola","fontSize":30,"speed":1.5,"opacity":0.6}"#.utf8)
        let decoded = try JSONDecoder().decode(TeleprompterSettings.self, from: old)
        #expect(decoded == TeleprompterSettings(isOn: true, script: "Hola", fontSize: 30, speed: 1.5, opacity: 0.6))
        #expect(!decoded.followsVoice)
        // Saved and read again, on.
        let on = TeleprompterSettings(isOn: true, script: "Hola", fontSize: 30, speed: 1.5, opacity: 0.6, followsVoice: true)
        #expect(try JSONDecoder().decode(TeleprompterSettings.self, from: JSONEncoder().encode(on)) == on)
        // A value it cannot read takes its default; the rest is kept.
        let wrong = Data(#"{"isOn":true,"script":"Hola","followsVoice":"yes"}"#.utf8)
        #expect(try JSONDecoder().decode(TeleprompterSettings.self, from: wrong) == TeleprompterSettings(isOn: true, script: "Hola"))
        // Clamping keeps it.
        #expect(on.clamped().followsVoice)
    }

    @Test func rerecordStartsAtItsWord() throws {
        let script = TeleprompterLinesTests.script(words: 120)
        let lines = TeleprompterLines(script: script, words: ScriptWords(script), fontSize: 22, width: TeleprompterLinesTests.width)
        func start(returning: Bool = true, isRecording: Bool = false, word: Int?) -> Double? {
            TeleprompterRules.startOffset(
                returning: returning, isRecording: isRecording, word: word, lines: lines, readingHeight: 122, leadIn: 40, maximum: 1000)
        }
        // The line of its word, at the reading line.
        let line = try #require(lines.line(ofWord: 37))
        #expect(line > 0)
        #expect(start(word: 37) == TeleprompterFollow.offset(showing: lines.lines[line], readingHeight: 122, leadIn: 40, maximum: 1000))
        #expect(start(word: 37)! > 0)
        // Without a word (a new take), or one the script does not have: from the top, as today.
        #expect(start(word: nil) == 0)
        #expect(start(word: 500) == 0)
        // Only when it comes back without a take recording, as `startsFromTheTop` says.
        #expect(start(returning: false, word: 37) == nil)
        #expect(start(isRecording: true, word: 37) == nil)
        #expect(start(returning: false, isRecording: true, word: nil) == nil)
    }

    @Test func scrollMovesWhereItIsSent() {
        var scroll = TeleprompterScroll()
        scroll.move(to: 120, maximum: 1000)
        #expect(scroll.offset == 120)
        scroll.move(to: 2000, maximum: 1000)
        #expect(scroll.offset == 1000)
        scroll.move(to: -5, maximum: 1000)
        #expect(scroll.offset == 0)
        scroll.move(to: 50, maximum: -40)
        #expect(scroll.offset == 0)
    }
}
