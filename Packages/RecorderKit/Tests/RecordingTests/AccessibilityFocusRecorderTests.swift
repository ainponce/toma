// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import Recording

// `AccessibilityFocusRecorder` with readings the test sends as the Accessibility source would: only rectangles, the
// element before the text cursor at one time, never a cursor in a secure field, nothing in a pause or after the stop,
// and never a wait on a reading under way. `FocusReadSchedule`, the 50 ms between two readings, and the parts of
// `AXFocusSource` that need no Accessibility.

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

/// Readings the test sends. `read` sends one only while started, as the source does; `deliverLate` sends one through
/// the handler of the last start even after a stop, as a reading that was under way.
final class ManualFocusSource: FocusSource {
    private struct State {
        var running = false
        var handler: (@Sendable (FocusReading, HostTime) -> Void)?
        var starts = 0
        var stops = 0
    }

    private let canStart: Bool
    private let state = Mutex(State())

    init(canStart: Bool = true) {
        self.canStart = canStart
    }

    var isRunning: Bool { state.withLock { $0.running } }
    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }

    func start(handler: @escaping @Sendable (FocusReading, HostTime) -> Void) -> Bool {
        state.withLock { s in
            s.starts += 1
            guard canStart else { return false }
            (s.running, s.handler) = (true, handler)
            return true
        }
    }

    func stop() {
        state.withLock { s in
            s.stops += 1
            s.running = false
        }
    }

    /// A reading at `seconds`, if the source is started.
    func read(_ reading: FocusReading, at seconds: Double) {
        let handler = state.withLock { s in s.running ? s.handler : nil }
        handler?(reading, host(seconds))
    }

    /// A reading at `seconds` through the last start's handler, started or not.
    func deliverLate(_ reading: FocusReading, at seconds: Double) {
        let handler = state.withLock { $0.handler }
        handler?(reading, host(seconds))
    }
}

/// A source whose first reading of each start reaches the handler `delay` late, on a thread of its own, with the time
/// the reading started; `stop()` never waits for it. `delivered` returns once every reading begun has been handed over.
private final class SlowFocusSource: FocusSource {
    private let delay: TimeInterval
    private let clock: @Sendable () -> HostTime
    private let reading: FocusReading
    private let pending = Mutex(0)

    init(delay: TimeInterval, reading: FocusReading, clock: @escaping @Sendable () -> HostTime) {
        self.delay = delay
        self.reading = reading
        self.clock = clock
    }

    func start(handler: @escaping @Sendable (FocusReading, HostTime) -> Void) -> Bool {
        let time = clock()
        let (reading, delay) = (reading, delay)
        pending.withLock { $0 += 1 }
        let thread = Thread { [self] in
            Thread.sleep(forTimeInterval: delay)
            handler(reading, time)
            pending.withLock { $0 -= 1 }
        }
        thread.start()
        return true
    }

    func stop() {}

    func delivered() async {
        while pending.withLock({ $0 }) > 0 { try? await Task.sleep(for: .milliseconds(20)) }
    }
}

/// Whether secure input is on, as the test sets it.
private final class SecureInput: Sendable {
    private let on = Mutex(false)
    var value: Bool { on.withLock { $0 } }
    func set(_ value: Bool) { on.withLock { $0 = value } }
}

/// How many times the recorder said there is no Accessibility.
private final class Notices: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func add() { count.withLock { $0 += 1 } }
}

private struct FocusRig {
    let log: EventLogWriter
    let clock = TestClock(1)
    let source: ManualFocusSource
    let secure = SecureInput()
    let notices = Notices()
    let recorder: AccessibilityFocusRecorder

    init(in dir: URL, canStart: Bool = true) throws {
        log = try EventLogWriter(url: dir.appendingPathComponent("focus.jsonl"))
        source = ManualFocusSource(canStart: canStart)
        let (clock, secure, notices) = (clock, secure, notices)
        recorder = AccessibilityFocusRecorder(
            source: source, secureInput: { secure.value }, clock: { clock.now }, noAccessibility: { notices.add() })
    }

