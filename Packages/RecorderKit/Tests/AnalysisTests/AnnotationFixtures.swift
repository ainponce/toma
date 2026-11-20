// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

@testable import Analysis

/// A take of 20 s: clips [0, 8) and [10, 20) s with a frozen frame of 2 s at 8 s between them (and so 8 s of source cut
/// out: [8, 10) is cut), as output `0–8 s`, `8–10 s` frozen, `10–20 s`.
enum AnnotationFixtures {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }
    static func ns(_ s: Double) -> Int64 { Int64((s * 1e9).rounded()) }

    static func clips(speedOfFirst: Double = 1) -> [Clip] {
        [
            Clip(id: "c-00000001", take: "take-001", start: at(0), end: at(8), speed: speedOfFirst),
            Clip(id: "c-00000002", take: "take-001", start: at(8), end: at(8), speed: 1, content: .freeze(duration: ns(2))),
            Clip(id: "c-00000003", take: "take-001", start: at(10), end: at(20), speed: 1),
        ]
    }

    static func document(_ annotations: [Annotation] = [], sequence: [Clip]? = nil) -> EditDocument {
        EditDocument(
            documentVersion: 4, logSequence: 0, aspect: .landscape, frameRate: 60, sequence: sequence ?? clips(),
            screens: ScreenPlan(initial: [:], changes: []), style: DefaultStyle.toma.style, cursor: DefaultStyle.toma.cursor,
            zoom: ZoomPlan(show: true, auto: DefaultStyle.toma.zoomAuto, spring: DefaultStyle.toma.zoomSpring, motionBlur: 0, regions: [], suppressed: []),
            camera: CameraPlan(show: true, initial: [:], changes: []), audio: AudioPlan(limiter: false, tracks: [:]),
            annotations: AnnotationPlan(items: annotations))
    }

    static func text(
        _ id: String = "a-00000001", anchor: AnnotationAnchor, layer: Int = 0, kind: AnnotationKind? = nil, enter: AnnotationEnter = .fade,
        exit: AnnotationExit = .fade, opacity: Double = 1
    ) -> Annotation {
        Annotation(
            id: id, anchor: anchor, layer: layer, kind: kind ?? .text(TextAnnotation(string: "x", preset: .plain)),
            rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1), opacity: opacity, enter: enter, exit: exit)
    }

    static func content(_ a: Double, _ b: Double) -> AnnotationAnchor { .content(take: "take-001", start: at(a), end: at(b)) }
}
