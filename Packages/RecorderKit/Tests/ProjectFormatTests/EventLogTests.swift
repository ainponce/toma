// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the recorder, recovery and render modules use only the public API.
import ProjectFormat

extension InputEvent {
    /// One event of every kind with its exact line, as documented in `docs/format/README.md`.
    static let documentedExamples: [(InputEvent, String)] = [
        (InputEvent(t: HostTime(nanoseconds: 123), kind: .cursor(x: 10.5, y: 20)),
         #"{"t":123,"type":"cursor","x":10.5,"y":20}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .mouseDown(.left, x: 1, y: 2)),
         #"{"button":"left","t":5,"type":"mouseDown","x":1,"y":2}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .mouseUp(.right, x: -1920, y: 340.25)),
         #"{"button":"right","t":5,"type":"mouseUp","x":-1920,"y":340.25}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 2)),
         #"{"displayID":1,"frame":{"height":982,"width":1512,"x":0,"y":0},"scale":2,"t":5,"type":"displayGeometry"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .segmentStarted(track: "display-1", index: 2)),
         #"{"index":2,"t":5,"track":"display-1","type":"segmentStarted"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .streamInterrupted(track: "display-1", domain: "SCStreamErrorDomain", code: -3821)),
         #"{"code":-3821,"domain":"SCStreamErrorDomain","t":5,"track":"display-1","type":"streamInterrupted"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .paused(reason: "screenLocked")),
         #"{"reason":"screenLocked","t":5,"type":"paused"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .resumed),
         #"{"t":5,"type":"resumed"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .deviceChanged(track: "mic", deviceUniqueID: "BuiltInMicrophoneDevice")),
         #"{"deviceUniqueID":"BuiltInMicrophoneDevice","t":5,"track":"mic","type":"deviceChanged"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .marker),
         #"{"t":5,"type":"marker"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .droppedSamples(track: "display-1", count: 12)),
         #"{"count":12,"t":5,"track":"display-1","type":"droppedSamples"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .audioClock(track: "mic", frame: 240_000)),
         #"{"frame":240000,"t":5,"track":"mic","type":"audioClock"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .windowGeometry(track: "window-4242", frame: Rect(x: 100, y: 80, width: 800, height: 600), onScreen: true)),
         #"{"frame":{"height":600,"width":800,"x":100,"y":80},"onScreen":true,"t":5,"track":"window-4242","type":"windowGeometry"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .cameraStyle(CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .topLeading))),
         #"{"style":{"anchor":"topLeading","shape":"landscape","size":0.17},"t":5,"type":"cameraStyle"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .cursorImage(
            hash: "3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e", hotspot: SIMD2(0.16, 0.12), size: SIMD2(24, 32), kind: .arrow)),
         #"{"hash":"3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e","hotspot":{"x":0.16,"y":0.12},"kind":"arrow","size":{"height":32,"width":24},"t":5,"type":"cursorImage"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .scroll(dx: 0, dy: -42.5, x: 640.5, y: 402)),
         #"{"dx":0,"dy":-42.5,"t":5,"type":"scroll","x":640.5,"y":402}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .keyActivity),
         #"{"t":5,"type":"keyActivity"}"#),
        (InputEvent(t: HostTime(nanoseconds: 5), kind: .keyPress(code: 0, chars: "a", mods: 256, isRepeat: false)),
         #"{"chars":"a","code":0,"mods":256,"repeat":false,"t":5,"type":"keyPress"}"#),
    ]
}

private func marker(_ t: UInt64) -> InputEvent {
    InputEvent(t: HostTime(nanoseconds: t), kind: .marker)
}

private func line(_ event: InputEvent) throws -> String {
    try event.jsonLine() + "\n"
}

// MARK: - Line format

@Test(arguments: InputEvent.documentedExamples)
func lineFormatIsExact(event: InputEvent, line: String) throws {
    #expect(try event.jsonLine() == line)
    #expect(try InputEvent(jsonLine: line) == event)
}