    /// Stops the recorder, closes the log and returns its events, in file order.
    func finish() async throws -> [InputEvent] {
        await recorder.stop()
        try log.close()
        return try EventLogReader.read(log.url).events
    }
}

private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Rect {
    Rect(x: x, y: y, width: width, height: height)
}

private func focus(_ seconds: Double, _ r: Rect, _ kind: FocusKind) -> InputEvent {
    InputEvent(t: host(seconds), kind: .focus(x: r.x, y: r.y, width: r.width, height: r.height, kind: kind))
}

private let field = rect(40, 40, 240, 24)
private let caret = rect(44, 44, 0, 16)
private let reading = FocusReading(element: field, caret: caret, isSecure: false)

@Suite struct AccessibilityFocusRecorderTests {
    @Test func writesTheElementThenTheCaretAtOneTime() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try FocusRig(in: dir)
            await rig.recorder.start(log: rig.log)
            #expect(rig.recorder.isListening)
            rig.source.read(reading, at: 2)
            // A reading with only the element, and one with only the cursor (another field's), each give their line.
            rig.source.read(FocusReading(element: rect(0, 100, 300, 30), caret: nil, isSecure: false), at: 3)
            rig.source.read(FocusReading(element: nil, caret: rect(-20.5, -1000, 1.5, 18), isSecure: false), at: 4)
            #expect(try await rig.finish() == [
                focus(2, field, .element), focus(2, caret, .caret),
                focus(3, rect(0, 100, 300, 30), .element),
                focus(4, rect(-20.5, -1000, 1.5, 18), .caret),
            ])
        }
    }

    @Test func aLineHasOnlyItsRect() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try FocusRig(in: dir)
            await rig.recorder.start(log: rig.log)
            rig.source.read(reading, at: 2)
            rig.source.read(FocusReading(element: rect(1, 2, 3, 4), caret: rect(5, 6, 0, 7), isSecure: false), at: 3)
            _ = try await rig.finish()
            let lines = try String(contentsOf: rig.log.url, encoding: .utf8).split(separator: "\n")
            #expect(lines.count == 4)
            for line in lines {
                let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                #expect(object.keys.sorted() == ["height", "kind", "t", "type", "width", "x", "y"], "\(line)")
                #expect(object["type"] as? String == "focus")
            }
        }
    }

    @Test func anUnchangedKindIsNotWrittenAgain() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try FocusRig(in: dir)
            await rig.recorder.start(log: rig.log)
            rig.source.read(reading, at: 2)
            rig.source.read(reading, at: 2.1)
            // Only the cursor moves: only a caret.
            let moved = rect(52, 44, 0, 16)
            rig.source.read(FocusReading(element: field, caret: moved, isSecure: false), at: 2.2)
            // A reading without a cursor does not forget the last one written.
            rig.source.read(FocusReading(element: field, caret: nil, isSecure: false), at: 2.3)
            rig.source.read(FocusReading(element: field, caret: moved, isSecure: false), at: 2.4)
            #expect(try await rig.finish() == [focus(2, field, .element), focus(2, caret, .caret), focus(2.2, moved, .caret)])
        }
        try await withTemporaryDirectory { dir in
            let rig = try FocusRig(in: dir)
            await rig.recorder.start(log: rig.log)
            // 1000 different readings in a second: at most one line of each kind a reading.
            for n in 0..<1000 {
                let x = Double(n)
                rig.source.read(
                    FocusReading(element: rect(x, 0, 100, 20), caret: rect(x + 1, 2, 0, 16), isSecure: false),
                    at: 2 + Double(n) / 1000)
            }
            let events = try await rig.finish()
            #expect(events.count == 2000)
            let byTime = Dictionary(grouping: events, by: \.t)
            #expect(byTime.count == 1000)
            for (_, lines) in byTime {
                #expect(lines.map(\.kind).count { if case .focus(_, _, _, _, .element) = $0 { true } else { false } } == 1)
                #expect(lines.map(\.kind).count { if case .focus(_, _, _, _, .caret) = $0 { true } else { false } } == 1)
            }
        }
    }

    @Test func aSecureFieldWritesOnlyTheElement() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try FocusRig(in: dir)
            await rig.recorder.start(log: rig.log)
            // A field whose role says it is secure.
            let password = rect(40, 200, 240, 24)
            rig.source.read(FocusReading(element: password, caret: rect(44, 204, 0, 16), isSecure: true), at: 2)
            // A field of an app that turned secure input on.
            rig.secure.set(true)
            rig.source.read(FocusReading(element: field, caret: caret, isSecure: false), at: 3)
            rig.source.read(FocusReading(element: field, caret: rect(60, 44, 0, 16), isSecure: false), at: 3.5)
            // Secure input off again: the cursor is written.
            rig.secure.set(false)
            rig.source.read(FocusReading(element: field, caret: caret, isSecure: false), at: 4)
            let events = try await rig.finish()
            #expect(events == [focus(2, password, .element), focus(3, field, .element), focus(4, caret, .caret)])
        }
        // Pure: the same rule.
        let kinds = AccessibilityFocusRecorder.kinds(of: reading, secure: true, last: (nil, nil))
        #expect(kinds == [.focus(x: 40, y: 40, width: 240, height: 24, kind: .element)])
        let secureReading = FocusReading(element: field, caret: caret, isSecure: true)
        #expect(AccessibilityFocusRecorder.kinds(of: secureReading, secure: false, last: (nil, nil)) == kinds)
    }

    @Test func pauseWritesNothingAndResumeWritesTheFocusAgain() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try FocusRig(in: dir)
            await rig.recorder.start(log: rig.log)
            rig.source.read(reading, at: 2)
            rig.clock.set(3)
            await rig.recorder.pause()
            // The source is stopped in the pause, and a reading under way is not written.
            #expect(!rig.source.isRunning && !rig.recorder.isListening)
            rig.source.deliverLate(FocusReading(element: rect(0, 0, 10, 10), caret: nil, isSecure: false), at: 3.5)
            rig.clock.set(5)
            await rig.recorder.resume()
            #expect(rig.source.starts == 2 && rig.source.isRunning && rig.recorder.isListening)
            // Read before the resume, handed over after it: left out.
            rig.source.read(FocusReading(element: rect(0, 0, 10, 10), caret: nil, isSecure: false), at: 4.9)
            // The same focus as before the pause: written again, it is the state after the resume.
            rig.source.read(reading, at: 5)
            #expect(try await rig.finish() == [
                focus(2, field, .element), focus(2, caret, .caret), focus(5, field, .element), focus(5, caret, .caret),
            ])
        }
    }

    @Test func nothingAfterStop() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try FocusRig(in: dir)
            await rig.recorder.start(log: rig.log)
            rig.source.read(reading, at: 2)
            await rig.recorder.stop()
            #expect(!rig.source.isRunning && !rig.recorder.isListening)
            rig.source.deliverLate(FocusReading(element: rect(0, 0, 10, 10), caret: nil, isSecure: false), at: 3)
            try rig.log.close()
            #expect(try EventLogReader.read(rig.log.url).events == [focus(2, field, .element), focus(2, caret, .caret)])
        }
    }

    @Test func aSlowReadingNeverHoldsPauseOrStop() async throws {
        try await withTemporaryDirectory { dir in
            let log = try EventLogWriter(url: dir.appendingPathComponent("focus.jsonl"))
            let clock = TestClock(1)
            let source = SlowFocusSource(delay: 2, reading: reading, clock: { clock.now })
            let recorder = AccessibilityFocusRecorder(source: source, secureInput: { false }, clock: { clock.now })
            await recorder.start(log: log)
            let watch = ContinuousClock()
            let pause = await watch.measure { await recorder.pause() }
            clock.set(2)
            await recorder.resume()
            let stop = await watch.measure { await recorder.stop() }
            #expect(pause < .milliseconds(100), "pause took \(pause)")
            #expect(stop < .milliseconds(100), "stop took \(stop)")
            // Both readings reach the handler after the pause and after the stop: neither is written.
            await source.delivered()
            try log.close()
            #expect(try EventLogReader.read(log.url).events.isEmpty)
        }
    }

    @Test func invalidRectsAreNotWritten() async throws {
        let big = AccessibilityFocusRecorder.largestCoordinate
        #expect(big == 100_000)
        let bad: [Rect] = [
            rect(.nan, 0, 10, 10), rect(0, .infinity, 10, 10), rect(0, 0, -.infinity, 10), rect(0, 0, 10, .nan),
            rect(0, 0, -1, 10), rect(0, 0, 10, -1), rect(big + 1, 0, 10, 10), rect(0, -big - 1, 10, 10),
            rect(big - 5, 0, 10, 10), rect(0, 0, 10, 0),
        ]
        for r in bad {
            let only = FocusReading(element: r, caret: r, isSecure: false)
            #expect(AccessibilityFocusRecorder.kinds(of: only, secure: false, last: (nil, nil)).isEmpty, "\(r)")
        }
        // An element needs a width; a text cursor may have none, but not a height of 0.
        let thin = FocusReading(element: rect(0, 0, 0, 20), caret: rect(0, 0, 0, 20), isSecure: false)
        #expect(AccessibilityFocusRecorder.kinds(of: thin, secure: false, last: (nil, nil))
            == [.focus(x: 0, y: 0, width: 0, height: 20, kind: .caret)])
        let flat = FocusReading(element: rect(0, 0, 20, 20), caret: rect(0, 0, 2, 0), isSecure: false)
        #expect(AccessibilityFocusRecorder.kinds(of: flat, secure: false, last: (nil, nil))
            == [.focus(x: 0, y: 0, width: 20, height: 20, kind: .element)])
        // The edges of what is valid.
        let edge = FocusReading(element: rect(-big, big - 10, 10, 10), caret: rect(big, -big, 0, 1), isSecure: false)
        #expect(AccessibilityFocusRecorder.kinds(of: edge, secure: false, last: (nil, nil)).count == 2)

        try await withTemporaryDirectory { dir in
            let rig = try FocusRig(in: dir)
            await rig.recorder.start(log: rig.log)
            for (n, r) in bad.enumerated() {
                rig.source.read(FocusReading(element: r, caret: r, isSecure: false), at: 2 + Double(n) / 10)
            }
            // Nothing invalid reached the writer, so closing throws no encoding error.
            #expect(try await rig.finish().isEmpty)
        }
    }

    @Test func withoutAccessibilityNothingStarts() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try FocusRig(in: dir, canStart: false)
            await rig.recorder.start(log: rig.log)
            #expect(!rig.recorder.isListening && !rig.source.isRunning)
            rig.source.read(reading, at: 2)
            rig.source.deliverLate(reading, at: 2)
            // A resume tries again, and says nothing more.
            rig.clock.set(3)
            await rig.recorder.pause()
            rig.clock.set(4)
            await rig.recorder.resume()
            #expect(rig.source.starts == 2 && !rig.recorder.isListening)
            #expect(try await rig.finish().isEmpty)
            #expect(rig.notices.value == 1)
        }
        // With it, nothing is said.
        try await withTemporaryDirectory { dir in
            let rig = try FocusRig(in: dir)
            #expect(!rig.recorder.isListening)
            await rig.recorder.start(log: rig.log)
            #expect(rig.recorder.isListening)
            _ = try await rig.finish()
            #expect(!rig.recorder.isListening && !rig.source.isRunning && rig.notices.value == 0)
        }
    }
}

