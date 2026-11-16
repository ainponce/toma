// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The opacity of a cursor hidden when it does not move (design §8.5), in output time (integer nanoseconds).
///
/// - Still: once the raw position stays within 3 pt of where it stopped for `delay` seconds, it fades out in 0.30 s
///   (ease in-out). It stopped at a position from which every later one is within 3 pt, up to the first that is not:
///   there it moves again.
/// - It comes back in 0.15 s, starting 0.10 s before it moves (the path is known in advance), so it shows already
///   moving; before a click, 0.15 s before it, so it is whole at the click.
/// - It is never hidden in the 0.5 s after a click, nor while a button is down (from 0.15 s before the press to the
///   release). A click does not start the delay again: a cursor that has been still long enough fades out again 0.5 s
///   after it.
///
/// The fades are smoothstep curves, `3x² − 2x³`. A return starts from the opacity it has then, so a fade cut short
/// never jumps.
public struct IdleVisibility: Sendable {
    // Design §8.5. Distances in points, times in output nanoseconds.
    static let stillRadius = 3.0
    static let fadeOut: Int64 = 300_000_000
    static let fadeIn: Int64 = 150_000_000
    static let returnBeforeMoving: Int64 = 100_000_000
    static let returnBeforeClick: Int64 = 150_000_000
    static let shownAfterClick: Int64 = 500_000_000

    /// From where it starts to fade out to where it starts to come back: sorted, apart, never empty.
    private let hidden: [Range<Int64>]

    /// `samples` are the raw positions in output time, each with whether a button is down from it on (a press lasts
    /// from the first position that has one down to the next one that has none); `clicks`, the output times of the
    /// clicks; `delay`, the seconds without moving before it is hidden (one that is negative or not a number is 0).
    public init(samples: [(output: Int64, point: SIMD2<Double>, pressed: Bool)], clicks: [Int64], delay: Double) {
        let samples = Self.inOutputOrder(samples) { $0.output }
        var presses: [Range<Int64>] = []
        var pressStart: Int64?
        for sample in samples {
            if sample.pressed, pressStart == nil { pressStart = sample.output }
            if !sample.pressed, let start = pressStart {
                presses.append(start..<sample.output)
                pressStart = nil
            }
        }
        if let start = pressStart { presses.append(start..<Int64.max) }
        self.init(positions: samples.map { ($0.output, $0.point) }, presses: presses, clicks: clicks, delay: delay)
    }

    /// `positions` are the raw positions in output time; `presses`, the output ranges during which a button is down,
    /// from each press to its release (an empty one is none), known apart from the positions (a press can come while
    /// the pointer stands still); `clicks` and `delay` as in `init(samples:clicks:delay:)`.
    public init(positions: [(output: Int64, point: SIMD2<Double>)], presses: [Range<Int64>], clicks: [Int64], delay: Double) {
        let samples = Self.inOutputOrder(positions) { $0.output }
        let delay = max(TimeMap.outputNanoseconds(seconds: delay), 0)

        // Where it must be shown: around each click, and from before each press to its release.
        let shown = clicks.map { $0.subtractingSaturating(Self.returnBeforeClick)..<$0.addingSaturating(Self.shownAfterClick) }
            + presses.filter { !$0.isEmpty }.map { $0.lowerBound.subtractingSaturating(Self.returnBeforeClick)..<$0.upperBound }
        let kept = Self.merged(shown)

        // Where it heads for hidden: from `delay` after it stopped to 0.10 s before it moves, outside `kept`.
        var hidden: [Range<Int64>] = []
        var i = 0
        while i < samples.count {
            let stop = samples[i]
            var j = i + 1
            while j < samples.count, distance(samples[j].point, stop.point) <= Self.stillRadius { j += 1 }
            let start = stop.output.addingSaturating(delay)
            let end = j < samples.count ? samples[j].output.subtractingSaturating(Self.returnBeforeMoving) : Int64.max
            if start < end { hidden += Self.subtracting(kept, from: start..<end) }
            i = j
        }
        self.hidden = hidden
    }

    /// 1 when shown, 0 when hidden, in between while it fades.
    public func opacity(atOutput τ: Int64) -> Double {
        // The last stretch that starts at or before `τ`; an earlier one can still be coming back.
        var low = 0, high = hidden.count
        while low < high {
            let mid = (low + high) / 2
            if hidden[mid].lowerBound <= τ { low = mid + 1 } else { high = mid }
        }
        var opacity = 1.0
        for k in stride(from: low - 1, through: 0, by: -1) {
            // The stretches are apart and sorted, so their ends are too: once one is back, every earlier one is.
            if τ.subtractingSaturating(hidden[k].upperBound) >= Self.fadeIn { break }
            opacity = min(opacity, Self.opacity(at: τ, in: hidden[k]))
        }
        return opacity
    }

    // MARK: - Private

    /// The opacity at `τ` (at or after its start) of a stretch: fading out over `fadeOut` from its start, coming back
    /// over `fadeIn` from its end, from where the fade got to.
    private static func opacity(at τ: Int64, in stretch: Range<Int64>) -> Double {
        func fadedOut(after elapsed: Int64) -> Double { 1 - smoothstep(Double(elapsed) / Double(fadeOut)) }
        guard τ >= stretch.upperBound else { return fadedOut(after: τ.subtractingSaturating(stretch.lowerBound)) }
        let from = fadedOut(after: stretch.upperBound.subtractingSaturating(stretch.lowerBound))
        let back = Double(τ.subtractingSaturating(stretch.upperBound)) / Double(fadeIn)
        return back >= 1 ? 1 : from + (1 - from) * smoothstep(back)
    }

    /// `items` in the order of their `output`, those at the same instant in the order they have.
    private static func inOutputOrder<Item>(_ items: [Item], _ output: (Item) -> Int64) -> [Item] {
        items.enumerated().sorted { (output($0.element), $0.offset) < (output($1.element), $1.offset) }.map(\.element)
    }

    /// `3x² − 2x³` of `x` held in [0, 1].
    private static func smoothstep(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// `ranges` sorted, with those that overlap or touch joined; empty ones left out.
    private static func merged(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        var merged: [Range<Int64>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// What is left of `range` outside the sorted, apart ranges `holes`, in order; never an empty piece.
    private static func subtracting(_ holes: [Range<Int64>], from range: Range<Int64>) -> [Range<Int64>] {
        var pieces: [Range<Int64>] = []
        var start = range.lowerBound
        // The first hole that ends after the start.
        var low = 0, high = holes.count
        while low < high {
            let mid = (low + high) / 2
            if holes[mid].upperBound <= start { low = mid + 1 } else { high = mid }
        }
        for hole in holes[low...] {
            guard hole.lowerBound < range.upperBound else { break }
            if start < hole.lowerBound { pieces.append(start..<hole.lowerBound) }
            start = max(start, hole.upperBound)
            if start >= range.upperBound { return pieces }
        }
        if start < range.upperBound { pieces.append(start..<range.upperBound) }
        return pieces
    }
}