@Test func documentedExamplesCoverEveryKind() throws {
    let types = try InputEvent.documentedExamples.map { example -> String in
        let object = try JSONSerialization.jsonObject(with: Data(example.1.utf8)) as? [String: Any]
        return try #require(object?["type"] as? String)
    }
    #expect(Set(types) == [
        "cursor", "mouseDown", "mouseUp", "displayGeometry", "segmentStarted",
        "streamInterrupted", "paused", "resumed", "deviceChanged", "marker", "droppedSamples", "audioClock",
        "windowGeometry", "cameraStyle", "cursorImage", "scroll", "keyActivity", "keyPress",
    ])
}

@Test func otherMouseButtonRoundTrips() throws {
    let event = InputEvent(t: HostTime(nanoseconds: 9), kind: .mouseDown(.other, x: 0.1, y: 0))
    let line = try event.jsonLine()
    #expect(line == #"{"button":"other","t":9,"type":"mouseDown","x":0.1,"y":0}"#)
    #expect(try InputEvent(jsonLine: line) == event)
}

@Test func stringsWithLineBreaksStayOnOneLine() throws {
    let event = InputEvent(t: HostTime(nanoseconds: 5), kind: .paused(reason: "line\nbreak\r\"quoted\" a/b"))
    let line = try event.jsonLine()
    #expect(!line.contains("\n") && !line.contains("\r"))
    #expect(line.contains("a/b"))
    #expect(try InputEvent(jsonLine: line) == event)
}

@Test func unknownTypeOrMissingFieldFailsToDecode() {
    #expect(throws: DecodingError.self) { try InputEvent(jsonLine: #"{"phase":1,"t":5,"type":"gesture"}"#) }
    #expect(throws: DecodingError.self) { try InputEvent(jsonLine: #"{"t":5,"type":"cursor","x":1}"#) }
    #expect(throws: DecodingError.self) { try InputEvent(jsonLine: #"{"dy":1,"t":5,"type":"scroll"}"#) }
    #expect(throws: DecodingError.self) {
        try InputEvent(jsonLine: #"{"hash":"3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e","hotspot":{"x":0.16},"size":{"height":32,"width":24},"t":5,"type":"cursorImage"}"#)
    }
    #expect(throws: DecodingError.self) { try InputEvent(jsonLine: #"{"type":"marker"}"#) }
}

@Test func cursorImageWithoutKindOmitsIt() throws {
    let line = #"{"hash":"00112233445566778899aabbccddeeff","hotspot":{"x":0.5,"y":0.5},"size":{"height":16,"width":16},"t":7,"type":"cursorImage"}"#
    let event = try InputEvent(jsonLine: line)
    #expect(event == InputEvent(t: HostTime(nanoseconds: 7), kind: .cursorImage(
        hash: "00112233445566778899aabbccddeeff", hotspot: SIMD2(0.5, 0.5), size: SIMD2(16, 16), kind: nil)))
    #expect(try event.jsonLine() == line)
    #expect(!(try event.jsonLine()).contains("kind"))
}

@Test func unknownCursorKindReadsAsAbsent() throws {
    // A shape a newer version knows: the line still counts, with the recorded image and no kind.
    let line = #"{"hash":"3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e","hotspot":{"x":0.16,"y":0.12},"kind":"resizeDiagonal","size":{"height":32,"width":24},"t":5,"type":"cursorImage"}"#
    let event = try InputEvent(jsonLine: line)
    guard case let .cursorImage(hash, hotspot, size, kind) = event.kind else {
        Issue.record("expected a cursorImage, got \(event)")
        return
    }
    #expect(event.t == HostTime(nanoseconds: 5))
    #expect(hash == "3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e")
    #expect(hotspot == SIMD2(0.16, 0.12))
    #expect(size == SIMD2(24, 32))
    #expect(kind == nil)
}

@Test func cursorKindsAreTheNineOfTheDesign() {
    #expect(CursorKind.allCases.map(\.rawValue) == [
        "arrow", "iBeam", "pointingHand", "openHand", "closedHand", "crosshair", "resizeLeftRight", "resizeUpDown",
        "notAllowed",
    ])
}

