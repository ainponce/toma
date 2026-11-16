// SPDX-License-Identifier: GPL-3.0-or-later
// @testable for `ShortcutsCLI.shortcuts(listed:)`: what `shortcuts list` prints is otherwise only reached by running the
// real Shortcuts, which no test does.
@testable import AppSupport
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing

/// Do Not Disturb around a take, with a shortcut of the user's that no test runs: `FakeShortcuts` answers for it.
@MainActor @Suite struct FocusGuardTests {
    @Test func focusShortcutRunsOnBeforeAndOffAfter() async throws {
        try await withFocusDefaults { defaults, suite in
            let runner = FakeShortcuts(marksIn: suite) { _ in FocusGuard.changedOutput }
            let focus = FocusGuard(runner: runner, defaults: defaults)
            #expect(await focus.takeWillStart(shortcut: "ID"))
            #expect(runner.runs == [ShortcutRun("ID", "on")])
            // Saved before the shortcut ran, so a crash while it runs still turns Do Not Disturb off.
            #expect(runner.marksWhenRun == ["ID"])
            #expect(defaults.string(forKey: FocusGuard.activeKey) == "ID")

            await focus.takeDidEnd()
            #expect(runner.runs == [ShortcutRun("ID", "on"), ShortcutRun("ID", "off")])
            #expect(defaults.string(forKey: FocusGuard.activeKey) == nil)
            // Once is enough.
            await focus.takeDidEnd()
            #expect(runner.runs.count == 2)
        }
    }

    @Test func focusIsLeftOnIfItWasAlreadyOn() async throws {
        try await withFocusDefaults { defaults, _ in
            // Do Not Disturb was on already: the shortcut changed nothing, so it is not turned off afterwards.
            let runner = FakeShortcuts { _ in "" }
            let focus = FocusGuard(runner: runner, defaults: defaults)
            #expect(await focus.takeWillStart(shortcut: "ID"))
            #expect(defaults.string(forKey: FocusGuard.activeKey) == nil)
            await focus.takeDidEnd()
            #expect(runner.runs == [ShortcutRun("ID", "on")])
        }
    }

    @Test func focusIsTurnedOffAfterACrash() async throws {
        try await withFocusDefaults { defaults, _ in
            let runner = FakeShortcuts { _ in "" }
            let focus = FocusGuard(runner: runner, defaults: defaults)
            // Nothing was left on.
            await focus.recoverAfterLaunch()
            #expect(runner.runs.isEmpty)

            // The app ended during a take that turned Do Not Disturb on.
            defaults.set("ID", forKey: FocusGuard.activeKey)
            await focus.recoverAfterLaunch()
            #expect(runner.runs == [ShortcutRun("ID", "off")])
            #expect(defaults.string(forKey: FocusGuard.activeKey) == nil)
        }
    }

    @Test func noShortcutRunsNothing() async throws {
        try await withFocusDefaults { defaults, _ in
            let runner = FakeShortcuts { _ in FocusGuard.changedOutput }
            let focus = FocusGuard(runner: runner, defaults: defaults)
            #expect(await focus.takeWillStart(shortcut: nil))
            await focus.takeDidEnd()
            #expect(runner.runs.isEmpty && defaults.string(forKey: FocusGuard.activeKey) == nil)
        }
    }

    @Test func aFailedShortcutLeavesNothingToTurnOff() async throws {
        try await withFocusDefaults { defaults, _ in
            let runner = FakeShortcuts { _ in throw ShortcutsCLIError.failed(status: 1, message: "No shortcut") }
            let focus = FocusGuard(runner: runner, defaults: defaults)
            #expect(await focus.takeWillStart(shortcut: "ID") == false)
            #expect(defaults.string(forKey: FocusGuard.activeKey) == nil)
            await focus.takeDidEnd()
            #expect(runner.runs == [ShortcutRun("ID", "on")])
        }
    }

