// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics

/// The teleprompter (notch design §5.4): whether it shows, the one script (the last used, kept in the app's
/// settings), and how it reads it.
public struct TeleprompterSettings: Codable, Equatable, Sendable {
    public var isOn: Bool = false
    public var script: String = ""
    /// In points: from 14 to 40, in steps of 2.
    public var fontSize: Double = 22
    /// How fast the script goes up, as a multiple of `pointsPerSecondAtOneX`: from 0.3× to 3×.
    public var speed: Double = 1
    /// Of its background and its text: from 20 to 100 %.
    public var opacity: Double = 0.85
    /// "Follow the Voice" (phase 3 design §8.4): while a take records, the script goes where the voice is instead of up at
    /// `speed`.
    public var followsVoice: Bool = false

    public static let fontSizes = 14.0...40.0
    public static let fontStep = 2.0
    public static let speeds = 0.3...3.0
    public static let opacities = 0.2...1.0
    /// How far the script goes up in a second at 1×.
    public static let pointsPerSecondAtOneX = 24.0

    public init(
        isOn: Bool = false, script: String = "", fontSize: Double = 22, speed: Double = 1, opacity: Double = 0.85,
        followsVoice: Bool = false
    ) {
        self.isOn = isOn
        self.script = script
        self.fontSize = fontSize
        self.speed = speed
        self.opacity = opacity
        self.followsVoice = followsVoice
    }

