// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// What the keys on screen show: the shortcuts as loose keys and, in `.all`, what is typed as a pill.
public enum KeyOverlayContent: Equatable, Sendable {
    case keys([String])
    case text(String)
}

/// One thing drawn at an instant, at `opacity` from 0 to 1 (never 0: what is invisible is not listed).
public struct KeyOverlayShown: Equatable, Sendable {
    public var content: KeyOverlayContent
    public var opacity: Double

    public init(content: KeyOverlayContent, opacity: Double) {
        self.content = content
        self.opacity = opacity
    }
}

/// `keyOverlay-1` (phase 2 design §7.4, plan decision 13): the keys of one take as the output shows them. A key in a cut
/// is not shown; the times are the output's (`TimeMap`), so a speed compresses when the keys come and how far apart, and
/// the fades and the hold are of output time.
///
/// - A display (a shortcut or a pill) appears with its first key in a fade of `fadeIn`, stays `hold` after its last key
///   and goes in `fadeOut`.
/// - A new display that starts while another is still on replaces it: the old one goes in `crossfade` while the new one
///   comes in. At most two are shown, the one going first first.
/// - A pill takes the characters typed with at most `typingGap` between them; a shortcut, ↩ or a loose special key ends it.
///   ⌫ takes the last character off. It keeps `visibleCharacters`, cutting from the left with "…".
public struct KeyOverlayTimeline: Sendable {
    public static let id = "keyOverlay-1"
    public static let fadeIn: Int64 = 100_000_000
    public static let hold: Int64 = 1_000_000_000
    public static let fadeOut: Int64 = 200_000_000
    public static let crossfade: Int64 = 100_000_000
    public static let typingGap: Int64 = 1_500_000_000
    public static let visibleCharacters = 20

    private struct Display {
        var start: Int64
        /// The output time of each key, in order, and what the display says after each.
        var keyTimes: [Int64]
        var contents: [KeyOverlayContent]
        var isPill: Bool
        /// Where the next display starts if it starts while this one is on (`nil` if it does not).
        var replacedAt: Int64?
        /// Where it is gone for sure: the start of the display after the next, so at most two are on.
        var cutAt: Int64?

        var lastKey: Int64 { keyTimes.last ?? start }
        var naturalEnd: Int64 { lastKey + KeyOverlayTimeline.hold + KeyOverlayTimeline.fadeOut }
    }

    private let displays: [Display]

    public init(events: [InputEvent], take: String, timeMap: TimeMap, mode: KeyOverlayMode) {
        guard mode != .off else {
            displays = []
            return
        }
        var built: [Display] = []
        /// The index of the pill that takes characters, if one is open.
        var openPill: Int?
        let keys = events.compactMap {
            event -> (t: Int64, code: UInt16, chars: String?, mods: UInt32, isRepeat: Bool, key: String?)? in
            guard case .keyPress(let code, let chars, let mods, let isRepeat, let key) = event.kind,
                let output = timeMap.output(atSource: event.t, take: take)
            else { return nil }
            return (output, code, chars, mods, isRepeat, key)
        }
        for key in keys.enumerated().sorted(by: { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }).map(\.element) {
            if KeyLabels.isShortcut(code: key.code, mods: key.mods) {
                guard let label = KeyLabels.key(code: key.code, chars: key.chars, mods: key.mods, key: key.key) else { continue }
                Self.addKeys(KeyLabels.modifiers(key.mods) + [label], at: key.t, repeating: key.isRepeat, to: &built)
                openPill = nil
                continue
            }
            guard mode == .all else { continue }
            if KeyLabels.returnCodes.contains(key.code) {
                openPill = nil
            } else if key.code == KeyLabels.deleteCode {
                if let open = openPill, case .text(let text) = built[open].contents.last, !text.isEmpty {
                    var characters = Array(text)
                    characters.removeLast()
                    built[open].keyTimes.append(key.t)
                    built[open].contents.append(.text(String(characters)))
                } else {
                    Self.addKeys(["⌫"], at: key.t, repeating: key.isRepeat, to: &built)
                    openPill = nil
                }
            } else if let label = KeyLabels.specialLabel(code: key.code), key.code != KeyLabels.spaceCode {
                Self.addKeys([label], at: key.t, repeating: key.isRepeat, to: &built)
                openPill = nil
            } else if let chars = key.chars, !chars.isEmpty {
                if let open = openPill, key.t - built[open].lastKey <= Self.typingGap, case .text(let text) = built[open].contents.last {
                    built[open].keyTimes.append(key.t)
                    built[open].contents.append(.text(text + chars))
                } else if chars.allSatisfy(\.isWhitespace) {
                    continue
                } else {
                    built.append(Display(
                        start: key.t, keyTimes: [key.t], contents: [.text(chars)],
                        isPill: true, replacedAt: nil, cutAt: nil))
                    openPill = built.count - 1
                }
            }
        }
        // Who replaces whom, and the most that are on at once.
        for i in built.indices {
            if i + 1 < built.count, built[i + 1].start < built[i].naturalEnd { built[i].replacedAt = built[i + 1].start }
            if i + 2 < built.count { built[i].cutAt = built[i + 2].start }
        }
        displays = built
    }