    @Test func aShortcutThatDidNotEndInTimeIsTurnedOffAfterTheTake() async throws {
        try await withFocusDefaults { defaults, _ in
            // Terminated at its time limit, it may still turn Do Not Disturb on: the take's end turns it off.
            let runner = FakeShortcuts { run in
                if run.input == "on" { throw ShortcutsCLIError.timedOut }
                return ""
            }
            let focus = FocusGuard(runner: runner, defaults: defaults)
            #expect(await focus.takeWillStart(shortcut: "ID") == false)
            #expect(defaults.string(forKey: FocusGuard.activeKey) == "ID")
            await focus.takeDidEnd()
            #expect(runner.runs == [ShortcutRun("ID", "on"), ShortcutRun("ID", "off")])
            #expect(defaults.string(forKey: FocusGuard.activeKey) == nil)
        }
    }

    @Test func anOffThatFailedIsTriedAgain() async throws {
        try await withFocusDefaults { defaults, _ in
            // `shortcuts` cannot run while the Mac logs out.
            let failing = FakeShortcuts { run in
                if run.input == "off" { throw ShortcutsCLIError.failed(status: 1, message: "Logging out") }
                return FocusGuard.changedOutput
            }
            let focus = FocusGuard(runner: failing, defaults: defaults)
            #expect(await focus.takeWillStart(shortcut: "ID"))
            await focus.takeDidEnd()
            #expect(failing.runs == [ShortcutRun("ID", "on"), ShortcutRun("ID", "off")])
            // Do Not Disturb may still be on: the mark stays.
            #expect(defaults.string(forKey: FocusGuard.activeKey) == "ID")

            // At the next launch it is turned off.
            let runner = FakeShortcuts { _ in "" }
            await FocusGuard(runner: runner, defaults: defaults).recoverAfterLaunch()
            #expect(runner.runs == [ShortcutRun("ID", "off")])
            #expect(defaults.string(forKey: FocusGuard.activeKey) == nil)
        }
    }

    @Test(arguments: [false, true]) func anOffOwedFromBeforeStaysOwed(onFails: Bool) async throws {
        try await withFocusDefaults { defaults, _ in
            // The last take's `off` failed, so Do Not Disturb is still on: this take's `on` changes nothing (or fails),
            // and the `off` is still owed when it ends.
            let runner = FakeShortcuts { run in
                if run.input == "on", onFails { throw ShortcutsCLIError.failed(status: 1, message: "") }
                return ""
            }
            let focus = FocusGuard(runner: runner, defaults: defaults)
            defaults.set("OLD", forKey: FocusGuard.activeKey)
            #expect(await focus.takeWillStart(shortcut: "ID") == !onFails)
            #expect(defaults.string(forKey: FocusGuard.activeKey) == "OLD")
            await focus.takeDidEnd()
            #expect(runner.runs == [ShortcutRun("ID", "on"), ShortcutRun("OLD", "off")])
            #expect(defaults.string(forKey: FocusGuard.activeKey) == nil)
        }
    }

    @Test func theShortcutNeverRunsTwiceAtOnce() async throws {
        try await withFocusDefaults { defaults, _ in
            // Recovering at launch turns Do Not Disturb off while the first take already turns it on.
            let off = ShortcutGate()
            let runner = FakeShortcuts { run in
                if run.input == "off" { await off.pass() }
                return FocusGuard.changedOutput
            }
            let focus = FocusGuard(runner: runner, defaults: defaults)
            defaults.set("ID", forKey: FocusGuard.activeKey)
            let recovering = Task { await focus.recoverAfterLaunch() }
            #expect(await eventually { off.isHolding })
            let starting = Task { await focus.takeWillStart(shortcut: "ID") }
            try await Task.sleep(for: .milliseconds(100))
            #expect(runner.runs == [ShortcutRun("ID", "off")])  // "on" waits for "off"
            off.open()
            await recovering.value
            #expect(await starting.value)
            #expect(runner.runs == [ShortcutRun("ID", "off"), ShortcutRun("ID", "on")])
            // The take's mark is kept: its "off" comes when it ends.
            #expect(defaults.string(forKey: FocusGuard.activeKey) == "ID")
        }
    }