@Suite struct FocusReadScheduleTests {
    private let interval = FocusReadSchedule.interval

    @Test func aQuietChangeIsReadAtOnce() {
        #expect(interval == 50_000_000)
        var schedule = FocusReadSchedule()
        #expect(schedule.changed(at: host(1)) == host(1))
        schedule.didRead(at: host(1))
        #expect(schedule.changed(at: host(2)) == host(2))
        schedule.didRead(at: host(2))
        // Just after a reading: the next one waits for the 50 ms.
        #expect(schedule.changed(at: host(2.01)) == host(2.05))
        // A pending reading covers what changes before it.
        #expect(schedule.changed(at: host(2.02)) == nil)
        #expect(schedule.changed(at: host(2.04)) == nil)
        schedule.didRead(at: host(2.05))
        #expect(schedule.changed(at: host(2.2)) == host(2.2))
    }

    /// Changes at each of `times`, reading when a reading is due: the times of the readings.
    private func reads(changingAt times: [HostTime]) -> [HostTime] {
        var schedule = FocusReadSchedule()
        var due: HostTime?
        var reads: [HostTime] = []
        for now in times {
            if let at = due, at <= now {
                schedule.didRead(at: at)
                reads.append(at)
                due = nil
            }
            if let at = schedule.changed(at: now) {
                if at <= now {
                    schedule.didRead(at: now)
                    reads.append(now)
                } else {
                    due = at
                }
            }
        }
        if let due {
            schedule.didRead(at: due)
            reads.append(due)
        }
        return reads
    }

