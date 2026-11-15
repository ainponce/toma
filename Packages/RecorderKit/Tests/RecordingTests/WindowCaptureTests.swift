// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

@testable import Recording

/// The sizing of a window's stream, its geometry and visibility, the displays' geometry and the composite recorder.
/// No ScreenCaptureKit: what needs a real window is in `CaptureIntegrationTests`.
@Suite struct WindowCaptureTests {
    // MARK: - Sizing

    @Test func windowSizingAsksForNewSizeAfterResize() {
        // The window grew to 900×600 pt with the configuration at 1600×1000: ScreenCaptureKit delivers it shrunk
        // (750×500, contentScale 5/6).
        #expect(WindowStreamSizing.resize(
            configured: CGSize(width: 1600, height: 1000), contentRect: CGRect(x: 0, y: 0, width: 750, height: 500),
            contentScale: 5.0 / 6.0, scaleFactor: 2) == CGSize(width: 1800, height: 1200))
        #expect(WindowStreamSizing.resize(
            configured: CGSize(width: 1800, height: 1200), contentRect: CGRect(x: 0, y: 0, width: 900.4, height: 600),
            contentScale: 1, scaleFactor: 2) == nil)
    }

    @Test func windowSizingRoundsToEvenPixelsAndFollowsAShrink() {
        #expect(WindowStreamSizing.pixelSize(
            contentRect: CGRect(x: 0, y: 0, width: 333.3, height: 201), contentScale: 1, scaleFactor: 1)
            == CGSize(width: 334, height: 202))
        // A smaller window comes at full scale in a corner of the old size.
        #expect(WindowStreamSizing.resize(
            configured: CGSize(width: 1800, height: 1200), contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            contentScale: 1, scaleFactor: 2) == CGSize(width: 1200, height: 800))
        // No content, or no scale: nothing to ask for.
        #expect(WindowStreamSizing.resize(
            configured: CGSize(width: 1800, height: 1200), contentRect: .zero, contentScale: 1, scaleFactor: 2) == nil)
        #expect(WindowStreamSizing.resize(
            configured: CGSize(width: 1800, height: 1200), contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            contentScale: 0, scaleFactor: 2) == nil)
    }

    @Test func resizesAtMostEveryQuarterSecond() {
        let geometry = StreamFrameGeometry(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), contentScale: 1, scaleFactor: 2)
        func resize(_ side: Double) -> StreamResize { StreamResize(size: CGSize(width: side, height: side), geometry: geometry) }
        let start = HostTime(nanoseconds: 10_000_000_000)
        var throttle = StreamResizeThrottle(configured: CGSize(width: 100, height: 100))

        #expect(throttle.request(resize(200), now: start) == .apply(resize(200)))
        throttle.applied(CGSize(width: 200, height: 200), at: start)
        #expect(throttle.configured == CGSize(width: 200, height: 200))
        // 100 ms later: one retry, for the rest of the interval; a newer size replaces the one waiting.
        #expect(throttle.request(resize(300), now: start.adding(seconds: 0.1)) == .retry(after: .milliseconds(150)))
        #expect(throttle.request(resize(400), now: start.adding(seconds: 0.2)) == .none)
        #expect(throttle.retryFired(now: start.adding(seconds: 0.25)) == .apply(resize(400)))
        throttle.applied(CGSize(width: 400, height: 400), at: start.adding(seconds: 0.25))

        // A frame that wants no new size drops the one waiting.
        #expect(throttle.request(resize(500), now: start.adding(seconds: 0.3)) == .retry(after: .milliseconds(200)))
        #expect(throttle.request(nil, now: start.adding(seconds: 0.35)) == .none)
        #expect(throttle.retryFired(now: start.adding(seconds: 0.5)) == .none)

        // A frame that applies before the retry fires leaves it nothing, and a retry that fires early waits again.
        #expect(throttle.request(resize(600), now: start.adding(seconds: 0.6)) == .apply(resize(600)))
        throttle.applied(CGSize(width: 600, height: 600), at: start.adding(seconds: 0.6))
        #expect(throttle.request(resize(700), now: start.adding(seconds: 0.7)) == .retry(after: .milliseconds(150)))
        #expect(throttle.request(resize(800), now: start.adding(seconds: 0.9)) == .apply(resize(800)))
        throttle.applied(CGSize(width: 800, height: 800), at: start.adding(seconds: 0.9))
        #expect(throttle.request(resize(900), now: start.adding(seconds: 0.95)) == .none)
        #expect(throttle.retryFired(now: start.adding(seconds: 1.0)) == .retry(after: .milliseconds(150)))
        #expect(throttle.retryFired(now: start.adding(seconds: 1.15)) == .apply(resize(900)))

        // A size the stream refused goes back to the one before, so a later frame asks again.
        throttle.applied(CGSize(width: 900, height: 900), at: start.adding(seconds: 1.15))
        throttle.refused(CGSize(width: 900, height: 900), previous: CGSize(width: 800, height: 800))
        #expect(throttle.configured == CGSize(width: 800, height: 800))
        // Only while it is still the configured one.
        throttle.applied(CGSize(width: 1000, height: 1000), at: start.adding(seconds: 2))
        throttle.refused(CGSize(width: 900, height: 900), previous: CGSize(width: 800, height: 800))
        #expect(throttle.configured == CGSize(width: 1000, height: 1000))
    }

    @Test func streamStopsOnceAndNeverBeforeItStarted() {
        /// What each call says, in order: `true` where the stream must be stopped.
        func stops(_ calls: [(inout StreamStopPhase) -> Bool]) -> (stops: [Bool], phase: StreamStopPhase.Phase) {
            var phase = StreamStopPhase()
            let stops = calls.map { $0(&phase) }
            return (stops, phase.phase)
        }
        let didStart: (inout StreamStopPhase) -> Bool = { $0.didStart() }
        let end: (inout StreamStopPhase) -> Bool = { $0.end() }
        let streamEnded: (inout StreamStopPhase) -> Bool = { phase in
            phase.streamEnded()
            return false
        }

        // Ended while starting: its start stops it once started, and only then.
        #expect(stops([end, didStart, end]) == ([false, true, false], .ended))
        // Ended while capturing: at once, and only once.
        #expect(stops([didStart, end, end]) == ([false, true, false], .ended))
        #expect(stops([didStart]) == ([false], .capturing))
        // Stopped by its own error, or never started: nothing to stop.
        #expect(stops([didStart, streamEnded, end]) == ([false, false, false], .ended))
        #expect(stops([end, streamEnded, didStart]) == ([false, false, false], .ended))
    }

    // MARK: - Visibility

    @Test func visibilityIsOtherSpaceWhileFramesKeepComing() {
        #expect(WindowVisibility.verdict(onScreen: false, secondsSinceCompleteFrame: 0.3) == .otherSpace)
    }

    @Test func visibilityIsHiddenAfterOneSecondWithoutFrames() {
        #expect(WindowVisibility.verdict(onScreen: false, secondsSinceCompleteFrame: 1.0) == .hidden)
        #expect(WindowVisibility.verdict(onScreen: false, secondsSinceCompleteFrame: nil) == .hidden)
        #expect(WindowVisibility.verdict(onScreen: true, secondsSinceCompleteFrame: 5) == .visible)
        #expect(WindowVisibility.verdict(onScreen: true, secondsSinceCompleteFrame: nil) == .visible)
    }

    // MARK: - Window geometry

    @Test func windowGeometryRecorderLogsChangesOnly() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("events.jsonl")
            let log = try EventLogWriter(url: url)
            let start = Rect(x: 100, y: 80, width: 800, height: 600)
            let moved = Rect(x: 150, y: 90, width: 800, height: 600)
            let window = ScriptedWindow([
                WindowState(frame: start, onScreen: true), WindowState(frame: start, onScreen: true),
                WindowState(frame: start, onScreen: true), WindowState(frame: moved, onScreen: true),
                WindowState(frame: moved, onScreen: true), WindowState(frame: moved, onScreen: false),
            ])
            let visibility = Mutex<[WindowVisibility]>([])
            let recorder = WindowGeometryRecorder(
                trackID: "window-42", windowID: 42, query: { window.next(for: $0) }, lastCompleteFrame: { nil },
                onVisibilityChange: { change in visibility.withLock { $0.append(change) } })
            await recorder.start(log: log)
            #expect(await eventually { window.calls >= 8 })
            await recorder.stop()
            try log.close()

            #expect(try EventLogReader.read(url).events.map(\.kind) == [
                .windowGeometry(track: "window-42", frame: start, onScreen: true),
                .windowGeometry(track: "window-42", frame: moved, onScreen: true),
                .windowGeometry(track: "window-42", frame: moved, onScreen: false),
            ])
            // Off screen and no frames: hidden, once. It starts out visible, as the take's first event says.
            #expect(visibility.withLock { $0 } == [.hidden])
            #expect(window.windowIDs == [42])
        }
    }

    @Test func windowGeometryRecorderSaysOtherSpaceWhileFramesArrive() async throws {
        try await withTemporaryDirectory { dir in
            let log = try EventLogWriter(url: dir.appendingPathComponent("events.jsonl"))
            let window = ScriptedWindow([WindowState(frame: Rect(x: 0, y: 0, width: 10, height: 10), onScreen: false)])
            let visibility = Mutex<[WindowVisibility]>([])
            let recorder = WindowGeometryRecorder(
                trackID: "window-42", windowID: 42, query: { window.next(for: $0) },
                lastCompleteFrame: { HostTime.now().adding(seconds: -0.3) },
                onVisibilityChange: { change in visibility.withLock { $0.append(change) } })
            await recorder.start(log: log)
            #expect(await eventually { window.calls >= 3 })
            await recorder.stop()
            try log.close()
            #expect(visibility.withLock { $0 } == [.otherSpace])
        }
    }

    @Test func windowThatIsGoneLogsNothing() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("events.jsonl")
            let log = try EventLogWriter(url: url)
            let window = ScriptedWindow([nil])
            let visibility = Mutex<[WindowVisibility]>([])
            let recorder = WindowGeometryRecorder(
                trackID: "window-42", windowID: 42, query: { window.next(for: $0) },
                onVisibilityChange: { change in visibility.withLock { $0.append(change) } })
            await recorder.start(log: log)
            #expect(await eventually { window.calls >= 3 })
            await recorder.stop()
            try log.close()
            #expect(try EventLogReader.read(url).events.isEmpty)
            #expect(visibility.withLock { $0 }.isEmpty)
        }
    }

    @Test func windowGeometryRecorderIsQuietWhilePaused() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("events.jsonl")
            let log = try EventLogWriter(url: url)
            let first = Rect(x: 100, y: 80, width: 800, height: 600)
            let second = Rect(x: 200, y: 80, width: 640, height: 480)
            let window = ScriptedWindow([WindowState(frame: first, onScreen: true)])
            let recorder = WindowGeometryRecorder(trackID: "window-42", windowID: 42, query: { window.next(for: $0) })
            await recorder.start(log: log)
            // The first sample has written its event (a sample still in flight when the pause comes writes nothing).
            #expect(await eventually {
                try? log.flush()
                return (try? EventLogReader.read(url).events.count) == 1
            })
            await recorder.pause()
            await recorder.pause()  // idempotent
            let callsAtPause = window.calls
            window.set(WindowState(frame: second, onScreen: false))
            try await Task.sleep(for: .milliseconds(300))
            try log.flush()
            // Nothing sampled, nothing written.
            #expect(window.calls == callsAtPause)
            #expect(try EventLogReader.read(url).events.count == 1)

            let resumed = HostTime.now()
            await recorder.resume()
            await recorder.resume()  // idempotent: one timer, not two
            #expect(await eventually { window.calls >= callsAtPause + 2 })
            await recorder.stop()
            try log.close()
            let events = try EventLogReader.read(url).events
            #expect(events.map(\.kind) == [
                .windowGeometry(track: "window-42", frame: first, onScreen: true),
                .windowGeometry(track: "window-42", frame: second, onScreen: false),
            ])
            #expect(events[1].t >= resumed)
        }
    }

    // MARK: - Display geometry

    @Test func displayGeometryRecorderLogsChangesOnly() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("events.jsonl")
            let log = try EventLogWriter(url: url)
            let main = Rect(x: 0, y: 0, width: 1512, height: 982)
            let side = Rect(x: 1512, y: 0, width: 1920, height: 1080)
            let displays = FakeDisplays([1: (main, 2), 2: (side, 2)])
            let recorder = DisplayGeometryRecorder(displayIDs: [1, 2], query: { displays.geometry(of: $0) })
            await recorder.start(log: log)

            displays.set(2, to: (side, 1))
            recorder.reconfigured()
            recorder.reconfigured()
            try log.flush()
            #expect(try EventLogReader.read(url).events.map(\.kind) == [.displayGeometry(displayID: 2, frame: side, scale: 1)])

            // Nothing while paused; what changed is written when the take resumes.
            await recorder.pause()
            let moved = Rect(x: 0, y: 0, width: 1728, height: 1117)
            displays.set(1, to: (moved, 2))
            recorder.reconfigured()
            try log.flush()
            #expect(try EventLogReader.read(url).events.count == 1)
            await recorder.resume()
            recorder.reconfigured()

            // A display that is gone writes nothing; nor does anything once stopped.
            displays.set(2, to: nil)
            recorder.reconfigured()
            await recorder.stop()
            displays.set(1, to: (main, 2))
            recorder.reconfigured()
            try log.close()
            #expect(try EventLogReader.read(url).events.map(\.kind) == [
                .displayGeometry(displayID: 2, frame: side, scale: 1),
                .displayGeometry(displayID: 1, frame: moved, scale: 2),
            ])
        }
    }

    // MARK: - Composite

    @Test func compositeRecorderStartsPausesAndStopsAll() async throws {
        try await withTemporaryDirectory { dir in
            let log = try EventLogWriter(url: dir.appendingPathComponent("events.jsonl"))
            let calls = CallLog()
            let composite = CompositeInputRecorder([CallRecorder(name: "a", calls: calls), CallRecorder(name: "b", calls: calls)])
            await composite.start(log: log)
            await composite.pause()
            await composite.resume()
            await composite.stop()
            try log.close()
            #expect(calls.all == [
                "a.start", "b.start", "a.pause", "b.pause", "a.resume", "b.resume", "a.stop", "b.stop",
            ])
        }
    }
}