    @Test(.timeLimit(.minutes(1))) func shortcutRunStopsAtTheTimeLimit() async throws {
        // `yes` never ends by itself, as `shortcuts` waiting on a dialog would not.
        let cli = ShortcutsCLI(executable: URL(filePath: "/usr/bin/yes"), timeLimit: .milliseconds(200))
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: ShortcutsCLIError.timedOut) {
            _ = try await cli.run(shortcut: "ID", input: "on")
        }
        #expect(clock.now - started < .seconds(2))
        // Terminated and waited for: no `yes` is left running, nor a zombie of it.
        #expect(childProcesses(named: "yes") == 0)
    }

    @Test func listedShortcutsKeepTheirIdentifiers() {
        let listed = """
            Focus for Toma (2D1E36B2-5C9A-4F83-9C67-1A2B3C4D5E6F)
            Morning (routine) (8F0E2B6C-0000-4D2C-8E5F-0123456789AB)

            Not a listed shortcut
            """
        #expect(ShortcutsCLI.shortcuts(listed: listed) == [
            ShortcutInfo(name: "Focus for Toma", identifier: "2D1E36B2-5C9A-4F83-9C67-1A2B3C4D5E6F"),
            ShortcutInfo(name: "Morning (routine)", identifier: "8F0E2B6C-0000-4D2C-8E5F-0123456789AB"),
        ])
    }
}

/// A defaults suite of its own, and its name, removed when `body` returns.
@MainActor private func withFocusDefaults(_ body: (UserDefaults, String) async throws -> Void) async throws {
    let suite = "FocusGuardTests-\(UUID().uuidString)"
    let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
    defer { defaults.removePersistentDomain(forName: suite) }
    try await body(defaults, suite)
}

/// How many child processes of the tests are named `name`, running or exited but not waited for (zombies).
private func childProcesses(named name: String) -> Int {
    let capacity = Int(max(proc_listchildpids(getpid(), nil, 0), 0)) + 16
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = proc_listchildpids(getpid(), &pids, Int32(capacity * MemoryLayout<pid_t>.size))
    return pids.prefix(Int(max(count, 0))).count { pid in
        // `sysctl` still reads a zombie's name, which `proc_name` does not.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return command == name
    }
}

// MARK: - Fakes

/// One run of a shortcut: which one, with what input.
struct ShortcutRun: Equatable, CustomStringConvertible {
    var identifier: String
    var input: String

    init(_ identifier: String, _ input: String) {
        self.identifier = identifier
        self.input = input
    }

    var description: String { "\(identifier) \(input)" }
}

/// Shortcuts that answer as `answer` says, and remember every run with the Focus mark (`FocusGuard.activeKey`) of
/// the defaults suite `marksIn` at that moment.
final class FakeShortcuts: ShortcutRunning {
    private struct State {
        var runs: [ShortcutRun] = []
        var marks: [String?] = []
    }

    private let state = Mutex(State())
    private let suite: String?
    private let answer: @Sendable (ShortcutRun) async throws -> String

    /// Every run, in order.
    var runs: [ShortcutRun] { state.withLock { $0.runs } }
    /// The mark as each run began, if `marksIn` named a suite.
    var marksWhenRun: [String?] { state.withLock { $0.marks } }

    init(marksIn suite: String? = nil, answer: @escaping @Sendable (ShortcutRun) async throws -> String) {
        self.suite = suite
        self.answer = answer
    }

    func run(shortcut identifier: String, input: String) async throws -> String {
        let run = ShortcutRun(identifier, input)
        let mark = suite.flatMap { UserDefaults(suiteName: $0)?.string(forKey: FocusGuard.activeKey) }
        state.withLock { state in
            state.runs.append(run)
            state.marks.append(mark)
        }
        return try await answer(run)
    }

    func list() async throws -> [ShortcutInfo] {
        []
    }
}

/// Holds who passes it until `open()`.
final class ShortcutGate: Sendable {
    private struct State {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var isHolding: Bool { state.withLock { !$0.waiting.isEmpty } }

    func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen { state.waiting.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }
}