    @Test func aBurstIsReadAtMostEvery50ms() {
        // A change every millisecond for a second.
        let reads = reads(changingAt: (0..<1000).map { host(10 + Double($0) / 1000) })
        #expect(!reads.isEmpty && reads.count <= 21, "\(reads.count) readings")
        #expect(zip(reads, reads.dropFirst()).allSatisfy { $1.nanoseconds - $0.nanoseconds >= UInt64(interval) })
    }

    @Test func theLastChangeOfABurstIsRead() throws {
        let changes = (0...12).map { host(10 + Double($0) / 100) }
        let reads = reads(changingAt: changes)
        let (last, lastChange) = (try #require(reads.last), try #require(changes.last))
        #expect(last >= lastChange)
        #expect(reads.first == changes.first)
    }
}

@Suite struct AXFocusSourceTests {
    @Test func withoutTrustItDoesNotStart() async {
        let calls = Mutex(0)
        let source = AXFocusSource(isTrusted: { false }, clock: HostTime.now)
        #expect(!source.start { _, _ in calls.withLock { $0 += 1 } })
        try? await Task.sleep(for: .milliseconds(200))
        source.stop()
        #expect(calls.withLock { $0 } == 0)
        #expect(AXFocusSource.messagingTimeout == 0.05)
    }