@Test func sortedByTimeKeepsFileOrderForEqualTimes() {
    func event(_ name: String, t: UInt64) -> InputEvent {
        InputEvent(t: HostTime(nanoseconds: t), kind: .paused(reason: name))
    }
    let a = event("a", t: 1), b = event("b", t: 2), c = event("c", t: 2)
    #expect([b, a, c].sortedByTime() == [a, b, c])
    #expect([c, a, b].sortedByTime() == [a, c, b])
}

@Test func nonFiniteNumberFailsToEncode() {
    #expect(throws: EncodingError.self) {
        try InputEvent(t: HostTime(nanoseconds: 1), kind: .cursor(x: .nan, y: 0)).jsonLine()
    }
    #expect(throws: EncodingError.self) {
        try InputEvent(t: HostTime(nanoseconds: 1), kind: .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: .infinity, height: 1), scale: 2)).jsonLine()
    }
}

// MARK: - Writer

@Test func writerIntervals() {
    #expect(EventLogWriter.flushInterval == .milliseconds(250))
    #expect(EventLogWriter.syncInterval == .seconds(2))
}

@Test func writerFlushesWithinInterval() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let writer = try EventLogWriter(url: url)
        writer.append(marker(1))
        try await Task.sleep(for: .milliseconds(400))
        let result = try EventLogReader.read(url)
        #expect(result.events == [marker(1)])
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"t":1,"type":"marker"}"# + "\n")
        try writer.close()
    }
}

@Test func explicitFlushWritesImmediately() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let writer = try EventLogWriter(url: url)
        writer.append(marker(1))
        writer.append(marker(2))
        try writer.flush()
        #expect(try EventLogReader.read(url).events == [marker(1), marker(2)])
        try writer.close()
    }
}

@Test func writerKeepsWritingAcrossSyncIntervals() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let writer = try EventLogWriter(url: url)
        for t in 0..<25 {
            writer.append(marker(UInt64(t)))
            try await Task.sleep(for: .milliseconds(100))
        }
        // At least 2 s of the 2.5 s are on disk without flush() or close().
        #expect(try EventLogReader.read(url).events.count >= 20)
        try writer.close()
        let result = try EventLogReader.read(url)
        #expect(result.events == (0..<25).map { marker(UInt64($0)) })
        #expect(result.skippedLines == 0 && !result.droppedTruncatedTail)
    }
}

@Test func closeIsIdempotentAndLaterAppendsAreIgnored() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let writer = try EventLogWriter(url: url)
        writer.append(marker(1))
        try writer.close()
        #expect(try EventLogReader.read(url).events == [marker(1)])
        try writer.close()
        writer.append(marker(2))
        try writer.flush()
        try writer.close()
        try await Task.sleep(for: .milliseconds(400))
        #expect(try String(contentsOf: url, encoding: .utf8) == (try line(marker(1))))
    }
}

@Test func concurrentAppendsKeepWholeLines() async throws {
    try await withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let writer = try EventLogWriter(url: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0..<8 {
                group.addTask {
                    for i in 0..<1000 {
                        writer.append(InputEvent(t: HostTime(nanoseconds: UInt64(task * 1000 + i)), kind: .cursor(x: Double(task), y: Double(i))))
                        if i % 100 == 99 { try writer.flush() }
                    }
                }
            }
            try await group.waitForAll()
        }
        try writer.close()

        let result = try EventLogReader.read(url)
        #expect(result.events.count == 8000)
        #expect(result.skippedLines == 0 && !result.droppedTruncatedTail)
        for task in 0..<8 {
            let ys = result.events.compactMap { event -> Double? in
                guard case let .cursor(x, y) = event.kind, x == Double(task) else { return nil }
                return y
            }
            #expect(ys == (0..<1000).map(Double.init), "task \(task) lost or reordered its events")
        }
    }
}

