// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import Recording

// `ScrollRecorder` and `KeyActivityRecorder` on manual ticks and a clock the test sets: the scroll of each 1/30 s in one
// event, and the 250 ms windows with a key, never during secure input, a pause or a reading that cannot be used.

/// The host time `seconds` seconds after boot.
private func host(_ seconds: Double) -> HostTime {
    HostTime(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
}

/// A clock that is wherever the test last set it.
private final class TestClock: Sendable {
    private let time: Mutex<HostTime>

    init(_ seconds: Double) {
        time = Mutex(host(seconds))
    }

    var now: HostTime { time.withLock { $0 } }

    func set(_ seconds: Double) {
        time.withLock { $0 = host(seconds) }
    }
}

/// Stops `recorder`, closes `log` and returns what was logged, in file order.
private func stopAndRead(_ recorder: any InputRecorder, _ log: EventLogWriter) async throws -> [InputEvent] {
    await recorder.stop()
    try log.close()
    return try EventLogReader.read(log.url).events
}

// MARK: - Scroll

/// Scroll events the test sends, as the global monitor would.
private final class FakeScrollEvents: ScrollEventSource {
    private let handler = Mutex<(@Sendable (Double, Double, Bool) -> Void)?>(nil)

    @MainActor func start(_ handler: @escaping @Sendable (_ dx: Double, _ dy: Double, _ precise: Bool) -> Void) {
        self.handler.withLock { $0 = handler }
    }

    @MainActor func stop() {
        handler.withLock { $0 = nil }
    }

    var isStarted: Bool { handler.withLock { $0 != nil } }

    /// One scroll event; nothing if the recorder is not listening.
    func send(_ dx: Double, _ dy: Double, precise: Bool = true) {
        handler.withLock { $0 }?(dx, dy, precise)
    }
}

/// Where the pointer is, and how many times it was asked.
private final class FakePointer: Sendable {
    private let point = Mutex(CGPoint(x: 1, y: 2))
    private let readCount = Mutex(0)

    var now: CGPoint {
        readCount.withLock { $0 += 1 }
        return point.withLock { $0 }
    }

    var reads: Int { readCount.withLock { $0 } }

    func set(_ x: Double, _ y: Double) {
        point.withLock { $0 = CGPoint(x: x, y: y) }
    }
}

private struct ScrollRig {
    let log: EventLogWriter
    let events = FakeScrollEvents()
    let clock = TestClock(10)
    let pointer = FakePointer()
    let ticks = ManualTicks()
    let recorder: ScrollRecorder

    init(in dir: URL) throws {
        log = try EventLogWriter(url: dir.appendingPathComponent("scroll.jsonl"))
        let (clock, pointer) = (clock, pointer)
        recorder = ScrollRecorder(events: events, clock: { clock.now }, location: { pointer.now }, ticks: ticks.ticks)
    }

    /// At `seconds`, the interval ends.
    func tick(at seconds: Double) async {
        clock.set(seconds)
        await ticks.fire(every: ScrollRecorder.interval)
    }
}

@Test func scrollIsSummedPerThirtiethOfASecond() async throws {
    try await withTemporaryDirectory { dir in
        let rig = try ScrollRig(in: dir)
        await rig.recorder.start(log: rig.log)
        #expect(rig.events.isStarted)
        rig.events.send(0, -10)
        rig.events.send(0, -20)
        rig.pointer.set(100, 200)
        rig.events.send(0, -12.5)
        rig.pointer.set(640.5, 402)
        await rig.tick(at: 10.5)
        await rig.tick(at: 10.6)  // nothing since: no event
        rig.events.send(3, 0)
        rig.events.send(0, 0)  // no movement: not a scroll
        rig.events.send(.nan, -1)  // not a number: dropped
        await rig.tick(at: 10.7)
        let events = try await stopAndRead(rig.recorder, rig.log)
        #expect(!rig.events.isStarted)
        // Asked only for the two events: not on a tick, nor at the stop, with nothing to write.
        #expect(rig.pointer.reads == 2)

        #expect(events == [
            InputEvent(t: host(10.5), kind: .scroll(dx: 0, dy: -42.5, x: 640.5, y: 402)),
            InputEvent(t: host(10.7), kind: .scroll(dx: 3, dy: 0, x: 640.5, y: 402)),
        ])
        let line = try #require(try String(contentsOf: rig.log.url, encoding: .utf8).split(separator: "\n").first)
        #expect(line == #"{"dx":0,"dy":-42.5,"t":10500000000,"type":"scroll","x":640.5,"y":402}"#)
    }
}

