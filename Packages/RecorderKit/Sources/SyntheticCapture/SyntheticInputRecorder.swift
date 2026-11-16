// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Dispatch
import Foundation
import ProjectFormat
import Recording
import Synchronization

/// The input of `synth-record`, the same in every take. From its start, in seconds of the take (pauses included): the
/// cursor going round a circle of 90 pt about (320, 180) every 4 s, logged at 60 Hz; a left click, down and 0.1 s later
/// up, at 0.5 s and every second after; the arrow from the start and the I-beam from 1 s, drawn here, with their images
/// in `cursors/` (written by a `CursorImageRecorder`, so they are named and logged as in a real take, with their
/// `kind`); a scroll of `dy` −42.5 pt at 2 s; and a key in each 250 ms window that starts from 3 s to 4 s. What falls in
/// a pause is left out. Needs no permission.
public final class SyntheticInputRecorder: InputRecorder, Sendable {
    /// How often the cursor is logged, and the clicks, the scroll and the keys that are due.
    static let interval: Duration = .nanoseconds(16_666_667)
    static let center = SIMD2<Double>(320, 180)
    static let radius = 90.0
    /// Seconds a turn of the circle lasts.
    static let period = 4.0

    private struct State {
        var log: EventLogWriter?
        var paused = false
        var timer: (any RecordingTimer)?
        /// Events due at or before this time are done: logged, or left out by a pause.
        var done = HostTime(nanoseconds: 0)
    }

    private let clock: @Sendable () -> HostTime
    private let takeStart = TakeStart()
    private let cursorImages: CursorImageRecorder
    private let queue = DispatchSerialQueue(label: "dev.toma.synthetic-input", qos: .userInteractive)
    private let state = Mutex(State())

    public init(clock: @escaping @Sendable () -> HostTime = HostTime.now) {
        self.clock = clock
        let shapes = SyntheticCursor(clock: clock, start: takeStart)
        cursorImages = CursorImageRecorder(source: shapes, kinds: SyntheticCursor.kinds, clock: clock)
    }

    public func start(log: EventLogWriter) async {
        let now = clock()
        let started = state.withLock { s in
            guard s.log == nil else { return false }
            s = State(log: log, done: now)
            takeStart.set(now)
            s.timer = makeTimer()
            return true
        }
        guard started else { return }
        await cursorImages.start(log: log)
    }

    public func pause() async {
        let timer = state.withLock { s -> (any RecordingTimer)? in
            guard s.log != nil, !s.paused else { return nil }
            s.paused = true
            defer { s.timer = nil }
            return s.timer
        }
        timer?.cancel()
        await cursorImages.pause()
    }

    /// Goes on from now: what was due during the pause is left out.
    public func resume() async {
        let now = clock()
        state.withLock { s in
            guard s.log != nil, s.paused else { return }
            s.paused = false
            s.done = now
            s.timer = makeTimer()
        }
        await cursorImages.resume()
    }

    public func stop() async {
        let timer = state.withLock { s -> (any RecordingTimer)? in
            defer { s = State() }
            return s.timer
        }
        timer?.cancel()
        await cursorImages.stop()
        takeStart.set(nil)
    }

    private func makeTimer() -> any RecordingTimer {
        RecordingTicks.live.every(Self.interval, queue) { [weak self] in self?.tick() }
    }

    /// Logs what came due since the last tick, then where the cursor is now. Under the lock, so nothing is appended once
    /// `stop()` has cleared the log or `pause()` has returned.
    private func tick() {
        let now = clock()
        guard let start = takeStart.time else { return }
        state.withLock { s in
            guard let log = s.log, !s.paused, now > s.done else { return }
            for event in Self.due(after: s.done, through: now, start: start) { log.append(event) }
            let position = Self.position(at: now.seconds(since: start))
            log.append(InputEvent(t: now, kind: .cursor(x: position.x, y: position.y)))
            s.done = now
        }
    }

