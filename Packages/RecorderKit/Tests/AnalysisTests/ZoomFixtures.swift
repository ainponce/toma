// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
@testable import Analysis

/// The synthetic take of the tests of the zoom cameras, `ZoomCameraPath` (design §7.4, §8.3 and §8.6) and `CardZoomPath`
/// (1c design §5.4), and the bits of every motion path's state, the cursor's too: source seconds count from
/// `zoomOrigin`, the screen is a display of 1440×900 pt at the origin, and one clip spans its first 20 s unless a test
/// says otherwise, so output seconds are then source seconds.
///
/// The tests that use these helpers are nested in extensions of this namespace, where they are found unqualified, so
/// other files of AnalysisTests can have helpers of their own with the same names.
enum ZoomFixtures {
    static let zoomOrigin = HostTime(nanoseconds: 9_000_000_000_000)
    static let zoomTakeID = "take-001"
    static let displayID = "display-1"
    static let cameraID = "camera-1"
    static let ln2 = log(2.0)
    static let medium = SpringSpec(damping: 1, response: 0.70)
    static let smoothed = CursorSmoothing.spring(SpringSpec(damping: 1, response: 0.16))

    static func source(_ seconds: Double) -> HostTime { zoomOrigin.adding(seconds: seconds) }

    /// `seconds` of output, in nanoseconds.
    static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    /// The first step at or after `seconds` of output.
    static func step(_ seconds: Double) -> Int { StepGrid.firstStep(atOrAfter: output(seconds)) }

    /// A segment of `track` over the take's first `seconds`.
    static func segment(_ track: String, seconds: Double = 60) -> SegmentRecord {
        SegmentRecord(
            index: 1, file: "takes/\(zoomTakeID)/\(track)/seg-0001.mov", startHostTime: zoomOrigin, endHostTime: source(seconds),
            endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
    }

    /// A take of `seconds` with one screen track, `display-1`: a display of `frame` (1440×900 pt) or, with `window`, a
    /// window there; and a camera track when `camera` is set.
    static func zoomTake(
        frame: Rect = Rect(x: 0, y: 0, width: 1440, height: 900), window: Bool = false, camera: Bool = false,
        seconds: Double = 60
    ) -> TakeRecord {
        let screen = TrackRecord(
            id: displayID, kind: window ? .window : .display,
            source: TrackSource(name: "Screen", displayID: window ? nil : 1, globalFrame: frame, pixelScale: 2),
            segments: [segment(displayID, seconds: seconds)])
        let cameraTrack = TrackRecord(
            id: cameraID, kind: .camera, source: TrackSource(name: "Camera"), segments: [segment(cameraID, seconds: seconds)])
        return TakeRecord(
            id: zoomTakeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: camera ? [screen, cameraTrack] : [screen])
    }

    static func zoomClip(_ number: Int, from: Double, to: Double, speed: Double = 1) -> Clip {
        Clip(id: "c-0000000\(number)", take: zoomTakeID, start: source(from), end: source(to), speed: speed)
    }

    static func block(
        _ number: Int, from: Double, to: Double, depth: Double? = 2, focus: ZoomFocus = .follow, instant: Bool = false
    ) -> ZoomRegion {
        ZoomRegion(
            id: "z-0000000\(number)", take: zoomTakeID, start: source(from), end: source(to), origin: .user, depth: depth,
            focus: focus, instant: instant)
    }

    /// A document of the take: Toma's style with `padding` and `frame`, the zoom `medium`, the cursor not hiding, the
    /// camera's bubble shown with `bubble`, and the project's layout and blocks.
    static func zoomDocument(
        aspect: Aspect = .landscape, padding: Double = 0, frame: WindowFrame = .none,
        sequence: [Clip] = [zoomClip(1, from: 0, to: 20)], regions: [ZoomRegion] = [], show: Bool = true,
        smoothing: CursorSmoothing = .off, bubble: CameraStyle? = nil, layout: CameraLayout = .bubble,
        layouts: [LayoutBlock] = []
    ) -> EditDocument {
        let toma = DefaultStyle.toma
        var style = toma.style
        style.padding = padding
        style.frame = frame
        var cursor = toma.cursor
        cursor.smoothing = smoothing
        cursor.hideWhenIdle = false
        return EditDocument(
            documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: aspect, frameRate: 60, sequence: sequence,
            screens: ScreenPlan(initial: [zoomTakeID: displayID], changes: []), style: style, cursor: cursor,
            zoom: ZoomPlan(show: show, auto: toma.zoomAuto, spring: medium, motionBlur: 0.5, regions: regions, suppressed: []),
            camera: CameraPlan(
                show: bubble != nil, initial: bubble.map { [zoomTakeID: $0] } ?? [:], changes: [], layout: layout,
                layouts: layouts),
            audio: AudioPlan(limiter: true, tracks: [:]))
    }

    static func paths(_ document: EditDocument, events: [InputEvent] = [], take: TakeRecord = zoomTake()) -> MotionPaths {
        MotionPaths(take: take, events: events, document: document)
    }

    static func pointer(_ seconds: Double, _ point: SIMD2<Double>) -> InputEvent {
        InputEvent(t: source(seconds), kind: .cursor(x: point.x, y: point.y))
    }

    /// Pointer positions every 1/60 s from `from` to `to` seconds, both included, at `along(t)`.
    static func trail(from: Double, to: Double, _ along: (Double) -> SIMD2<Double>) -> [InputEvent] {
        let count = Int(((to - from) * 60).rounded())
        return (0...count).map { i in
            let t = from + Double(i) / 60
            return pointer(t, along(t))
        }
    }

    static func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ tolerance: Double = 1e-9) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// Every bit of a camera's simulation on a step.
    static func bits(_ camera: ZoomCamera) -> [UInt64] {
        let values = [camera.logDepth, camera.logDepthVelocity, camera.center.x, camera.center.y, camera.centerVelocity.x]
        let all = values + [camera.centerVelocity.y, camera.target.x, camera.target.y]
        return all.map(\.bitPattern) + [UInt64(camera.block.map { $0 + 1 } ?? 0)]
    }

    /// Every bit of a placed state of the stage's camera.
    static func bits(_ state: ZoomCameraState) -> [UInt64] {
        [state.logDepth, state.center.x, state.center.y].map(\.bitPattern)
    }

    /// Every bit of a placed state of the card's camera.
    static func bits(_ state: CardZoomState) -> [UInt64] {
        [state.logDepth, state.center.x, state.center.y].map(\.bitPattern)
    }

    /// Every bit of the cursor's spring on a step (`CursorPath.State`).
    static func bits(_ state: CursorPath.State?) -> [UInt64]? {
        guard let state else { return nil }
        let values = [state.position.x, state.position.y, state.velocity.x, state.velocity.y, state.target.x, state.target.y]
        return (values + [state.scale, state.scaleVelocity]).map(\.bitPattern) + [state.pressed ? 1 : 0]
    }

    /// Every bit of a sample of the cursor's path.
    static func bits(_ sample: CursorSample?) -> [UInt64]? {
        guard let sample else { return nil }
        let values = [sample.position.x, sample.position.y, sample.opacity, sample.clickScale]
        return values.map(\.bitPattern) + [sample.pressed ? 1 : 0]
    }

    /// SplitMix64: the same numbers on every run.
    struct ZoomRandom: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