@Test func lineScrollIsTenPointsPerLine() async throws {
    try await withTemporaryDirectory { dir in
        let rig = try ScrollRig(in: dir)
        await rig.recorder.start(log: rig.log)
        for _ in 0..<3 { rig.events.send(0, -1, precise: false) }
        await rig.tick(at: 10.5)
        rig.events.send(0.5, 0, precise: false)
        rig.events.send(2, 0, precise: true)
        await rig.tick(at: 10.6)
        let events = try await stopAndRead(rig.recorder, rig.log)

        #expect(ScrollRecorder.pointsPerLine == 10)
        #expect(events.map(\.kind) == [.scroll(dx: 0, dy: -30, x: 1, y: 2), .scroll(dx: 7, dy: 0, x: 1, y: 2)])
    }
}

// MARK: - Key activity

/// What macOS says about the keyboard, the mouse and secure input, read against `clock`, and how often the recorder
/// asked each thing.
private final class FakeInput: Sendable {
    private struct State {
        var keyAt: HostTime?
        var mouseAt: HostTime?
        /// Read instead of the time since `keyAt`.
        var keyReading: Double?
        /// The `.keyDown` reading is the `.mouseMoved` one plus this: a source that follows the mouse.
        var keyFollowsMouse: Double?
        var secure = false
        var keyReads = 0
        var listenAccessCalls = 0
    }

    private let clock: TestClock
    private let state = Mutex(State())

    init(clock: TestClock) {
        self.clock = clock
    }

    /// A key was pressed `secondsAgo` before the clock's time now.
    func press(secondsAgo: Double = 0.01) {
        let at = clock.now.adding(seconds: -secondsAgo)
        state.withLock { $0.keyAt = at }
    }

    /// The mouse moved `secondsAgo` before the clock's time now.
    func moveMouse(secondsAgo: Double = 0.005) {
        let at = clock.now.adding(seconds: -secondsAgo)
        state.withLock { $0.mouseAt = at }
    }

    func setKeyReading(_ seconds: Double?) {
        state.withLock { $0.keyReading = seconds }
    }

    func setKeyFollowsMouse(_ offset: Double?) {
        state.withLock { $0.keyFollowsMouse = offset }
    }

    func setSecure(_ secure: Bool) {
        state.withLock { $0.secure = secure }
    }

    var keyReads: Int { state.withLock { $0.keyReads } }
    var listenAccessCalls: Int { state.withLock { $0.listenAccessCalls } }

    func secondsSinceLastKey() -> Double {
        let now = clock.now
        return state.withLock { s in
            s.keyReads += 1
            if let offset = s.keyFollowsMouse { return Self.seconds(since: s.mouseAt, now) + offset }
            return s.keyReading ?? Self.seconds(since: s.keyAt, now)
        }
    }

    func secondsSinceLastMouseMove() -> Double {
        let now = clock.now
        return state.withLock { Self.seconds(since: $0.mouseAt, now) }
    }

    func secureInput() -> Bool {
        state.withLock { $0.secure }
    }

    func listenAccess() -> Bool {
        state.withLock { s in
            s.listenAccessCalls += 1
            return true
        }
    }

    /// Since boot, as macOS says when nothing happened since.
    private static func seconds(since time: HostTime?, _ now: HostTime) -> Double {
        time.map { now.seconds(since: $0) } ?? now.seconds(since: HostTime(nanoseconds: 0))
    }
}

private struct KeyRig {
    let log: EventLogWriter
    let clock: TestClock
    let input: FakeInput
    let ticks = ManualTicks()
    let recorder: KeyActivityRecorder

