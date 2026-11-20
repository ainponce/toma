// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import ProjectFormat
import Recording
import Synchronization

/// One reading of a `ScriptedFocusSource`'s script: `reading`, given `seconds` into it.
public struct ScriptedFocus: Sendable {
    public var seconds: Double
    public var reading: FocusReading

    public init(seconds: Double, reading: FocusReading) {
        self.seconds = seconds
        self.reading = reading
    }
}

/// A focus that moves as `script` says, for tests and `synth-record --focus`. It checks the script every 50 ms while
/// started and gives each reading once its seconds have gone by, counting only the time started: a stop keeps its place
/// and the next start goes on from there. Each start gives at once what is due by then, or else the last reading given
/// again (the state). Each reading's time is `HostTime.now()` when it is given, on its own queue. Needs no permission.
public final class ScriptedFocusSource: FocusSource {
    /// How often the script is checked.
    static let interval: Duration = .milliseconds(50)

    private struct State {
        var timer: (any RecordingTimer)?
        var handler: (@Sendable (FocusReading, HostTime) -> Void)?
        /// The checks done while started: `interval` each.
        var checks = 0
        /// The next reading of the script to give.
        var next = 0
        var last: FocusReading?
    }

    private let script: [ScriptedFocus]
    private let ticks: RecordingTicks
    private let queue = DispatchSerialQueue(label: "dev.toma.scripted-focus", qos: .userInteractive)
    private let state = Mutex(State())

    public init(script: [ScriptedFocus], ticks: RecordingTicks) {
        self.script = script.enumerated().sorted { ($0.element.seconds, $0.offset) < ($1.element.seconds, $1.offset) }
            .map(\.element)
        self.ticks = ticks
    }

    public func start(handler: @escaping @Sendable (FocusReading, HostTime) -> Void) -> Bool {
        let timer = ticks.every(Self.interval, queue) { [weak self] in self?.check() }
        let previous = state.withLock { s -> (any RecordingTimer)? in
            defer { (s.timer, s.handler) = (timer, handler) }
            return s.timer
        }
        previous?.cancel()
        queue.async { [weak self] in self?.giveState() }
        return true
    }

    public func stop() {
        let timer = state.withLock { s -> (any RecordingTimer)? in
            defer { (s.timer, s.handler) = (nil, nil) }
            return s.timer
        }
        timer?.cancel()
    }

    /// On the queue, after a start: what is due, or else the last reading given.
    private func giveState() {
        let (readings, handler) = state.withLock { s -> ([FocusReading], (@Sendable (FocusReading, HostTime) -> Void)?) in
            guard let handler = s.handler else { return ([], nil) }
            let due = takeDue(&s)
            return (due.isEmpty ? s.last.map { [$0] } ?? [] : due, handler)
        }
        if let handler { for reading in readings { handler(reading, HostTime.now()) } }
    }

    /// On the queue, every interval while started.
    private func check() {
        let (readings, handler) = state.withLock { s -> ([FocusReading], (@Sendable (FocusReading, HostTime) -> Void)?) in
            guard let handler = s.handler else { return ([], nil) }
            s.checks += 1
            return (takeDue(&s), handler)
        }
        if let handler { for reading in readings { handler(reading, HostTime.now()) } }
    }

    /// The readings of the script due by the checks done, which are given now.
    private func takeDue(_ s: inout State) -> [FocusReading] {
        var due: [FocusReading] = []
        while s.next < script.count, Self.check(at: script[s.next].seconds) <= s.checks {
            due.append(script[s.next].reading)
            s.next += 1
        }
        if let last = due.last { s.last = last }
        return due
    }

    /// The check by which a reading `seconds` into the script is due.
    static func check(at seconds: Double) -> Int {
        max(0, Int((seconds * 20 - 1e-6).rounded(.up)))
    }
}

/// The keyboard's focus of `synth-record --focus`, the same in every take: an `AccessibilityFocusRecorder` that reads a
/// `ScriptedFocusSource` of `script` and sees no secure input. Its screen is that of `synth-record`, 640 × 360 at the
/// origin, with the clicks of `SyntheticInputRecorder` (0.5 s and every second after) and its key activity from 3 to 4 s.
/// Needs no permission.
public final class SyntheticFocusRecorder: InputRecorder, Sendable {
    /// From the start, in seconds:
    /// - 0: a field at (40, 40) of 240 × 24 with its text cursor at (44, 44), 16 high. The state, not a change;
    /// - 2.2: another field below it, at (40, 120), reached with the keyboard: 0.7 s after the click of 1.5 s, and still
    ///   until 3 s;
    /// - 3.0 to 3.4: the text cursor typing in it, at (44 + 8k, 124), one every 0.1 s;
    /// - 3.5 to 3.9: the same, a line far below, at (44 + 8k, 300): at 2× it leaves the view, so it gives two blocks.
    public static let script: [ScriptedFocus] = {
        let first = Rect(x: 40, y: 40, width: 240, height: 24)
        let second = Rect(x: 40, y: 120, width: 240, height: 24)
        var script = [
            ScriptedFocus(seconds: 0, reading: FocusReading(
                element: first, caret: Rect(x: 44, y: 44, width: 0, height: 16), isSecure: false)),
            ScriptedFocus(seconds: 2.2, reading: FocusReading(element: second, caret: nil, isSecure: false)),
        ]
        for (n, y) in [124.0, 300].enumerated() {
            for k in 0..<5 {
                let caret = Rect(x: 44 + 8 * Double(k), y: y, width: 0, height: 16)
                script.append(ScriptedFocus(
                    seconds: Double(30 + 5 * n + k) / 10, reading: FocusReading(element: second, caret: caret, isSecure: false)))
            }
        }
        return script
    }()

    private let recorder: AccessibilityFocusRecorder

    public init(ticks: RecordingTicks = .live) {
        recorder = AccessibilityFocusRecorder(source: ScriptedFocusSource(script: Self.script, ticks: ticks), secureInput: { false })
    }

    public func start(log: EventLogWriter) async {
        await recorder.start(log: log)
    }

    public func pause() async {
        await recorder.pause()
    }

    public func resume() async {
        await recorder.resume()
    }

    public func stop() async {
        await recorder.stop()
    }
}