    @Test func secureRolesAreSecure() {
        #expect(AXFocusSource.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        #expect(AXFocusSource.isSecure(role: "AXSecureTextField", subrole: nil))
        #expect(!AXFocusSource.isSecure(role: "AXTextField", subrole: nil))
        #expect(!AXFocusSource.isSecure(role: nil, subrole: nil))
        #expect(!AXFocusSource.isSecure(role: "AXTextArea", subrole: "AXSearchField"))
    }

    @Test func caretRangesTryEmptyThenOne() {
        func ranges(_ location: Int, _ length: Int, of count: Int?) -> [[Int]] {
            AXFocusSource.caretRanges(selection: CFRange(location: location, length: length), characterCount: count)
                .map { [$0.location, $0.length] }
        }
        #expect(ranges(5, 0, of: 10) == [[5, 0], [5, 1]])
        #expect(ranges(10, 0, of: 10) == [[10, 0], [9, 1]])
        #expect(ranges(3, 4, of: 10) == [[3, 0], [3, 1]])
        #expect(ranges(3, 4, of: nil) == [[3, 0], [3, 1]])
        // An empty field has no character to ask for.
        #expect(ranges(0, 0, of: 0) == [[0, 0]])
        // Past the end, the last character.
        #expect(ranges(12, 0, of: 10) == [[12, 0], [9, 1]])
    }

    @Test func aCharactersBoxNarrowsToTheEdgeOfTheCursor() {
        let box = Rect(x: 100, y: 40, width: 8, height: 16)
        // At the character after the cursor: its leading edge. At the one before (the end of the text): its trailing edge.
        #expect(AXFocusSource.caret(in: box, of: CFRange(location: 5, length: 1), at: 5) == Rect(x: 100, y: 40, width: 0, height: 16))
        #expect(AXFocusSource.caret(in: box, of: CFRange(location: 9, length: 1), at: 10) == Rect(x: 108, y: 40, width: 0, height: 16))
        // An empty range's box is the cursor as it is.
        let thin = Rect(x: 100, y: 40, width: 1, height: 16)
        #expect(AXFocusSource.caret(in: thin, of: CFRange(location: 5, length: 0), at: 5) == thin)
    }