    /// The take starts at `start` seconds.
    init(in dir: URL, start: Double = 1) throws {
        log = try EventLogWriter(url: dir.appendingPathComponent("keys.jsonl"))
        let clock = TestClock(start)
        let input = FakeInput(clock: clock)
        (self.clock, self.input) = (clock, input)
        recorder = KeyActivityRecorder(
            secondsSinceLastKey: { input.secondsSinceLastKey() }, secondsSinceLastMouseMove: { input.secondsSinceLastMouseMove() },
            secureInput: { input.secureInput() }, listenAccess: { input.listenAccess() }, clock: { clock.now },
            ticks: ticks.ticks)
    }

    /// The recorder asks at `seconds`.
    func poll(at seconds: Double) async {
        clock.set(seconds)
        await ticks.fire(every: KeyActivityRecorder.interval)
    }

    /// At `seconds`, a key pressed 10 ms before, then the recorder asks.
    func key(at seconds: Double) async {
        clock.set(seconds)
        input.press()
        await ticks.fire(every: KeyActivityRecorder.interval)
    }

    /// At `seconds`, the mouse moving and `.keyDown` read 1 ms after `.mouseMoved`, then the recorder asks.
    func echo(at seconds: Double) async {
        clock.set(seconds)
        input.moveMouse()
        input.setKeyFollowsMouse(0.001)
        await ticks.fire(every: KeyActivityRecorder.interval)
        input.setKeyFollowsMouse(nil)
    }

    /// At `seconds`, the mouse moving and a `.keyDown` reading of its own (no key since boot), then the recorder asks.
    func mouseOnly(at seconds: Double) async {
        clock.set(seconds)
        input.moveMouse()
        await ticks.fire(every: KeyActivityRecorder.interval)
    }

    /// Stops the recorder and returns the times of its `keyActivity` lines; any other event fails.
    func finish() async throws -> [HostTime] {
        try await stopAndRead(recorder, log).map { event in
            #expect(event.kind == .keyActivity)
            return event.t
        }
    }
}

@Test func keyActivityMarksTheQuarterSecondWindow() async throws {
    #expect(KeyActivityRecorder.window == 250_000_000)
    #expect(KeyActivityRecorder.windowStart(of: host(1.37)) == host(1.25))
    #expect(KeyActivityRecorder.windowStart(of: host(1.5)) == host(1.5))
    #expect(KeyActivityRecorder.windowStart(of: HostTime(nanoseconds: 1_499_999_999)) == host(1.25))
    #expect(KeyActivityRecorder.isUsable(0) && KeyActivityRecorder.isUsable(12.5))
    #expect(!KeyActivityRecorder.isUsable(-0.001) && !KeyActivityRecorder.isUsable(.nan) && !KeyActivityRecorder.isUsable(.infinity))

    try await withTemporaryDirectory { dir in
        let rig = try KeyRig(in: dir)
        await rig.recorder.start(log: rig.log)
        await rig.poll(at: 1.1)  // no key since the start
        await rig.key(at: 1.38)  // pressed at 1.37
        await rig.poll(at: 1.41)  // the same key: nothing new
        await rig.key(at: 1.46)  // another one in the same window: no second line
        await rig.poll(at: 2.0)
        // At 2.25 and at 2.5: two windows.
        await rig.key(at: 2.26)
        await rig.key(at: 2.51)
        let lines = try await rig.finish()
        #expect(lines == [host(1.25), host(2.25), host(2.5)])
        let line = try #require(try String(contentsOf: rig.log.url, encoding: .utf8).split(separator: "\n").first)
        #expect(line == #"{"t":1250000000,"type":"keyActivity"}"#)
    }
}

@Test func nothingWithSecureInput() async throws {
    try await withTemporaryDirectory { dir in
        let rig = try KeyRig(in: dir)
        await rig.recorder.start(log: rig.log)
        // Polls 1 to 8, each with a key in its own window: 1.25, 1.5, … 3.0.
        for poll in 1...8 {
            rig.input.setSecure(poll == 5)
            await rig.key(at: 1.0 + 0.25 * Double(poll) + 0.02)
        }
        let lines = try await rig.finish()
        // Poll 5 read secure input, and poll 6 came right after it (the Enter that closes a password field).
        #expect(lines == [1, 2, 3, 4, 7, 8].map { host(1.0 + 0.25 * Double($0)) })
    }
}

