// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Dispatch
import ProjectFormat
import Recording
import Synchronization

/// Types `text` as keys, one every `every` from one interval after the start, with the codes of a US keyboard: each
/// character's key, with ⇧ for a capital or a shifted symbol, `chars` the character itself and `key` what the key types
/// without ⇧ (both `nil` for a line break or a tab, which are ↩ and ⇥). A character the US layout has no key for is
/// left out. Each key's time is `HostTime.now()` when it is typed. A stop keeps its place: the next start goes on from the next character. Once
/// typed, it types nothing more. Needs no permission.
public final class ScriptedKeyEvents: KeyEventSource {
    private struct State {
        var timer: (any RecordingTimer)?
        var handler: (@Sendable (KeyEvent, HostTime) -> Void)?
        var next = 0
    }

    private let keys: [KeyEvent]
    private let every: Duration
    private let ticks: RecordingTicks
    private let state = Mutex(State())

    public init(text: String, every: Duration, ticks: RecordingTicks) {
        keys = text.compactMap(Self.usKey(for:))
        self.every = every
        self.ticks = ticks
    }

    public func start(on queue: DispatchSerialQueue, handler: @escaping @Sendable (KeyEvent, HostTime) -> Void) -> Bool {
        let timer = ticks.every(every, queue) { [weak self] in self?.typeNext() }
        let previous = state.withLock { s -> (any RecordingTimer)? in
            defer { (s.timer, s.handler) = (timer, handler) }
            return s.timer
        }
        previous?.cancel()
        return true
    }

    public func stop() {
        let timer = state.withLock { s -> (any RecordingTimer)? in
            defer { (s.timer, s.handler) = (nil, nil) }
            return s.timer
        }
        timer?.cancel()
    }

    /// On the queue.
    private func typeNext() {
        let (key, handler, done) = state.withLock { s -> (KeyEvent?, (@Sendable (KeyEvent, HostTime) -> Void)?, (any RecordingTimer)?) in
            guard let handler = s.handler, s.next < keys.count else { return (nil, nil, nil) }
            let key = keys[s.next]
            s.next += 1
            guard s.next == keys.count else { return (key, handler, nil) }
            defer { s.timer = nil }
            return (key, handler, s.timer)
        }
        done?.cancel()
        if let key, let handler { handler(key, HostTime.now()) }
    }

    /// The key that types `character` on a US keyboard, or `nil` if it has none.
    static func usKey(for character: Character) -> KeyEvent? {
        let shift = UInt32(truncatingIfNeeded: CGEventFlags.maskShift.rawValue)
        switch character {
        case "\n", "\r": return KeyEvent(code: 36, chars: nil, mods: 0, isRepeat: false)
        case "\t": return KeyEvent(code: 48, chars: nil, mods: 0, isRepeat: false)
        default: break
        }
        if let code = unshifted[character] {
            return KeyEvent(code: code, chars: String(character), mods: 0, isRepeat: false, key: String(character))
        }
        if let code = shifted[character], let own = own[code] {
            return KeyEvent(code: code, chars: String(character), mods: shift, isRepeat: false, key: String(own))
        }
        let lower = character.lowercased()
        if lower.count == 1, let letter = lower.first, letter != character, letter.isLetter, let code = unshifted[letter] {
            return KeyEvent(code: code, chars: String(character), mods: shift, isRepeat: false, key: String(letter))
        }
        return nil
    }

    /// What each key of `unshifted` types without ⇧, by its code.
    private static let own: [UInt16: Character] = Dictionary(uniqueKeysWithValues: unshifted.map { ($0.value, $0.key) })

    /// The keys of a US ANSI keyboard (`kVK_ANSI_*`), by what they type without ⇧.
    private static let unshifted: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    /// The same keys, by what they type with ⇧ (the capitals aside).
    private static let shifted: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24, "(": 25, "&": 26, "_": 27, "*": 28, ")": 29,
        "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42, "<": 43, "?": 44, ">": 47, "~": 50,
    ]
}
