// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import Foundation
import ProjectFormat
import Synchronization

/// Records pointer input into the event log while a take runs.
public protocol InputRecorder: Sendable {
    func start(log: EventLogWriter) async
    func stop() async
}

/// Records nothing; for takes made without input recording.
public final class NoInputRecorder: InputRecorder {
    public init() {}
    public func start(log: EventLogWriter) async {}
    public func stop() async {}
}

/// Samples the cursor at `sampleRate` Hz and records button presses, so the editor can redraw
/// the cursor later. Needs neither Accessibility nor Input Monitoring: it reads the cursor
/// position and listens only to mouse-button events.
public final class CursorRecorder: InputRecorder, Sendable {
    public static let sampleRate = 120.0

    /// An NSEvent monitor token; only ever created and removed on the main actor.
    private struct MonitorToken: @unchecked Sendable { let value: Any }

    private struct State {
        var log: EventLogWriter?
        var generation = 0
        var timer: DispatchSourceTimer?
        var monitors: [MonitorToken] = []
        var lastPosition: CGPoint?
    }

    private let clock: @Sendable () -> HostTime
    private let location: @Sendable () -> CGPoint
    private let queue = DispatchQueue(label: "dev.toma.cursor-sampler", qos: .userInteractive)
    private let state = Mutex(State())

    public init(
        clock: @escaping @Sendable () -> HostTime = HostTime.now,
        location: @escaping @Sendable () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero }
    ) {
        self.clock = clock
        self.location = location
    }

    public func start(log: EventLogWriter) async {
        let generation: Int? = state.withLock { s in
            guard s.log == nil else { return nil }
            s.log = log
            s.generation += 1
            s.lastPosition = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000 / Self.sampleRate))
            timer.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.sample() }
            s.timer = timer
            timer.resume()
            return s.generation
        }
        guard let generation else { return }

        let tokens = await MainActor.run { () -> [MonitorToken] in
            let mask: NSEvent.EventTypeMask = [
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            ]
            let handler: @Sendable (NSEvent) -> Void = { [weak self] event in self?.handle(event) }
            var tokens: [MonitorToken] = []
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
                tokens.append(MonitorToken(value: global))
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
                handler(event)
                return event
            }) {
                tokens.append(MonitorToken(value: local))
            }
            return tokens
        }

        // stop() may have run while the monitors were being installed; then they must not stay.
        let keep = state.withLock { s in
            guard s.log != nil, s.generation == generation else { return false }
            s.monitors = tokens
            return true
        }
        if !keep { await Self.remove(tokens) }
    }

    public func stop() async {
        let (timer, tokens) = state.withLock { s -> (DispatchSourceTimer?, [MonitorToken]) in
            let result = (s.timer, s.monitors)
            s.log = nil
            s.timer = nil
            s.monitors = []
            s.lastPosition = nil
            return result
        }
        timer?.cancel()
        await Self.remove(tokens)
    }

    /// Appends a `.cursor` event when the position differs from the last one recorded. Holding the
    /// lock across the append guarantees nothing is appended once `stop()` has cleared the log.
    private func sample() {
        let position = location()
        let time = clock()
        state.withLock { s in
            guard let log = s.log, s.lastPosition != position else { return }
            s.lastPosition = position
            log.append(InputEvent(t: time, kind: .cursor(x: Double(position.x), y: Double(position.y))))
        }
    }

    private func handle(_ event: NSEvent) {
        guard let position = event.cgEvent?.location,
              let input = Self.inputEvent(
                type: event.type, buttonNumber: event.buttonNumber,
                location: position, timestamp: event.timestamp)
        else { return }
        state.withLock { s in s.log?.append(input) }
    }

    private static func remove(_ tokens: [MonitorToken]) async {
        guard !tokens.isEmpty else { return }
        await MainActor.run {
            for token in tokens { NSEvent.removeMonitor(token.value) }
        }
    }

    /// The log entry for a mouse-button event, or nil for any other event type.
    static func inputEvent(
        type: NSEvent.EventType, buttonNumber: Int, location: CGPoint, timestamp: TimeInterval
    ) -> InputEvent? {
        let button: MouseButton
        let isDown: Bool
        switch type {
        case .leftMouseDown: (button, isDown) = (.left, true)
        case .leftMouseUp: (button, isDown) = (.left, false)
        case .rightMouseDown: (button, isDown) = (.right, true)
        case .rightMouseUp: (button, isDown) = (.right, false)
        case .otherMouseDown: (button, isDown) = (.other, true)
        case .otherMouseUp: (button, isDown) = (.other, false)
        default: return nil
        }
        let x = Double(location.x), y = Double(location.y)
        return InputEvent(
            t: HostTime(eventTimestamp: timestamp),
            kind: isDown ? .mouseDown(button, x: x, y: y) : .mouseUp(button, x: x, y: y))
    }
}