@Test func scrollAndKeysStopWhilePaused() async throws {
    try await withTemporaryDirectory { dir in
        let scroll = try ScrollRig(in: dir)
        await scroll.recorder.start(log: scroll.log)
        scroll.events.send(0, -5)
        await scroll.tick(at: 10.1)
        scroll.events.send(0, -7)
        scroll.clock.set(10.12)
        await scroll.recorder.pause()  // the scroll before the pause is logged at once
        await scroll.recorder.pause()
        #expect(scroll.ticks.timers(every: ScrollRecorder.interval) == 0)
        scroll.events.send(0, -100)
        await scroll.tick(at: 10.2)
        await scroll.recorder.resume()
        await scroll.recorder.resume()
        #expect(scroll.ticks.timers(every: ScrollRecorder.interval) == 1)
        await scroll.tick(at: 10.3)
        scroll.events.send(0, -1)
        await scroll.tick(at: 10.4)
        let scrolls = try await stopAndRead(scroll.recorder, scroll.log)
        #expect(scrolls == [
            InputEvent(t: host(10.1), kind: .scroll(dx: 0, dy: -5, x: 1, y: 2)),
            InputEvent(t: host(10.12), kind: .scroll(dx: 0, dy: -7, x: 1, y: 2)),
            InputEvent(t: host(10.4), kind: .scroll(dx: 0, dy: -1, x: 1, y: 2)),
        ])

        let keys = try KeyRig(in: dir)
        await keys.recorder.start(log: keys.log)
        await keys.key(at: 1.3)
        await keys.recorder.pause()
        await keys.recorder.pause()
        #expect(keys.ticks.timers(every: KeyActivityRecorder.interval) == 0)
        await keys.key(at: 1.8)  // no poll while paused
        #expect(keys.input.keyReads == 1)
        keys.clock.set(2.0)
        keys.input.press()
        await keys.recorder.resume()  // that key was pressed during the pause
        await keys.recorder.resume()
        #expect(keys.ticks.timers(every: KeyActivityRecorder.interval) == 1)
        await keys.poll(at: 2.1)
        #expect(keys.input.keyReads == 2)  // one poll, one reading
        // A key at 2.29 whose window starts at 2.25, after the resume.
        await keys.key(at: 2.3)
        #expect(try await keys.finish() == [host(1.25), host(2.25)])
    }
}

@Test func keyWindowThatStartedBeforeTheTakeIsLeftOut() async throws {
    try await withTemporaryDirectory { dir in
        // The take starts at 1.1, in the window of 1.0: a key at 1.15 falls in a window the take did not record whole.
        let rig = try KeyRig(in: dir, start: 1.1)
        await rig.recorder.start(log: rig.log)
        await rig.key(at: 1.16)
        await rig.key(at: 1.27)
        #expect(try await rig.finish() == [host(1.25)])
    }
}

@Test func unusableReadingsWriteNothing() async throws {
    try await withTemporaryDirectory { dir in
        let rig = try KeyRig(in: dir)
        await rig.recorder.start(log: rig.log)
        for (i, reading) in [Double.nan, -1, .infinity, -.infinity].enumerated() {
            rig.input.setKeyReading(reading)
            await rig.poll(at: 1.3 + 0.25 * Double(i))
        }
        // The recorder goes on: a reading it can use later is logged.
        rig.input.setKeyReading(nil)
        await rig.key(at: 2.4)
        #expect(try await rig.finish() == [host(2.25)])
    }
}

@Test func readingLongerThanTheHostClockIsNoKey() async throws {
    try await withTemporaryDirectory { dir in
        let rig = try KeyRig(in: dir)
        await rig.recorder.start(log: rig.log)
        // Finite and not negative, so usable, but longer than the host clock can count (2⁶⁴ ns and more): a key long
        // before the previous reading, not one to convert to a host time.
        for (i, reading) in [18_446_744_073.709_553, 1e300, .greatestFiniteMagnitude].enumerated() {
            rig.input.setKeyReading(reading)
            await rig.poll(at: 1.3 + 0.25 * Double(i))
        }
        rig.input.setKeyReading(nil)
        await rig.key(at: 2.4)
        #expect(try await rig.finish() == [host(2.25)])
    }
}

