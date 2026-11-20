// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// How an annotation looks at one instant of the output (`annotation-1`): its opacity, the scale of its pop and how much of
/// its stroke is drawn.
public struct AnnotationState: Equatable, Sendable {
    /// 0 to 1: the annotation's own opacity times its entrance and its exit.
    public var opacity: Double
    /// 1 but while it pops in (0.9 to 1).
    public var scale: Double
    /// 0 to 1: the fraction of an arrow's or a shape's stroke that is drawn; 1 for everything else and once it is in.
    public var drawn: Double

    public init(opacity: Double, scale: Double, drawn: Double) {
        self.opacity = opacity
        self.scale = scale
        self.drawn = drawn
    }
}

/// When an annotation is shown and how it comes in and goes out (phase 3 plan 3a, decision 3). Pure: the track, the
/// numbering of the steps and the render read the same rule.
public enum AnnotationTiming {
    public static let algorithm = "annotation-1"
    /// The entrance and the exit last this long, ns, or half of the annotation's length if that is less.
    public static let transition: Int64 = 250_000_000
    /// The scale a pop starts at.
    public static let popStart = 0.9
    /// The response of the critical spring of a pop, in seconds (`Motion.panelSwap`).
    public static let popResponse = 0.30

    /// The output range the annotation's block takes, the cuts inside it closed: anchored to the take, where its source
    /// range is seen (`TimeMap.outputRange(ofSource:take:)`, freezes inside it included); `nil` if all of it is cut;
    /// anchored to the output, `[start, end)` (`nil` if it is empty); the whole video, `0..<D` (`nil` for an output of 0 ns).
    /// The range can be empty when what is kept lasts 0 ns of output.
    public static func outputRange(of annotation: Annotation, document: EditDocument, timeMap: TimeMap) -> Range<Int64>? {
        switch annotation.anchor {
        case let .content(take, start, end):
            guard start < end else { return nil }
            return timeMap.outputRange(ofSource: start..<end, take: take)
        case let .output(start, end):
            return start < end ? start..<end : nil
        case .whole:
            return timeMap.duration > 0 ? 0..<timeMap.duration : nil
        }
    }

    /// The look of `annotation` at output time `τ`; `nil` where it is not shown: outside its range; for one anchored to the
    /// take, where the output shows something else than its source range (a cut, another take, a title card or an imported
    /// clip). In a frozen frame of its take it is shown when the frame's point is inside its source range (decision 3),
    /// also one at an edge of its output range rather than inside it (one put at the end of a run of the take, or before
    /// the stretch its source starts in), and the progress of its entrance and exit stands still there.
    public static func state(of annotation: Annotation, atOutput τ: Int64, document: EditDocument, timeMap: TimeMap) -> AnnotationState? {
        guard τ >= 0, τ < timeMap.duration, let range = outputRange(of: annotation, document: document, timeMap: timeMap),
            range.contains(τ) || isFrozenInside(annotation, atOutput: τ, document: document, timeMap: timeMap)
        else { return nil }
        let length = range.upperBound - range.lowerBound
        let t = min(transition, length / 2)
        // Output nanoseconds since it came in and until it goes out.
        var elapsed = τ - range.lowerBound
        var remaining = range.upperBound - τ
        if case let .content(take, start, end) = annotation.anchor {
            guard let (k, x) = timeMap.source(atOutput: τ), document.sequence.indices.contains(k) else { return nil }
            let clip = document.sequence[k]
            guard clip.take == take, x >= start, x < end else { return nil }
            switch clip.content {
            case nil, .freeze?: break
            default: return nil
            }
            // A start that is cut has already come in.
            elapsed =
                timeMap.output(atSource: start, take: take) == nil
                ? .max : timeMap.outputRange(ofSource: start..<x, take: take).map { $0.upperBound - $0.lowerBound } ?? 0
            remaining = timeMap.outputRange(ofSource: x..<end, take: take).map { $0.upperBound - $0.lowerBound } ?? 0
        }
        let into = fraction(elapsed, of: t, active: annotation.enter != .none)
        let out = fraction(remaining, of: t, active: annotation.exit != .none)
        let own = annotation.opacity.isFinite ? min(max(annotation.opacity, 0), 1) : 1
        let fadeOut = smoothstep(out)
        let isStroke: Bool
        switch annotation.kind {
        case .arrow, .shape: isStroke = true
        default: isStroke = false
        }
        switch annotation.enter {
        case .none:
            return AnnotationState(opacity: own * fadeOut, scale: 1, drawn: 1)
        case .fade:
            return AnnotationState(opacity: own * smoothstep(into) * fadeOut, scale: 1, drawn: 1)
        case .pop:
            return AnnotationState(opacity: own * into * fadeOut, scale: pop(into), drawn: 1)
        case .draw:
            guard isStroke else { return AnnotationState(opacity: own * smoothstep(into) * fadeOut, scale: 1, drawn: 1) }
            return AnnotationState(opacity: own * fadeOut, scale: 1, drawn: smoothstep(into))
        }
    }

    /// Whether output time `τ` is in a frozen frame of the take `annotation` is anchored to whose point is inside its
    /// source range.
    private static func isFrozenInside(_ annotation: Annotation, atOutput τ: Int64, document: EditDocument, timeMap: TimeMap) -> Bool {
        guard case let .content(take, start, end) = annotation.anchor, let (k, x) = timeMap.source(atOutput: τ),
            document.sequence.indices.contains(k), case .freeze? = document.sequence[k].content
        else { return false }
        return document.sequence[k].take == take && x >= start && x < end
    }

    /// The scale of a pop at `progress` of its entrance (0 to 1): `0.9 + 0.1 × s(p·0.25 s) / s(0.25 s)` with the critical
    /// spring `s(t) = 1 − (1 + ωt)·e^(−ωt)`, `ω = 2π / 0.30`; exactly 1 at 1.
    public static func pop(_ progress: Double) -> Double {
        guard progress.isFinite, progress > 0 else { return popStart }
        guard progress < 1 else { return 1 }
        let omega = 2 * Double.pi / popResponse
        func s(_ t: Double) -> Double { 1 - (1 + omega * t) * exp(-omega * t) }
        let nominal = Double(transition) / 1e9
        return popStart + (1 - popStart) * s(progress * nominal) / s(nominal)
    }

    /// `elapsed / t` held to 0…1; 1 when the transition is off or lasts nothing.
    private static func fraction(_ elapsed: Int64, of t: Int64, active: Bool) -> Double {
        guard active, t > 0 else { return 1 }
        return min(max(Double(elapsed) / Double(t), 0), 1)
    }

    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
