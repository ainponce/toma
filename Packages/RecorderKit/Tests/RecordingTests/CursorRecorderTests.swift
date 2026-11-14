// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import Synchronization
import Testing
import ProjectFormat
@testable import Recording

@Suite struct CursorRecorderTests {
    /// A location that moves to a new point every 3rd call.
    final class SteppingLocation: Sendable {
        private let calls = Mutex(0)
        /// How many times the recorder read the location.
        var callCount: Int { calls.withLock { $0 } }
        func next() -> CGPoint {
            let n = calls.withLock { $0 += 1; return $0 }
            return CGPoint(x: Double((n - 1) / 3), y: 7)
        }
    }

    @Test func recordsOnlyChangedPositionsAtSampleRate() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("events.jsonl")
            let log = try EventLogWriter(url: url)
            let source = SteppingLocation()
            let recorder = CursorRecorder(clock: HostTime.now, location: { source.next() })
            let started = HostTime.now()
            await recorder.start(log: log)
            await recorder.start(log: log) // idempotent
            try await Task.sleep(for: .milliseconds(500))
            await recorder.stop()
            await recorder.stop() // idempotent
            let elapsed = HostTime.now().seconds(since: started)
            try log.close()

            let events = try EventLogReader.read(url).events
            let points: [(Double, Double)] = events.compactMap {
                if case .cursor(let x, let y) = $0.kind { return (x, y) }
                return nil
            }
            #expect(points.count == events.count)
            // Every change of position is recorded once, and only those: the location moves every third read.
            // Counted against the reads the recorder made, not the time slept, so a loaded machine that fires
            // the timer less often still passes. A read in flight as `stop()` runs may record nothing.
            let calls = source.callCount
            #expect(calls >= 6, "\(calls) reads in \(elapsed) s")
            #expect(points.count == (calls + 2) / 3 || points.count == (calls + 2) / 3 - 1, "\(points.count) points from \(calls) reads")
            // Never faster than the sample rate.
            #expect(Double(calls) <= elapsed * CursorRecorder.sampleRate * 1.1 + 2, "\(calls) reads in \(elapsed) s")
            for (a, b) in zip(points, points.dropFirst()) {
                #expect(a != b)
            }
        }
    }

    @Test func noEventsAreAppendedAfterStop() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("events.jsonl")
            let log = try EventLogWriter(url: url)
            let source = SteppingLocation()
            let recorder = CursorRecorder(clock: HostTime.now, location: { source.next() })
            await recorder.start(log: log)
            try await Task.sleep(for: .milliseconds(100))
            await recorder.stop()
            try log.flush()
            let before = try EventLogReader.read(url).events.count
            try await Task.sleep(for: .milliseconds(100))
            try log.flush()
            #expect(try EventLogReader.read(url).events.count == before)
            try log.close()
        }
    }

    @Test func pauseStopsSamplingAndResumeStartsAgain() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("events.jsonl")
            let log = try EventLogWriter(url: url)
            let source = SteppingLocation()
            let recorder = CursorRecorder(clock: HostTime.now, location: { source.next() })
            await recorder.start(log: log)
            try await Task.sleep(for: .milliseconds(100))
            await recorder.pause()
            await recorder.pause()  // idempotent
            try log.flush()
            let beforePause = try EventLogReader.read(url).events.count
            try await Task.sleep(for: .milliseconds(150))
            try log.flush()
            #expect(beforePause > 0)
            #expect(try EventLogReader.read(url).events.count == beforePause)
            await recorder.resume()
            await recorder.resume()  // idempotent: one timer, not two
            try await Task.sleep(for: .milliseconds(100))
            await recorder.stop()
            try log.close()
            #expect(try EventLogReader.read(url).events.count > beforePause)
        }
    }

    @Test func mapsMouseEventsToInputEvents() {
        let p = CGPoint(x: 12, y: 34)
        let ts = 5.0
        let t = HostTime(eventTimestamp: ts)
        #expect(CursorRecorder.inputEvent(type: .leftMouseDown, buttonNumber: 0, location: p, timestamp: ts)
            == InputEvent(t: t, kind: .mouseDown(.left, x: 12, y: 34)))
        #expect(CursorRecorder.inputEvent(type: .leftMouseUp, buttonNumber: 0, location: p, timestamp: ts)
            == InputEvent(t: t, kind: .mouseUp(.left, x: 12, y: 34)))
        #expect(CursorRecorder.inputEvent(type: .rightMouseDown, buttonNumber: 1, location: p, timestamp: ts)
            == InputEvent(t: t, kind: .mouseDown(.right, x: 12, y: 34)))
        #expect(CursorRecorder.inputEvent(type: .rightMouseUp, buttonNumber: 1, location: p, timestamp: ts)
            == InputEvent(t: t, kind: .mouseUp(.right, x: 12, y: 34)))
        #expect(CursorRecorder.inputEvent(type: .otherMouseDown, buttonNumber: 2, location: p, timestamp: ts)
            == InputEvent(t: t, kind: .mouseDown(.other, x: 12, y: 34)))
        #expect(CursorRecorder.inputEvent(type: .otherMouseUp, buttonNumber: 3, location: p, timestamp: ts)
            == InputEvent(t: t, kind: .mouseUp(.other, x: 12, y: 34)))
        #expect(CursorRecorder.inputEvent(type: .mouseMoved, buttonNumber: 0, location: p, timestamp: ts) == nil)
        #expect(CursorRecorder.inputEvent(type: .keyDown, buttonNumber: 0, location: p, timestamp: ts) == nil)
    }
}
