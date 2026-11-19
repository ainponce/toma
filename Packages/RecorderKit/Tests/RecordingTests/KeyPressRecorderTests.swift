// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Dispatch
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import SyntheticCapture
import Testing
@testable import Recording

// `KeyPressRecorder` with keys the test sends as the tap would: one `keyPress` line a key, never during secure input,
// a pause or after the stop, and the package raised to 4 once, before the first line.

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

/// Keys the test sends. `press` sends one only while started, as the tap does; `deliverLate` sends one through the
/// handler of the last start even after a stop, as a key the tap had already handed to the queue.
final class ManualKeySource: KeyEventSource {
    private struct State {
        var running = false
        var queue: DispatchSerialQueue?
        var handler: (@Sendable (KeyEvent, HostTime) -> Void)?
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

    func start(on queue: DispatchSerialQueue, handler: @escaping @Sendable (KeyEvent, HostTime) -> Void) -> Bool {
        state.withLock { s in
            s.starts += 1
            guard canStart else { return false }
            (s.running, s.queue, s.handler) = (true, queue, handler)
            return true
        }
    }

    func stop() {
        state.withLock { s in
            s.stops += 1
            s.running = false
        }
    }

    /// A key at `seconds`, if the source is started; returns once the recorder's queue has handled it.
    func press(_ key: KeyEvent, at seconds: Double) async {
        let target = state.withLock { s in s.running ? s.queue.map { ($0, s.handler!) } : nil }
        guard let (queue, handler) = target else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                handler(key, host(seconds))
                done.resume()
            }
        }
    }

    /// A key at `seconds` through the last start's handler, started or not.
    func deliverLate(_ key: KeyEvent, at seconds: Double) async {
        let target = state.withLock { s in s.queue.map { ($0, s.handler!) } }
        guard let (queue, handler) = target else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                handler(key, host(seconds))
                done.resume()
            }
        }
    }
}

/// What the package's raise saw: how many times it was called and, each time, how many `keyPress` lines the log had
/// on disk then. It throws `failure` when set.
private final class RaiseProbe: Sendable {
    private struct State {
        var calls = 0
        var linesAtEachCall: [Int] = []
    }

    private let state = Mutex(State())
    private let log: EventLogWriter
    private let failure: (any Error & Sendable)?

    init(log: EventLogWriter, failure: (any Error & Sendable)? = nil) {
        self.log = log
        self.failure = failure
    }

    var calls: Int { state.withLock { $0.calls } }
    var linesAtEachCall: [Int] { state.withLock { $0.linesAtEachCall } }

    func raise() throws {
        try log.flush()
        let lines = try EventLogReader.read(log.url).events.count { $0.kind.requiresFormatVersion4 }
        state.withLock { s in
            s.calls += 1
            s.linesAtEachCall.append(lines)
        }
        if let failure { throw failure }
    }
}

private struct DiskFull: Error {}

/// Whether secure input is on, as the test sets it.
private final class SecureInput: Sendable {
    private let on = Mutex(false)
    var value: Bool { on.withLock { $0 } }
    func set(_ value: Bool) { on.withLock { $0 = value } }
}

private struct KeyRig {
    static let take = "take-001"
    let log: EventLogWriter
    let clock = TestClock(1)
    let source: ManualKeySource
    let secure = SecureInput()
    let recorder: KeyPressRecorder
    let probe: RaiseProbe

    init(in dir: URL, canStart: Bool = true, raiseFailure: (any Error & Sendable)? = nil, raiser: Bool = true) throws {
        let package = try ProjectPackage.create(in: dir, name: "Keys", app: AppInfo(name: "Tests", version: "0"), now: Date())
        try FileManager.default.createDirectory(at: package.takeDirectory(Self.take), withIntermediateDirectories: true)
        log = try EventLogWriter(url: package.eventsURL(take: Self.take))
        source = ManualKeySource(canStart: canStart)
        let (clock, secure) = (clock, secure)
        recorder = KeyPressRecorder(source: source, secureInput: { secure.value }, clock: { clock.now })
        let probe = RaiseProbe(log: log, failure: raiseFailure)
        self.probe = probe
        if raiser { recorder.setFormatRaiser { try probe.raise() } }
    }