    /// A field missing from what was saved (by a version that did not have it), or that this version
    /// cannot read, takes its default; the others are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TeleprompterSettings()
        isOn = (try? container.decodeIfPresent(Bool.self, forKey: .isOn)) ?? defaults.isOn
        script = (try? container.decodeIfPresent(String.self, forKey: .script)) ?? defaults.script
        fontSize = (try? container.decodeIfPresent(Double.self, forKey: .fontSize)) ?? defaults.fontSize
        speed = (try? container.decodeIfPresent(Double.self, forKey: .speed)) ?? defaults.speed
        opacity = (try? container.decodeIfPresent(Double.self, forKey: .opacity)) ?? defaults.opacity
        followsVoice = (try? container.decodeIfPresent(Bool.self, forKey: .followsVoice)) ?? defaults.followsVoice
    }

    /// Each value in its range, and the size on its step: `14 + ((size − 14) / 2).rounded() × 2`, a tie going
    /// away from zero.
    public func clamped() -> TeleprompterSettings {
        var clamped = self
        let size = Self.clamp(fontSize, to: Self.fontSizes)
        let smallest = Self.fontSizes.lowerBound
        clamped.fontSize = smallest + ((size - smallest) / Self.fontStep).rounded() * Self.fontStep
        clamped.speed = Self.clamp(speed, to: Self.speeds)
        clamped.opacity = Self.clamp(opacity, to: Self.opacities)
        return clamped
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// How far the script has gone up, in points from where it starts.
public struct TeleprompterScroll: Equatable, Sendable {
    public private(set) var offset: Double = 0

    public init() {}

    /// Goes up `speed × pointsPerSecondAtOneX × seconds` while `isRunning` (recording and not paused), never
    /// past `maximum`: the height of the text less what is visible of it.
    public mutating func advance(seconds: Double, speed: Double, isRunning: Bool, maximum: Double) {
        guard isRunning else { return }
        let step = max(0, speed * TeleprompterSettings.pointsPerSecondAtOneX * seconds)
        offset = min(offset + step, max(0, maximum))
    }

    /// Back to the top.
    public mutating func reset() {
        offset = 0
    }

    /// At `offset`, within the text: never before the top, nor past `maximum` (the height of the text less what is visible
    /// of it). Where Follow the Voice or a re-record's word puts it.
    public mutating func move(to offset: Double, maximum: Double) {
        self.offset = min(max(offset, 0), max(0, maximum))
    }

    /// The text was laid out again (another size, or the script edited): it is `newHeight` tall instead of
    /// `oldHeight`. The scroll keeps its place in it, as a share of the height, never past `maximum` (the new
    /// height less what is visible); measured for the first time (`oldHeight` 0), it only keeps within it.
    public mutating func contentHeightChanged(from oldHeight: Double, to newHeight: Double, maximum: Double) {
        if oldHeight > 0, newHeight > 0 { offset *= newHeight / oldHeight }
        offset = min(max(offset, 0), max(0, maximum))
    }

    /// The script has gone as far up as it can (or never had anywhere to go): nothing to step.
    public func isAtEnd(maximum: Double) -> Bool {
        offset >= max(0, maximum)
    }
}

/// Where the teleprompter is, and when it shows.
public enum TeleprompterLayout {
    public static let width = 640.0
    /// Between the island's bottom edge and the teleprompter's top.
    public static let gap = 10.0
    public static let height = 160.0

    /// Centered under `island`, `gap` below its bottom edge. AppKit coordinates.
    public static func frame(below island: CGRect) -> CGRect {
        CGRect(x: Double(island.midX) - width / 2, y: Double(island.minY) - gap - height, width: width, height: height)
    }

    /// When it is on, with the island open, counting down, recording (with its wings, open, or with a
    /// notice): never at rest, peeking, choosing on the screen, nor while a take is saved.
    public static func isVisible(isOn: Bool, island: IslandState) -> Bool {
        guard isOn else { return false }
        switch island {
        case .open, .countdown, .recording, .recordingOpen, .notice: return true
        case .rest, .peek, .choosing, .saving, .saved: return false
        }
    }

    /// What the confirmation capsule hangs from, `gap` under it: the teleprompter while it is on the screen
    /// (fading out included), so neither covers the other; the island otherwise. AppKit coordinates.
    public static func capsuleAnchor(island: CGRect, teleprompterOnScreen: Bool) -> CGRect {
        teleprompterOnScreen ? frame(below: island) : island
    }
}

/// How the teleprompter reads the script, and when its text field gives way to it.
public enum TeleprompterRules {
    /// The script goes up while the take records and nobody paused it (neither the user nor the system),
    /// and not while it is being edited: the text read is not on the screen then.
    public static func scrolls(phase: RecordingController.Phase, isUserPaused: Bool, isPaused: Bool, isEditing: Bool) -> Bool {
        guard case .recording = phase else { return false }
        return !isUserPaused && !isPaused && !isEditing
    }

    /// The teleprompter comes back on the screen (`returning`: it was off it, or leaving it) with no take
    /// recording: a new take's panel or countdown, or a restart's countdown. It reads from the top, never
    /// from where the last take left it. During a take (turned off and on again) it stays where it was.
    public static func startsFromTheTop(returning: Bool, isRecording: Bool) -> Bool {
        returning && !isRecording
    }

    /// Where the script starts when it comes back on the screen without a take recording (`startsFromTheTop`): with the
    /// line of `word` at the reading line (`TeleprompterFollow.offset`), the word a re-record begins at (plan 3d, decision
    /// 12); from the top (0) without one, or for a word `lines` does not have. `nil` when it does not start again: it stays
    /// where it is. `maximum` is how far it can go up.
    public static func startOffset(
        returning: Bool, isRecording: Bool, word: Int?, lines: TeleprompterLines, readingHeight: Double, leadIn: Double,
        maximum: Double
    ) -> Double? {
        guard startsFromTheTop(returning: returning, isRecording: isRecording) else { return nil }
        guard let word, let index = lines.line(ofWord: word) else { return 0 }
        return TeleprompterFollow.offset(showing: lines.lines[index], readingHeight: readingHeight, leadIn: leadIn, maximum: maximum)
    }

    /// The island starts counting down: the take is about to read the script, so editing it ends (never from
    /// one second of the countdown to the next).
    public static func endsEditing(from before: IslandState, to after: IslandState) -> Bool {
        guard case .countdown = after else { return false }
        if case .countdown = before { return false }
        return true
    }

    /// The teleprompter lost the keyboard (a click in another app) while its script was edited: editing ends,
    /// or the script would stay still until Done, except with the open island (or while choosing), which a
    /// click in another app closes, the teleprompter with it.
    public static func endsEditingOnLosingKeyboard(island: IslandState) -> Bool {
        switch island {
        case .open, .choosing: false
        case .rest, .peek, .countdown, .recording, .recordingOpen, .notice, .saving, .saved: true
        }
    }
}

/// Follow the Voice (phase 3 design §8.4; plan 3d, decisions 13 and 14): the line being read goes to the reading line, a
/// third of the way down the reading area, and what was said is dimmed.
public enum TeleprompterFollow {
    /// Where the reading line is, as a share of the reading area's height from its top.
    public static let readingLineShare = 1.0 / 3
    /// What was said, as a share of the text's opacity.
    public static let spokenOpacity = 0.4

    /// How far the script goes up for `line` to be at the reading line: its top a third of the way down the reading area
    /// (`readingHeight` tall), the script's first line being `leadIn` from the top of the area; never before the top, nor
    /// past `maximum`.
    public static func offset(showing line: TeleprompterLines.Line, readingHeight: Double, leadIn: Double, maximum: Double) -> Double {
        min(max(line.top + leadIn - readingHeight * readingLineShare, 0), max(0, maximum))
    }

    /// The first word of the line at the reading line when the script has gone `offset` up: where the voice is taken to be
    /// when Follow the Voice is turned on during a take. 0 without lines.
    public static func word(atOffset offset: Double, lines: TeleprompterLines, readingHeight: Double, leadIn: Double) -> Int {
        // The reading line is never above where the line it shows starts, so a hair of rounding keeps that line.
        let y = offset + readingHeight * readingLineShare - leadIn + 1e-6
        return lines.line(at: y).map { lines.lines[$0].words.lowerBound } ?? 0
    }

    /// Where the speaker is in the script, as the teleprompter shows it: what the live engine heard, aligned with
    /// `teleprompterAlign-1` from the word the take began at. Final results are confirmed (`alignment`); a volatile one is
    /// aligned on trial over what is confirmed, and the next result replaces it. What is shown (`word`) never goes back,
    /// though a final result may give less than the volatile one before it.
    public struct Place: Equatable, Sendable {
        /// What the final results confirmed.
        public private(set) var alignment: TeleprompterAlignment
        /// The next word to say, as shown: the furthest any result reached.
        public private(set) var word: Int

        /// At `word` of `script`: the words before it are said.
        public init(script: ScriptWords, from word: Int) {
            alignment = TeleprompterAlignment(script: script, at: word)
            self.word = alignment.position
        }

        /// What the engine heard of a stretch of speech so far (`text`), volatile or final.
        public mutating func hear(_ text: String, isFinal: Bool) {
            let heard = ScriptWords(text).words.map(\.text)
            guard !heard.isEmpty else { return }
            if isFinal {
                alignment.hear(heard)
                word = max(word, alignment.position)
            } else {
                word = max(word, alignment.trying(heard).position)
            }
        }

        /// The final result of what was said just before the take was paused, which comes while it is: confirmed, so what
        /// is heard next aligns after it, but not shown, since nothing moves while the take is paused (`showConfirmed`).
        public mutating func confirm(_ text: String) {
            let heard = ScriptWords(text).words.map(\.text)
            guard !heard.isEmpty else { return }
            alignment.hear(heard)
        }

        /// The take goes on: what was confirmed while it was paused shows (never going back).
        public mutating func showConfirmed() {
            word = max(word, alignment.position)
        }
    }

    /// Why Follow the Voice, on, does not follow: the teleprompter says it, and goes up at its speed instead.
    public enum Note: Equatable, Sendable {
        /// Live transcription needs macOS 26.
        case needsMacOS26
        /// The model of this language (BCP 47) is not on the Mac: it is downloaded in Captions.
        case missingLanguage(String)
        /// The take records no microphone.
        case noMicrophone
        /// The engine failed (a permission, or anything else), or the Mac cannot transcribe.
        case failed
    }
}