/// A window whose state the test scripts: each query returns the next state of the script, then the last one (or
/// the one `set` gives) on every later query.
private final class ScriptedWindow: Sendable {
    private struct State {
        var script: [WindowState?]
        var calls = 0
        var windowIDs: Set<CGWindowID> = []
    }

    private let state: Mutex<State>

    init(_ script: [WindowState?]) {
        state = Mutex(State(script: script))
    }

    /// How many times the recorder queried the window.
    var calls: Int { state.withLock { $0.calls } }
    /// The window IDs the recorder asked about.
    var windowIDs: Set<CGWindowID> { state.withLock { $0.windowIDs } }

    func set(_ next: WindowState?) {
        state.withLock { $0.script = [next] }
    }

    func next(for windowID: CGWindowID) -> WindowState? {
        state.withLock { state in
            state.calls += 1
            state.windowIDs.insert(windowID)
            return state.script.count > 1 ? state.script.removeFirst() : state.script.first ?? nil
        }
    }
}

/// Displays whose geometry the test sets.
private final class FakeDisplays: Sendable {
    private let displays: Mutex<[UInt32: (frame: Rect, scale: Double)]>

    init(_ displays: [UInt32: (frame: Rect, scale: Double)]) {
        self.displays = Mutex(displays)
    }

    func set(_ displayID: UInt32, to geometry: (frame: Rect, scale: Double)?) {
        displays.withLock { $0[displayID] = geometry }
    }

    func geometry(of displayID: UInt32) -> (frame: Rect, scale: Double)? {
        displays.withLock { $0[displayID] }
    }
}

/// The calls of the `CallRecorder`s that share it, in order.
private final class CallLog: Sendable {
    private let calls = Mutex<[String]>([])

    var all: [String] { calls.withLock { $0 } }

    func append(_ call: String) {
        calls.withLock { $0.append(call) }
    }
}

/// Writes down each call as "<name>.<call>".
private final class CallRecorder: InputRecorder {
    private let name: String
    private let calls: CallLog

    init(name: String, calls: CallLog) {
        self.name = name
        self.calls = calls
    }

    func start(log: EventLogWriter) async { calls.append("\(name).start") }
    func pause() async { calls.append("\(name).pause") }
    func resume() async { calls.append("\(name).resume") }
    func stop() async { calls.append("\(name).stop") }
}