    public var isEmpty: Bool { displays.isEmpty }

    /// What is on at output time `τ`, with its opacity: at most two, the one that goes first first.
    public func shown(atOutput τ: Int64) -> [KeyOverlayShown] {
        // Display `i` is gone once the one after the next starts, so only the last two that started can be on.
        let started = displays.partitionPoint { $0.start <= τ }
        var result: [KeyOverlayShown] = []
        for i in max(0, started - 2)..<started {
            let display = displays[i]
            if let cut = display.cutAt, τ >= cut { continue }
            guard let opacity = Self.opacity(of: display, at: τ), opacity > 0 else { continue }
            let k = display.keyTimes.partitionPoint { $0 <= τ } - 1
            let content = display.contents[max(k, 0)]
            if case .text(let text) = content {
                if text.isEmpty { continue }
                result.append(KeyOverlayShown(content: .text(Self.visible(text)), opacity: opacity))
            } else {
                result.append(KeyOverlayShown(content: content, opacity: opacity))
            }
        }
        return result
    }

    // MARK: - Private

    private static func opacity(of display: Display, at τ: Int64) -> Double? {
        guard τ >= display.start else { return nil }
        let last = display.keyTimes[max(display.keyTimes.partitionPoint { $0 <= τ } - 1, 0)]
        var opacity = min(Double(τ - display.start) / Double(fadeIn), 1)
        let quiet = τ - last
        if quiet > hold { opacity = min(opacity, 1 - Double(quiet - hold) / Double(fadeOut)) }
        if let replaced = display.replacedAt, τ >= replaced {
            opacity = min(opacity, 1 - Double(τ - replaced) / Double(crossfade))
        }
        return min(max(opacity, 0), 1)
    }

    /// A shortcut or loose key: a repeat of the one on screen lengthens it; anything else is a display of its own.
    private static func addKeys(_ labels: [String], at t: Int64, repeating isRepeat: Bool, to built: inout [Display]) {
        let content = KeyOverlayContent.keys(labels)
        if isRepeat, let last = built.indices.last, !built[last].isPill, built[last].contents.last == content {
            built[last].keyTimes.append(t)
            built[last].contents.append(content)
        } else {
            built.append(Display(start: t, keyTimes: [t], contents: [content], isPill: false, replacedAt: nil, cutAt: nil))
        }
    }

    /// What a pill says: the last `visibleCharacters` of what was typed, with "…" before them if it is longer.
    private static func visible(_ text: String) -> String {
        text.count > visibleCharacters ? "…" + String(text.suffix(visibleCharacters)) : text
    }
}

extension RandomAccessCollection where Index == Int {
    /// The first index for which `isBefore` is false, given that it is true for a prefix and false after.
    fileprivate func partitionPoint(_ isBefore: (Element) -> Bool) -> Int {
        var (low, high) = (startIndex, endIndex)
        while low < high {
            let middle = low + (high - low) / 2
            if isBefore(self[middle]) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
