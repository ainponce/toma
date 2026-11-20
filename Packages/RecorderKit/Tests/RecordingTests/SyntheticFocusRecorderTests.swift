// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import SyntheticCapture
import Testing
@testable import Recording

// The synthetic focus of `synth-record --focus`: `SyntheticFocusRecorder` on manual ticks, and the command itself in a
// process of its own.

/// The `focus` lines of `events`, as their rectangles and kinds.
private func focusLines(_ events: [InputEvent]) -> [(t: HostTime, rect: Rect, kind: FocusKind)] {
    events.compactMap { event in
        guard case let .focus(x, y, width, height, kind) = event.kind else { return nil }
        return (event.t, Rect(x: x, y: y, width: width, height: height), kind)
    }
}

/// What `log` has on disk once at least `count` lines are there, waiting up to 5 s for them.
private func lines(of log: EventLogWriter, atLeast count: Int) async throws -> [InputEvent] {
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
        try log.flush()
        let events = try EventLogReader.read(log.url).events
        if events.count >= count || ContinuousClock.now > deadline { return events }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A class of the test bundle, to find where it is.
private final class BundleMarker {}

private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Rect {
    Rect(x: x, y: y, width: width, height: height)
}

@Suite struct SyntheticFocusRecorderTests {
    private let tick = Duration.milliseconds(50)

    @Test func scriptedFocusFollowsTheSyntheticTyping() async throws {
        try await withTemporaryDirectory { dir in
            let log = try EventLogWriter(url: dir.appendingPathComponent("focus.jsonl"))
            let ticks = ManualTicks()
            let recorder = SyntheticFocusRecorder(ticks: ticks.ticks)
            await recorder.start(log: log)
            // The state of 0 s, at once: no tick has fired.
            let first = focusLines(try await lines(of: log, atLeast: 2))
            #expect(first.map(\.rect) == [rect(40, 40, 240, 24), rect(44, 44, 0, 16)])
            #expect(first.map(\.kind) == [.element, .caret])
            #expect(first[0].t == first[1].t)

            // To 2.2 s: the field reached with the keyboard.
            for _ in 0..<44 { await ticks.fire(every: tick) }
            let second = focusLines(try await lines(of: log, atLeast: 3))
            #expect(second.count == 3 && second.last?.rect == rect(40, 120, 240, 24) && second.last?.kind == .element)

            // Nothing in the pause: the script is not even checked.
            await recorder.pause()
            #expect(ticks.timers(every: tick) == 0)
            for _ in 0..<30 { await ticks.fire(every: tick) }
            try log.flush()
            #expect(focusLines(try EventLogReader.read(log.url).events).count == 3)

            // The resume gives the state again, and the script goes on from 2.2 s: the cursor from 3 to 4 s.
            await recorder.resume()
            #expect(ticks.timers(every: tick) == 1)
            _ = try await lines(of: log, atLeast: 4)
            for _ in 0..<40 { await ticks.fire(every: tick) }
            await recorder.stop()
            #expect(ticks.timers(every: tick) == 0)
            try log.close()
            let all = focusLines(try EventLogReader.read(log.url).events)
            let states = [rect(40, 40, 240, 24), rect(44, 44, 0, 16), rect(40, 120, 240, 24), rect(40, 120, 240, 24)]
            let typing: [Rect] = [124.0, 300].flatMap { y in (0..<5).map { rect(44 + 8 * Double($0), y, 0, 16) } }
            #expect(all.map(\.rect) == states + typing)
            let kinds: [FocusKind] = [.element, .caret, .element, .element] + Array(repeating: .caret, count: 10)
            #expect(all.map(\.kind) == kinds)
            #expect(zip(all, all.dropFirst()).allSatisfy { $0.t <= $1.t })
        }
    }

    @Test func theScriptIsDecision13() {
        let script = SyntheticFocusRecorder.script
        #expect(script.map(\.seconds) == [0, 2.2] + (30...39).map { Double($0) / 10 })
        #expect(script.allSatisfy { !$0.reading.isSecure })
        #expect(script[0].reading == FocusReading(element: rect(40, 40, 240, 24), caret: rect(44, 44, 0, 16), isSecure: false))
        #expect(script[1].reading.element == rect(40, 120, 240, 24) && script[1].reading.caret == nil)
    }

    /// `recorder-dev synth-record --focus`, run as a process: its take has the two fields and the typing cursor.
    @Test func synthRecordWithFocusWritesIt() throws {
        // Built next to the test bundle.
        let executable = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "recorder-dev")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path), "build recorder-dev: \(executable.path)")
        try withTemporaryDirectory { dir in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["synth-record", dir.path, "--duration", "4.5", "--focus"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let path = try #require(String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init))
            let package = ProjectPackage(url: URL(fileURLWithPath: path))
            let read = try EventLogReader.read(package.eventsURL(take: "take-001"))
            #expect(read.skippedLines == 0)
            let downs = read.events.filter { if case .mouseDown(.left, _, _) = $0.kind { true } else { false } }
            let start = try #require(downs.first).t.adding(seconds: -0.5)
            let lines = focusLines(read.events)
            let elements = lines.filter { $0.kind == .element }
            #expect(elements.map(\.rect) == [rect(40, 40, 240, 24), rect(40, 120, 240, 24)])
            if elements.count == 2 {
                #expect(abs(elements[0].t.seconds(since: start)) < 0.2, "\(elements[0].t.seconds(since: start)) s")
                #expect(abs(elements[1].t.seconds(since: start) - 2.2) < 0.2, "\(elements[1].t.seconds(since: start)) s")
            }
            let carets = lines.filter { $0.kind == .caret }.dropFirst()
            #expect(carets.count == 10)
            #expect(carets.allSatisfy { (2.9...4.1).contains($0.t.seconds(since: start)) })
        }
    }
}