    /// Stops the recorder, closes the log and returns its `keyPress` events, in file order.
    func finish() async throws -> [InputEvent] {
        await recorder.stop()
        try log.close()
        return try EventLogReader.read(log.url).events.filter(\.kind.requiresFormatVersion4)
    }
}

private let shiftFlags = UInt32(truncatingIfNeeded: CGEventFlags.maskShift.rawValue)
private let commandFlags = UInt32(truncatingIfNeeded: CGEventFlags.maskCommand.rawValue)
/// The bits macOS sets with any key: no modifier (`NX_NONCOALSESCEDMASK`) and the left ⇧ (device dependent).
private let deviceBits: UInt32 = 0x0000_0100 | 0x0000_0002

private func key(_ code: UInt16, _ chars: String?, mods: UInt32 = 0, isRepeat: Bool = false) -> KeyEvent {
    KeyEvent(code: code, chars: chars, mods: mods, isRepeat: isRepeat)
}

@Suite struct KeyPressRecorderTests {
    @Test func eachKeyDownIsOneLine() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try KeyRig(in: dir)
            await rig.recorder.start(log: rig.log)
            #expect(rig.recorder.isListening)
            await rig.source.press(key(0, "A", mods: shiftFlags | deviceBits), at: 2)
            await rig.source.press(key(8, "c", mods: commandFlags | 0x0000_0108), at: 3)
            await rig.source.press(key(123, nil, mods: 0x00A0_0100, isRepeat: true), at: 4)
            #expect(try await rig.finish() == [
                InputEvent(t: host(2), kind: .keyPress(code: 0, chars: "A", mods: shiftFlags, isRepeat: false)),
                InputEvent(t: host(3), kind: .keyPress(code: 8, chars: "c", mods: commandFlags, isRepeat: false)),
                // ← sets fn (`maskSecondaryFn`) and the numeric pad's bit: fn stays, the pad's goes.
                InputEvent(t: host(4), kind: .keyPress(code: 123, chars: nil, mods: 0x0080_0000, isRepeat: true)),
            ])
        }
    }

    @Test func secureInputWritesNothing() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try KeyRig(in: dir)
            await rig.recorder.start(log: rig.log)
            // A password field from the first key: nothing, not even the raise.
            rig.secure.set(true)
            await rig.source.press(key(0, "a"), at: 2)
            await rig.source.press(key(36, nil), at: 3)  // the ↩ that closes it
            #expect(rig.probe.calls == 0)
            rig.secure.set(false)
            await rig.source.press(key(11, "b"), at: 4)
            rig.secure.set(true)
            await rig.source.press(key(8, "c"), at: 5)
            rig.secure.set(false)
            await rig.source.press(key(2, "d"), at: 6)
            #expect(try await rig.finish().map(\.t) == [host(4), host(6)])
            #expect(rig.probe.calls == 1)
        }
    }

    @Test func theFirstKeyRaisesTo4BeforeItsLine() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try KeyRig(in: dir)
            await rig.recorder.start(log: rig.log)
            #expect(rig.probe.calls == 0)  // starting raises nothing
            await rig.source.press(key(0, "a"), at: 2)
            await rig.source.press(key(11, "b"), at: 3)
            await rig.source.press(key(8, "c"), at: 4)
            #expect(try await rig.finish().count == 3)
            // One raise, while the log had no `keyPress` line yet.
            #expect(rig.probe.linesAtEachCall == [0])
        }
    }

    @Test func raiseFailureWritesNoKey() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try KeyRig(in: dir, raiseFailure: DiskFull())
            await rig.recorder.start(log: rig.log)
            await rig.source.press(key(0, "a"), at: 2)
            await rig.source.press(key(11, "b"), at: 3)
            // Nor after a pause: the take has no keys any more, and the keyboard is not listened to again.
            rig.clock.set(4)
            await rig.recorder.pause()
            rig.clock.set(5)
            await rig.recorder.resume()
            #expect(!rig.recorder.isListening)
            await rig.source.deliverLate(key(8, "c"), at: 6)
            #expect(try await rig.finish().isEmpty)
            #expect(rig.probe.calls == 1)
        }
    }

    @Test func withoutARaiserNothingIsWritten() async throws {
        try await withTemporaryDirectory { dir in
            // Nothing said the package may go to 4: no line can go into it.
            let rig = try KeyRig(in: dir, raiser: false)
            await rig.recorder.start(log: rig.log)
            await rig.source.press(key(0, "a"), at: 2)
            #expect(try await rig.finish().isEmpty)
        }
    }

    @Test func pauseAndStopWriteNothingMore() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try KeyRig(in: dir)
            await rig.recorder.start(log: rig.log)
            await rig.source.press(key(0, "a"), at: 2)
            rig.clock.set(3)
            await rig.recorder.pause()
            // The keyboard is not listened to while paused, and a key the tap had handed over is not written.
            #expect(!rig.source.isRunning && !rig.recorder.isListening)
            await rig.source.deliverLate(key(11, "b"), at: 2.9)
            await rig.source.deliverLate(key(8, "c"), at: 3.5)
            await rig.recorder.stop()
            #expect(!rig.source.isRunning)
            await rig.source.deliverLate(key(2, "d"), at: 4)
            try rig.log.close()
            let keys = try EventLogReader.read(rig.log.url).events.filter(\.kind.requiresFormatVersion4)
            #expect(keys.map(\.t) == [host(2)])
        }
    }

    @Test func resumeRecordsOnlyFromThen() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try KeyRig(in: dir)
            await rig.recorder.start(log: rig.log)
            await rig.source.press(key(0, "a"), at: 2)
            rig.clock.set(3)
            await rig.recorder.pause()
            rig.clock.set(5)
            await rig.recorder.resume()
            #expect(rig.source.starts == 2 && rig.source.isRunning && rig.recorder.isListening)
            // Pressed during the pause, handed over after the resume: left out.
            await rig.source.press(key(11, "b"), at: 4)
            await rig.source.press(key(8, "c"), at: 6)
            #expect(try await rig.finish().map(\.t) == [host(2), host(6)])
            #expect(rig.probe.calls == 1)
        }
    }

    @Test func noTapNoLinesAndSaysSo() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try KeyRig(in: dir, canStart: false)
            await rig.recorder.start(log: rig.log)
            #expect(!rig.recorder.isListening)
            await rig.source.press(key(0, "a"), at: 2)
            #expect(try await rig.finish().isEmpty)
            #expect(rig.probe.calls == 0)
        }
        try await withTemporaryDirectory { dir in
            let rig = try KeyRig(in: dir)
            #expect(!rig.recorder.isListening)
            await rig.recorder.start(log: rig.log)
            #expect(rig.recorder.isListening)
            _ = try await rig.finish()
            #expect(!rig.recorder.isListening && !rig.source.isRunning)
        }
    }

    @Test func livesAlongsideKeyActivity() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try KeyRig(in: dir, raiser: false)
            let ticks = ManualTicks()
            let clock = rig.clock
            let activity = KeyActivityRecorder(
                secondsSinceLastKey: { 0.05 }, secondsSinceLastMouseMove: { 100 }, secureInput: { false },
                listenAccess: { false }, clock: { clock.now }, ticks: ticks.ticks)
            let both = CompositeInputRecorder([activity, rig.recorder])
            // The composite hands the raise on to the recorders that need it.
            both.setFormatRaiser { try rig.probe.raise() }
            await both.start(log: rig.log)
            await rig.source.press(key(0, "a"), at: 1.05)
            clock.set(1.1)
            await ticks.fire(every: KeyActivityRecorder.interval)
            await both.stop()
            try rig.log.close()
            let kinds = try EventLogReader.read(rig.log.url).events.map(\.kind)
            #expect(kinds.contains(.keyActivity))
            #expect(kinds.contains(.keyPress(code: 0, chars: "a", mods: 0, isRepeat: false)))
            #expect(rig.probe.calls == 1)
        }
    }

    @Test func modsKeepOnlyTheFiveModifiers() async throws {
        let five: [CGEventFlags] = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        #expect(KeyPressRecorder.modifierMask == five.reduce(0) { $0 | UInt32(truncatingIfNeeded: $1.rawValue) })
        try await withTemporaryDirectory { dir in
            let rig = try KeyRig(in: dir)
            await rig.recorder.start(log: rig.log)
            await rig.source.press(key(0, "a", mods: .max), at: 2)
            // Caps Lock, the numeric pad, help and the device's own bits go.
            let others: [CGEventFlags] = [.maskAlphaShift, .maskNumericPad, .maskHelp, .maskNonCoalesced]
            await rig.source.press(key(0, "a", mods: others.reduce(0) { $0 | UInt32($1.rawValue) } | 0xFF), at: 3)
            #expect(try await rig.finish().map(\.kind) == [
                .keyPress(code: 0, chars: "a", mods: KeyPressRecorder.modifierMask, isRepeat: false),
                .keyPress(code: 0, chars: "a", mods: 0, isRepeat: false),
            ])
        }
    }
}