    /// The clicks, the scroll and the keys of a take that started at `start`, after `from` and until `to`, by time.
    static func due(after from: HostTime, through to: HostTime, start: HostTime) -> [InputEvent] {
        func at(_ seconds: Double) -> HostTime { start.adding(seconds: seconds) }
        func inRange(_ t: HostTime) -> Bool { t > from && t <= to }
        var events: [InputEvent] = []
        // The clicks of the seconds the range touches.
        let first = max(0, Int(from.seconds(since: start).rounded(.down)) - 1)
        let last = Int(to.seconds(since: start).rounded(.down))
        for second in stride(from: first, through: last, by: 1) {
            let down = Double(second) + 0.5, up = down + 0.1
            let (downAt, upAt) = (position(at: down), position(at: up))
            if inRange(at(down)) { events.append(InputEvent(t: at(down), kind: .mouseDown(.left, x: downAt.x, y: downAt.y))) }
            if inRange(at(up)) { events.append(InputEvent(t: at(up), kind: .mouseUp(.left, x: upAt.x, y: upAt.y))) }
        }
        if inRange(at(2)) {
            let position = position(at: 2)
            events.append(InputEvent(t: at(2), kind: .scroll(dx: 0, dy: -42.5, x: position.x, y: position.y)))
        }
        // The windows that start at 3 s or later, and before 4 s.
        let threeSeconds = at(3)
        var window = KeyActivityRecorder.windowStart(of: threeSeconds)
        if window < threeSeconds { window.nanoseconds += KeyActivityRecorder.window }
        while window < at(4) {
            if inRange(window) { events.append(InputEvent(t: window, kind: .keyActivity)) }
            window.nanoseconds += KeyActivityRecorder.window
        }
        return events.sorted { $0.t < $1.t }
    }

    /// Where the cursor is `seconds` into the take.
    static func position(at seconds: Double) -> SIMD2<Double> {
        let angle = 2 * Double.pi * seconds / period
        return center + radius * SIMD2(cos(angle), sin(angle))
    }
}

/// When a take started; `nil` between takes.
private final class TakeStart: Sendable {
    private let value = Mutex<HostTime?>(nil)

    var time: HostTime? { value.withLock { $0 } }

    func set(_ time: HostTime?) {
        value.withLock { $0 = time }
    }
}

/// The arrow for the first second of the take, the I-beam after it: Toma's own drawings, at 4×.
private final class SyntheticCursor: SystemCursorSource {
    private static let arrowFingerprint: UInt64 = 0x546F_6D61_4172_726F
    private static let iBeamFingerprint: UInt64 = 0x546F_6D61_4942_6561
    /// Which system cursor each drawing stands for.
    static let kinds = CursorKindMatcher(references: [arrowFingerprint: .arrow, iBeamFingerprint: .iBeam])

    private let arrow: CursorSnapshot?
    private let iBeam: CursorSnapshot?
    private let clock: @Sendable () -> HostTime
    private let start: TakeStart

    init(clock: @escaping @Sendable () -> HostTime, start: TakeStart) {
        self.clock = clock
        self.start = start
        arrow = Self.draw(pointSize: [24, 32], hotspot: [4, 4], fingerprint: Self.arrowFingerprint) { context in
            // Tip at the hotspot, y down.
            let points: [CGPoint] = [
                CGPoint(x: 4, y: 4), CGPoint(x: 4, y: 24), CGPoint(x: 9, y: 19.5), CGPoint(x: 12.5, y: 27),
                CGPoint(x: 15.5, y: 25.8), CGPoint(x: 12, y: 18.5), CGPoint(x: 18.5, y: 18.5),
            ]
            context.addLines(between: points)
            context.closePath()
        }
        iBeam = Self.draw(pointSize: [12, 24], hotspot: [6, 12], fingerprint: Self.iBeamFingerprint) { context in
            context.addRect(CGRect(x: 2.5, y: 2, width: 7, height: 1.5))
            context.addRect(CGRect(x: 5.25, y: 3.5, width: 1.5, height: 17))
            context.addRect(CGRect(x: 2.5, y: 20.5, width: 7, height: 1.5))
        }
    }

    @MainActor func current() -> CursorSnapshot? {
        guard let start = start.time else { return arrow }
        return clock().seconds(since: start) < 1 ? arrow : iBeam
    }

    /// The path `shape` adds, in points from the top left, filled black with a white edge, at 4×.
    private static func draw(
        pointSize: SIMD2<Double>, hotspot: SIMD2<Double>, fingerprint: UInt64, _ shape: (CGContext) -> Void
    ) -> CursorSnapshot? {
        let scale = 4.0
        let (width, height) = (Int(pointSize.x * scale), Int(pointSize.y * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        shape(context)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1.5)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        guard let image = context.makeImage() else { return nil }
        return CursorSnapshot(image: image, pointSize: pointSize, hotspot: hotspot, fingerprint: fingerprint)
    }
}