    @Test func ownProcessIsNeverObserved() {
        #expect(!AXFocusSource.observes(ProcessInfo.processInfo.processIdentifier))
        #expect(!AXFocusSource.observes(getpid()))
        #expect(!AXFocusSource.observes(0) && !AXFocusSource.observes(-1))
        #expect(AXFocusSource.observes(1))
    }

    /// Only where the process running the tests has Accessibility: the real source starts, and its stop never waits.
    @Test(.enabled(if: AXIsProcessTrusted())) func aTrustedSourceStopsAtOnce() async throws {
        let readings = Mutex<[FocusReading]>([])
        let source = AXFocusSource()
        #expect(source.start { reading, _ in readings.withLock { $0.append(reading) } })
        try await Task.sleep(for: .milliseconds(300))
        let watch = ContinuousClock()
        let stop = watch.measure { source.stop() }
        #expect(stop < .milliseconds(100), "stop took \(stop)")
        let count = readings.withLock { $0.count }
        try await Task.sleep(for: .milliseconds(300))
        // At most a reading that was under way at the stop.
        #expect(readings.withLock { $0.count } <= count + 1)
        // The element comes as the app gives it (the recorder checks it); the text cursor is checked before it is given.
        for reading in readings.withLock({ $0 }) {
            if let caret = reading.caret { #expect(AccessibilityFocusRecorder.isValid(caret, as: .caret)) }
            if reading.isSecure { #expect(reading.caret == nil) }
        }
    }

    @Test func aRoleThatCannotBeReadCountsAsSecure() {
        let text = "AXTextField" as CFString
        #expect(AXFocusSource.AttributeAnswer(error: .success, value: text) == .value("AXTextField"))
        #expect(AXFocusSource.AttributeAnswer(error: .noValue, value: nil) == AXFocusSource.AttributeAnswer.none)
        #expect(AXFocusSource.AttributeAnswer(error: .attributeUnsupported, value: nil) == AXFocusSource.AttributeAnswer.none)
        // The app did not answer in 50 ms, or any other error, or not a string: not known.
        for error: AXError in [.cannotComplete, .failure, .invalidUIElement, .apiDisabled, .notImplemented] {
            #expect(AXFocusSource.AttributeAnswer(error: error, value: nil) == .unknown, "\(error.rawValue)")
        }
        #expect(AXFocusSource.AttributeAnswer(error: .success, value: nil) == .unknown)
        #expect(AXFocusSource.AttributeAnswer(error: .success, value: 3 as CFNumber) == .unknown)

        let plain = AXFocusSource.AttributeAnswer.value("AXTextField")
        let secure = AXFocusSource.AttributeAnswer.value("AXSecureTextField")
        #expect(!AXFocusSource.isSecure(role: plain, subrole: .none))
        #expect(AXFocusSource.isSecure(role: plain, subrole: secure))
        #expect(AXFocusSource.isSecure(role: secure, subrole: .none))
        #expect(AXFocusSource.isSecure(role: .unknown, subrole: .none))
        #expect(AXFocusSource.isSecure(role: plain, subrole: .unknown))
        #expect(AXFocusSource.isSecure(role: .unknown, subrole: .unknown))
    }

    @Test func aFieldWhoseRoleCannotBeReadGivesNoCaret() {
        for (role, subrole) in [
            (FakeQueries.unknown, FakeQueries.noSubrole), (FakeQueries.textField, FakeQueries.unknown),
            (FakeQueries.textField, .value("AXSecureTextField")), (.value("AXSecureTextField"), FakeQueries.noSubrole),
        ] {
            let queries = FakeQueries()
            (queries.role, queries.subrole) = (role, subrole)
            let reading = AXFocusSource.reading(of: 1, with: queries, stopped: { false })
            #expect(reading == FocusReading(element: field, caret: nil, isSecure: true), "\(role) \(subrole)")
            // Not even asked for.
            #expect(queries.asked == ["role", "subrole", "frame"], "\(role) \(subrole)")
        }
        // A plain field gives its cursor.
        let queries = FakeQueries()
        #expect(AXFocusSource.reading(of: 1, with: queries, stopped: { false }) == reading)
    }

    @Test func aStoppedReadingAsksNothingMore() {
        let stopped = Mutex(false)
        let queries = FakeQueries()
        queries.whenAsked = { if $0 == "frame" { stopped.withLock { $0 = true } } }
        #expect(AXFocusSource.reading(of: 1, with: queries, stopped: { stopped.withLock { $0 } }) == nil)
        #expect(queries.asked == ["role", "subrole", "frame"])

        stopped.withLock { $0 = false }
        let late = FakeQueries()
        late.bounds = [:]
        late.whenAsked = { if $0 == "bounds 5 0" { stopped.withLock { $0 = true } } }
        #expect(AXFocusSource.reading(of: 1, with: late, stopped: { stopped.withLock { $0 } }) == nil)
        #expect(late.asked == ["role", "subrole", "frame", "selection", "bounds 5 0"])
    }

    @Test func theTextsLengthIsAskedOnlyWhenTheCursorsBoxIsNotEnough() {
        // The empty range at the cursor gives it: the length is not asked.
        let queries = FakeQueries()
        #expect(AXFocusSource.reading(of: 1, with: queries, stopped: { false })?.caret == caret)
        #expect(queries.asked == ["role", "subrole", "frame", "selection", "bounds 5 0"])

        // It gives nothing usable: the length, then the character at the cursor, narrowed to its leading edge.
        let fallback = FakeQueries()
        fallback.bounds = ["5 0": rect(0, 0, 0, 0), "5 1": rect(100, 40, 8, 16)]
        #expect(AXFocusSource.reading(of: 1, with: fallback, stopped: { false })?.caret == rect(100, 40, 0, 16))
        #expect(fallback.asked == ["role", "subrole", "frame", "selection", "bounds 5 0", "count", "bounds 5 1"])

        // At the end of the text, the character before it, narrowed to its trailing edge.
        let end = FakeQueries()
        end.selection = CFRange(location: 10, length: 0)
        end.bounds = ["9 1": rect(100, 40, 8, 16)]
        #expect(AXFocusSource.reading(of: 1, with: end, stopped: { false })?.caret == rect(108, 40, 0, 16))
        #expect(end.asked.suffix(3) == ["bounds 10 0", "count", "bounds 9 1"])
    }

    @Test func concurrentStartsLeaveNoThreadBehind() async throws {
        // `isTrusted` says yes; where the process has no Accessibility, the queries fail and the threads still run.
        let source = AXFocusSource(isTrusted: { true }, clock: HostTime.now)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in _ = source.start { _, _ in } }
        source.stop()
        try await Task.sleep(for: .milliseconds(300))
        let deadline = ContinuousClock.now + .seconds(3)
        while source.runningThreads > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(source.runningThreads == 0)
    }
}

/// The queries of a reading, answered as the test says, in the order they were asked.
private final class FakeQueries: AXFocusSource.FocusQueries {
    static let textField = AXFocusSource.AttributeAnswer.value("AXTextField")
    static let noSubrole = AXFocusSource.AttributeAnswer.none
    static let unknown = AXFocusSource.AttributeAnswer.unknown

    var role = textField
    var subrole = noSubrole
    var selection: CFRange? = CFRange(location: 5, length: 0)
    var count: Int? = 10
    /// By "location length".
    var bounds: [String: Rect] = ["5 0": rect(44, 44, 0, 16)]
    private(set) var asked: [String] = []
    var whenAsked: (String) -> Void = { _ in }

    private func ask(_ query: String) {
        asked.append(query)
        whenAsked(query)
    }

    func role(of element: Int) -> AXFocusSource.AttributeAnswer {
        ask("role")
        return role
    }

    func subrole(of element: Int) -> AXFocusSource.AttributeAnswer {
        ask("subrole")
        return subrole
    }

    func frame(of element: Int) -> Rect? {
        ask("frame")
        return field
    }

    func selection(of element: Int) -> CFRange? {
        ask("selection")
        return selection
    }

    func characterCount(of element: Int) -> Int? {
        ask("count")
        return count
    }

    func bounds(of element: Int, for range: CFRange) -> Rect? {
        ask("bounds \(range.location) \(range.length)")
        return bounds["\(range.location) \(range.length)"]
    }
}