@Test func reopenedWriterAppendsToEarlierEvents() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let first = try EventLogWriter(url: url)
        first.append(marker(1))
        try first.close()
        let second = try EventLogWriter(url: url)
        second.append(marker(2))
        try second.close()
        #expect(try EventLogReader.read(url).events == [marker(1), marker(2)])
    }
}

@Test func writerReopenedAfterCrashStartsOnANewLine() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        try (#"{"t":1,"type":"marker"}"# + "\n" + #"{"t":2,"type":"cur"#).write(to: url, atomically: false, encoding: .utf8)
        let writer = try EventLogWriter(url: url)
        writer.append(marker(3))
        try writer.close()
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"t":1,"type":"marker"}"# + "\n" + #"{"t":3,"type":"marker"}"# + "\n")
        let result = try EventLogReader.read(url)
        #expect(result.events == [marker(1), marker(3)])
        #expect(result.skippedLines == 0 && !result.droppedTruncatedTail)
    }
}

@Test func writerReopenedAfterMissingNewlineKeepsTheLastEvent() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        try #"{"t":1,"type":"marker"}"#.write(to: url, atomically: false, encoding: .utf8)
        let writer = try EventLogWriter(url: url)
        writer.append(marker(2))
        try writer.close()
        #expect(try EventLogReader.read(url).events == [marker(1), marker(2)])
    }
}

@Test func droppedWriterIsReleasedAndKeepsItsEvents() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        weak var released: EventLogWriter?
        do {
            let writer = try EventLogWriter(url: url)
            released = writer
            writer.append(marker(1))
        }
        #expect(released == nil, "the flush timer must not keep the writer alive")
        #expect(try EventLogReader.read(url).events == [marker(1)])
    }
}

@Test func unencodableEventIsDroppedAndReportedOnce() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let writer = try EventLogWriter(url: url)
        writer.append(marker(1))
        writer.append(InputEvent(t: HostTime(nanoseconds: 2), kind: .cursor(x: .nan, y: 0)))
        writer.append(marker(3))
        #expect(throws: EncodingError.self) { try writer.flush() }
        #expect(try EventLogReader.read(url).events == [marker(1), marker(3)])
        try writer.flush()

        writer.append(InputEvent(t: HostTime(nanoseconds: 4), kind: .cursor(x: 0, y: .infinity)))
        #expect(throws: EncodingError.self) { try writer.close() }
        try writer.close()
        let result = try EventLogReader.read(url)
        #expect(result.events == [marker(1), marker(3)])
        #expect(result.skippedLines == 0 && !result.droppedTruncatedTail)
    }
}

@Test func writerNeedsAnExistingDirectory() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("missing/events.jsonl")
        let error = #expect(throws: POSIXError.self) { try EventLogWriter(url: url) }
        #expect(error?.code == .ENOENT)
    }
}

// MARK: - Reader

@Test func readerDropsTruncatedTail() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        try (#"{"t":1,"type":"marker"}"# + "\n" + #"{"t":2,"type":"cur"#).write(to: url, atomically: false, encoding: .utf8)
        let r = try EventLogReader.read(url)
        #expect(r.events.count == 1 && r.droppedTruncatedTail)
        #expect(r.events == [marker(1)] && r.skippedLines == 0)
        #expect(try EventLogReader.truncateIncompleteTail(url))
        #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix("}\n"))
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"t":1,"type":"marker"}"# + "\n")
        let again = try EventLogReader.read(url)
        #expect(again.events == [marker(1)] && !again.droppedTruncatedTail)
        #expect(try !EventLogReader.truncateIncompleteTail(url))
    }
}

struct BadLine: Sendable, CustomTestStringConvertible {
    var name: String
    var text: String
    var testDescription: String { name }
}