@Suite struct ScriptedKeyEventsTests {
    /// The keys `text` types, one a tick.
    private func typed(_ text: String) async -> [KeyEvent] {
        let ticks = ManualTicks()
        let source = ScriptedKeyEvents(text: text, every: .milliseconds(100), ticks: ticks.ticks)
        let queue = DispatchSerialQueue(label: "test.scripted-keys")
        let keys = Mutex<[KeyEvent]>([])
        #expect(source.start(on: queue) { key, _ in keys.withLock { $0.append(key) } })
        for _ in 0..<(text.count + 2) { await ticks.fire(every: .milliseconds(100)) }
        source.stop()
        return keys.withLock { $0 }
    }

    @Test func typesTheTextWithUSCodes() async {
        let shift = UInt32(truncatingIfNeeded: CGEventFlags.maskShift.rawValue)
        #expect(await typed("Hi 1!\n") == [
            KeyEvent(code: 4, chars: "H", mods: shift, isRepeat: false),
            KeyEvent(code: 34, chars: "i", mods: 0, isRepeat: false),
            KeyEvent(code: 49, chars: " ", mods: 0, isRepeat: false),
            KeyEvent(code: 18, chars: "1", mods: 0, isRepeat: false),
            KeyEvent(code: 18, chars: "!", mods: shift, isRepeat: false),
            KeyEvent(code: 36, chars: nil, mods: 0, isRepeat: false),
        ])
        // A character the US layout has no key for is left out.
        #expect(await typed("añb").map(\.chars) == ["a", "b"])
    }

    @Test func goesOnAfterAStopFromWhereItWas() async {
        let ticks = ManualTicks()
        let source = ScriptedKeyEvents(text: "abc", every: .milliseconds(100), ticks: ticks.ticks)
        let queue = DispatchSerialQueue(label: "test.scripted-keys")
        let keys = Mutex<[String]>([])
        _ = source.start(on: queue) { key, _ in keys.withLock { $0.append(key.chars ?? "") } }
        await ticks.fire(every: .milliseconds(100))
        source.stop()
        #expect(ticks.timers(every: .milliseconds(100)) == 0)
        _ = source.start(on: queue) { key, _ in keys.withLock { $0.append(key.chars ?? "") } }
        for _ in 0..<4 { await ticks.fire(every: .milliseconds(100)) }
        #expect(keys.withLock { $0 } == ["a", "b", "c"])
        // Once typed, it stops its timer.
        #expect(ticks.timers(every: .milliseconds(100)) == 0)
        source.stop()
    }
}

/// `chars` from the keyboard layout in use (no permission needed): what a key types with only ⇧, and nothing for a key
/// that types a control character.
@Suite struct KeyboardLayoutTests {
    @Test @MainActor func charactersComeFromTheLayoutInUse() throws {
        let layout = KeyboardLayout()
        #expect(layout.characters(code: 49, shift: false, keyboardType: 0) == nil)  // before the first reading
        layout.refresh()
        #expect(layout.characters(code: 49, shift: false, keyboardType: 0) == " ")  // space
        // ↩, ⇥, ⌫, esc, ⌦, ←, F1: control characters.
        for code: UInt16 in [36, 48, 51, 53, 117, 123, 122] {
            #expect(layout.characters(code: code, shift: false, keyboardType: 0) == nil, "key \(code)")
            #expect(layout.characters(code: code, shift: true, keyboardType: 0) == nil, "key \(code) with ⇧")
        }
        // The key at A on a US keyboard types a letter in every layout this Mac may have; ⇧ makes it a capital.
        let letter = try #require(layout.characters(code: 0, shift: false, keyboardType: 0))
        if letter.first?.isLetter == true {
            #expect(layout.characters(code: 0, shift: true, keyboardType: 0) == letter.uppercased())
        }
    }
}
