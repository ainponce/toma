// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import Foundation
import ProjectFormat
import Synchronization

/// Where `ScrollRecorder` hears the scroll: each scroll event as `dx`, `dy` (`scrollingDeltaX/Y`) and whether they are
/// in points (`hasPreciseScrollingDeltas`) or in lines.
public protocol ScrollEventSource: Sendable {
    /// Calls `handler` for each scroll event from now on, from any thread, until `stop()`.
    @MainActor func start(_ handler: @escaping @Sendable (_ dx: Double, _ dy: Double, _ precise: Bool) -> Void)
    @MainActor func stop()
}

/// The scroll of every app, from a global monitor of `.scrollWheel`, which needs no permission. The scroll in Toma's
/// own windows is not heard (a global monitor does not get it): none of them scrolls what is recorded.
public final class LiveScrollEvents: ScrollEventSource {
    /// An NSEvent monitor token; only ever created and removed on the main actor.
    private struct MonitorToken: @unchecked Sendable { let value: Any }

    private let monitor = Mutex<MonitorToken?>(nil)

    public init() {}

    @MainActor public func start(_ handler: @escaping @Sendable (_ dx: Double, _ dy: Double, _ precise: Bool) -> Void) {
        stop()
        let token = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { event in
            handler(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), event.hasPreciseScrollingDeltas)
        }
        monitor.withLock { $0 = token.map(MonitorToken.init(value:)) }
    }

    @MainActor public func stop() {
        guard let token = monitor.withLock({ $0.take() }) else { return }
        NSEvent.removeMonitor(token.value)
    }
}

/// Records the scroll while a take runs: what scrolled in each `interval`, summed into one `scroll` event in points
/// (`pointsPerLine` for a wheel that scrolls by lines), at the time the interval ends, with where the pointer is then. An
/// interval without scroll logs nothing. The scroll of the interval a pause or a stop cuts short is logged then; while
/// paused, nothing is summed. Needs no permission.
public final class ScrollRecorder: InputRecorder, Sendable {
    public static let interval: Duration = .nanoseconds(33_333_333)
    /// The points a line of a wheel without precise deltas scrolls.
    public static let pointsPerLine = 10.0

    private struct State {
        var log: EventLogWriter?
        var generation = 0
        var paused = false
        var timer: (any RecordingTimer)?
        /// Summed since the last event, in points.
        var dx = 0.0
        var dy = 0.0
        /// Something scrolled since the last event (the sum may still be zero).
        var pending = false
    }

    private let events: any ScrollEventSource
    private let clock: @Sendable () -> HostTime
    private let location: @Sendable () -> CGPoint
    private let ticks: RecordingTicks
    private let queue = DispatchSerialQueue(label: "dev.toma.scroll", qos: .userInteractive)
    private let state = Mutex(State())

    public convenience init(
        events: any ScrollEventSource = LiveScrollEvents(), clock: @escaping @Sendable () -> HostTime = HostTime.now,
        location: @escaping @Sendable () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero }
    ) {
        self.init(events: events, clock: clock, location: location, ticks: .live)
    }

    /// Tests pass their own ticks.
    init(
        events: any ScrollEventSource, clock: @escaping @Sendable () -> HostTime, location: @escaping @Sendable () -> CGPoint,
        ticks: RecordingTicks
    ) {
        self.events = events
        self.clock = clock
        self.location = location
        self.ticks = ticks
    }

    public func start(log: EventLogWriter) async {
        let generation: Int? = state.withLock { s in
            guard s.log == nil else { return nil }
            s.log = log
            s.generation += 1
            s.paused = false
            (s.dx, s.dy, s.pending) = (0, 0, false)
            s.timer = makeTimer()
            return s.generation
        }
        guard let generation else { return }
        let events = events
        await MainActor.run {
            events.start { [weak self] dx, dy, precise in self?.add(dx: dx, dy: dy, precise: precise) }
        }
        // stop() may have run while the monitor was being installed; then it must not stay.
        let stopped = state.withLock { $0.log == nil || $0.generation != generation }
        if stopped { await MainActor.run { events.stop() } }
    }

    /// Logs the scroll of the interval so far, and sums nothing until `resume()`. The monitor stays installed.
    public func pause() async {
        let end = intervalEnd()
        let timer = state.withLock { s -> (any RecordingTimer)? in
            guard s.log != nil, !s.paused else { return nil }
            if let end { flush(&s, at: end.time, end.position) }
            // A scroll that came after `intervalEnd()` looked is the pause's.
            (s.dx, s.dy, s.pending) = (0, 0, false)
            s.paused = true
            defer { s.timer = nil }
            return s.timer
        }
        timer?.cancel()
    }

    public func resume() async {
        state.withLock { s in
            guard s.log != nil, s.paused else { return }
            s.paused = false
            s.timer = makeTimer()
        }
    }

    /// Logs the scroll of the interval so far.
    public func stop() async {
        let end = intervalEnd()
        let timer = state.withLock { s -> (any RecordingTimer)? in
            if let end { flush(&s, at: end.time, end.position) }
            s.log = nil
            s.paused = false
            (s.dx, s.dy, s.pending) = (0, 0, false)
            defer { s.timer = nil }
            return s.timer
        }
        timer?.cancel()
        let events = events
        await MainActor.run { events.stop() }
    }

    private func makeTimer() -> any RecordingTimer {
        ticks.every(Self.interval, queue) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard let end = intervalEnd() else { return }
        state.withLock { flush(&$0, at: end.time, end.position) }
    }

    /// The time now and where the pointer is, if a scroll is waiting to be logged; `nil` otherwise, without asking
    /// where the pointer is (a round trip to the window server).
    private func intervalEnd() -> (time: HostTime, position: CGPoint)? {
        guard state.withLock({ $0.log != nil && !$0.paused && $0.pending }) else { return nil }
        return (clock(), location())
    }

    /// One scroll event, in points. One with a part that is not a number, or that does not move, is not a scroll.
    private func add(dx: Double, dy: Double, precise: Bool) {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        let scale = precise ? 1 : Self.pointsPerLine
        state.withLock { s in
            guard s.log != nil, !s.paused else { return }
            s.dx += dx * scale
            s.dy += dy * scale
            s.pending = true
        }
    }

    /// Appends what was summed, if anything (a sum too large to be a number is dropped), and starts the next sum. Under
    /// the lock, so nothing is appended once `stop()` has cleared the log or `pause()` has returned.
    private func flush(_ s: inout State, at time: HostTime, _ position: CGPoint) {
        guard let log = s.log, !s.paused, s.pending else { return }
        let (x, y) = (Double(position.x), Double(position.y))
        if s.dx.isFinite, s.dy.isFinite, x.isFinite, y.isFinite {
            log.append(InputEvent(t: time, kind: .scroll(dx: s.dx, dy: s.dy, x: x, y: y)))
        }
        (s.dx, s.dy, s.pending) = (0, 0, false)
    }
}