@Test(arguments: [
    BadLine(name: "garbage", text: "garbage{{"),
    BadLine(name: "unknown type", text: #"{"phase":1,"t":2,"type":"gesture"}"#),
    BadLine(name: "missing field", text: #"{"t":2,"type":"cursor","x":1}"#),
    BadLine(name: "empty line", text: ""),
    BadLine(name: "zeros left by a power loss", text: String(repeating: "\u{0}", count: 64)),
])
func undecodableMiddleLineIsSkipped(badLine: BadLine) async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let cursor = InputEvent(t: HostTime(nanoseconds: 3), kind: .cursor(x: 10.5, y: 20))
        try (line(marker(1)) + badLine.text + "\n" + line(cursor)).write(to: url, atomically: false, encoding: .utf8)
        let r = try EventLogReader.read(url)
        #expect(r.events == [marker(1), cursor])
        #expect(r.skippedLines == 1)
        #expect(!r.droppedTruncatedTail)
    }
}

@Test func lastLineThatOnlyLacksItsNewlineIsKept() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        let contents = try line(marker(1)) + #"{"t":2,"type":"resumed"}"#
        try contents.write(to: url, atomically: false, encoding: .utf8)
        let r = try EventLogReader.read(url)
        #expect(r.events == [marker(1), InputEvent(t: HostTime(nanoseconds: 2), kind: .resumed)])
        #expect(!r.droppedTruncatedTail && r.skippedLines == 0)
        #expect(try EventLogReader.truncateIncompleteTail(url))
        #expect(try String(contentsOf: url, encoding: .utf8) == contents + "\n")
    }
}

@Test func unknownEventTypeAtTailIsKeptNotTruncated() async throws {
    try withTemporaryDirectory { dir in
        // A whole line of a type a newer version writes, missing only its line break.
        let newer = #"{"phase":1,"t":2,"type":"gesture"}"#
        let contents = try line(marker(1)) + newer

        let url = dir.appendingPathComponent("events.jsonl")
        try contents.write(to: url, atomically: false, encoding: .utf8)
        let r = try EventLogReader.read(url)
        #expect(r.events == [marker(1)])
        #expect(r.skippedLines == 1 && !r.droppedTruncatedTail)
        #expect(try EventLogReader.truncateIncompleteTail(url))
        #expect(try String(contentsOf: url, encoding: .utf8) == contents + "\n")

        let reopened = dir.appendingPathComponent("reopened.jsonl")
        try contents.write(to: reopened, atomically: false, encoding: .utf8)
        let writer = try EventLogWriter(url: reopened)
        writer.append(marker(3))
        try writer.close()
        #expect(try String(contentsOf: reopened, encoding: .utf8) == contents + "\n" + (try line(marker(3))))
    }
}

@Test func truncateLeavesWholeLinesAlone() async throws {
    try withTemporaryDirectory { dir in
        let empty = dir.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        #expect(try !EventLogReader.truncateIncompleteTail(empty))
        #expect(try Data(contentsOf: empty).isEmpty)
        #expect(try EventLogReader.read(empty).events.isEmpty)

        let whole = dir.appendingPathComponent("whole.jsonl")
        let contents = try line(marker(1)) + line(marker(2))
        try contents.write(to: whole, atomically: false, encoding: .utf8)
        #expect(try !EventLogReader.truncateIncompleteTail(whole))
        #expect(try String(contentsOf: whole, encoding: .utf8) == contents)
    }
}

@Test func truncateFindsTheLineStartFarFromTheEnd() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        // A torn tail longer than one read chunk, after many whole lines.
        let lines = try (0..<5000).map { try line(marker(UInt64($0))) }.joined()
        try (lines + #"{"reason":""# + String(repeating: "x", count: 200_000)).write(to: url, atomically: false, encoding: .utf8)
        #expect(try EventLogReader.read(url).droppedTruncatedTail)
        #expect(try EventLogReader.truncateIncompleteTail(url))
        #expect(try String(contentsOf: url, encoding: .utf8) == lines)
    }
}

@Test func readingOrRepairingAMissingFileThrows() async throws {
    try withTemporaryDirectory { dir in
        let url = dir.appendingPathComponent("events.jsonl")
        #expect(throws: (any Error).self) { try EventLogReader.read(url) }
        let error = #expect(throws: POSIXError.self) { try EventLogReader.truncateIncompleteTail(url) }
        #expect(error?.code == .ENOENT)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