@Test func readingThatFollowsTheMouseTurnsItselfOff() async throws {
    try await withTemporaryDirectory { dir in
        let rig = try KeyRig(in: dir)
        // Each poll a quarter of a second after the one before, so each key falls in a window of its own.
        var time = 1.0
        func echo() async {
            time += 0.25
            await rig.echo(at: time)
        }
        func mouseOnly() async {
            time += 0.25
            await rig.mouseOnly(at: time)
        }
        func key() async {
            time += 0.25
            await rig.key(at: time)
        }

        #expect(KeyActivityRecorder.mouseEchoPolls == 10 && KeyActivityRecorder.mouseEchoTolerance == 0.002)
        await rig.recorder.start(log: rig.log)
        // Nine in a row, then a reading that does not follow the mouse: the count starts over, twice.
        for _ in 0..<9 { await echo() }
        await mouseOnly()
        for _ in 0..<9 { await echo() }
        await mouseOnly()
        await key()
        let lastOn = time
        // Ten in a row: off. A poll with the mouse still in between says nothing, so it neither counts nor breaks them.
        for i in 0..<10 {
            if i == 5 {
                time += 0.25
                await rig.poll(at: time)
            }
            await echo()
        }
        let off = time
        await key()
        await rig.recorder.pause()
        await rig.recorder.resume()
        await key()
        let lines = try await rig.finish()

        // The windows of a run are held until it settles: the two runs of nine that broke were written (looking like
        // keys, they may have been), and so was the key; those of the run of ten, none (9 + 9 + 1).
        #expect(lines.count == 19)
        let (lastOnTime, tenthWindow) = (host(lastOn), host(off - 0.25))
        #expect(lines.count { $0 >= lastOnTime } == 0)
        #expect(lines.allSatisfy { $0 < tenthWindow })
        // The first run's windows, in order: 1.244 s falls in the window of 1.0, … 3.244 s in that of 3.0.
        #expect(Array(lines.prefix(9)) == (0..<9).map { host(1.0 + 0.25 * Double($0)) })
    }
}

@Test func echoRunThatIsNotSettledWritesNothing() async throws {
    try await withTemporaryDirectory { dir in
        // A take whose reading follows the mouse from the start writes no window at all.
        let rig = try KeyRig(in: dir)
        await rig.recorder.start(log: rig.log)
        for poll in 1...10 { await rig.echo(at: 1.0 + 0.25 * Double(poll)) }
        #expect(try await rig.finish().isEmpty)

        // A run that a pause or the stop cuts short did not show the reading was the keyboard's: its windows go.
        rig.clock.set(5)
        let log = try EventLogWriter(url: dir.appendingPathComponent("second.jsonl"))
        await rig.recorder.start(log: log)
        for poll in 1...3 { await rig.echo(at: 5.0 + 0.25 * Double(poll)) }
        await rig.recorder.pause()
        rig.clock.set(6)
        await rig.recorder.resume()
        for poll in 1...3 { await rig.echo(at: 6.0 + 0.25 * Double(poll)) }
        #expect(try await stopAndRead(rig.recorder, log).isEmpty)
    }
}

@Test func listenAccessIsOnlyAsked() async throws {
    try await withTemporaryDirectory { dir in
        let rig = try KeyRig(in: dir)
        #expect(rig.input.listenAccessCalls == 0)
        await rig.recorder.start(log: rig.log)
        #expect(rig.input.listenAccessCalls == 1)
        await rig.key(at: 1.3)
        await rig.poll(at: 1.4)
        await rig.recorder.pause()
        await rig.recorder.resume()
        await rig.key(at: 1.6)
        // Not while it polls, nor on a pause or a resume.
        #expect(rig.input.keyReads == 3)
        #expect(rig.input.listenAccessCalls == 1)
        #expect(try await rig.finish() == [host(1.25), host(1.5)])

        // Once per take. Nothing else it calls could ask for a permission: the readings, secure input and the clock are
        // all the test's (and no source calls a function that requests one: the grep of the brief's step 4).
        rig.clock.set(2)
        let log = try EventLogWriter(url: dir.appendingPathComponent("second.jsonl"))
        await rig.recorder.start(log: log)
        #expect(rig.input.listenAccessCalls == 2)
        await rig.key(at: 2.3)
        #expect(try await stopAndRead(rig.recorder, log).map(\.t) == [host(2.25)])
        #expect(rig.input.listenAccessCalls == 2)
    }
}
