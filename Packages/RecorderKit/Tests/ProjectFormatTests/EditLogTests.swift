// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the editor uses only the public API.
import ProjectFormat

private func ns(_ nanoseconds: UInt64) -> HostTime { HostTime(nanoseconds: nanoseconds) }

private let app = AppInfo(name: "Toma", version: "0.2.0")

/// 2026-11-15T20:12:03Z, the date of the example of design §6.3.
private let date = Date(timeIntervalSince1970: 1_794_773_523)

private func set(_ path: String, _ before: Double, _ after: Double) throws -> EditChange {
    .set(path: try JSONPointer(path), before: .number(before), after: .number(after))
}

private func doLine(_ seq: Int, group: Int, _ changes: EditChange...) -> EditLogEntry {
    .do(seq: seq, group: group, label: "style.padding", changes: changes, at: date)
}

private func replay(_ entries: [EditLogEntry], from snapshot: EditDocument? = nil) throws -> EditReplay {
    try #require(EditReplay.replay(snapshot: snapshot, entries: entries))
}

/// `document` as it is after the line `seq` of the log: replay says which lines it includes.
private func at(_ seq: Int, _ document: EditDocument) -> EditDocument {
    var document = document
    document.logSequence = seq
    return document
}

/// A small document and its exact compact form, for the `create` line of design §6.3.
private enum SmallDocument {
    static let document = EditDocument(
        documentVersion: 1,
        logSequence: 0,
        aspect: .landscape,
        frameRate: 60,
        sequence: [Clip(id: "c-00000001", take: "take-001", start: ns(1_000), end: ns(2_000), speed: 1)],
        screens: ScreenPlan(initial: ["take-001": "display-1"], changes: []),
        style: StageStyle(
            background: .wallpaper("aurora-1"), backgroundBlur: 0, padding: 0.08, cornerRadius: 0.012, shadow: 0, frame: .none,
            screenSampling: .bilinear, geometryTransition: .none),
        cursor: CursorStyle(
            show: true, style: .toma, scale: 1, smoothing: .off, hideWhenIdle: false, idleDelay: 2, clickEffect: "none",
            clickSound: "none", clickSoundGain: 0.5, motionBlur: 0),
        zoom: ZoomPlan(
            show: true,
            auto: AutoZoomSettings(
                enabled: false, triggers: .clicks, holdWhileTyping: true, depth: 2, groupGap: 2.5, leadIn: 0.5, leadOut: 1,
                follow: true, planner: "autoZoom-1"),
            spring: SpringSpec(damping: 1, response: 0.7), motionBlur: 0, regions: [], suppressed: []),
        camera: CameraPlan(show: true, initial: [:], changes: []),
        audio: AudioPlan(limiter: false, tracks: [:]))

    static let json = #"{"aspect":"16:9","audio":{"limiter":false,"tracks":{}},"camera":{"changes":[],"initial":{},"show":true},"#
        + #""cursor":{"clickEffect":"none","clickSound":"none","clickSoundGain":0.5,"hideWhenIdle":false,"idleDelay":2,"#
        + #""motionBlur":0,"scale":1,"show":true,"smoothing":"off","style":"toma"},"documentVersion":1,"frameRate":60,"#
        + #""logSequence":0,"screens":{"changes":[],"initial":{"take-001":"display-1"}},"#
        + #""sequence":[{"end":2000,"id":"c-00000001","speed":1,"start":1000,"take":"take-001"}],"#
        + #""style":{"background":{"type":"wallpaper","wallpaper":"aurora-1"},"backgroundBlur":0,"cornerRadius":0.012,"#
        + #""frame":{"type":"none"},"geometryTransition":"none","padding":0.08,"screenSampling":"bilinear","shadow":0},"#
        + #""zoom":{"auto":{"depth":2,"enabled":false,"follow":true,"groupGap":2.5,"holdWhileTyping":true,"leadIn":0.5,"#
        + #""leadOut":1,"planner":"autoZoom-1","triggers":"clicks"},"motionBlur":0,"regions":[],"show":true,"#
        + #""spring":{"damping":1,"response":0.7},"suppressed":[]}}"#
}

// MARK: - Lines

@Test func documentedLinesAreExact() throws {
    let lines: [(EditLogEntry, String)] = [
        (.create(seq: 1, document: SmallDocument.document, app: app),
         #"{"app":{"name":"Toma","version":"0.2.0"},"document":"# + SmallDocument.json + #","seq":1,"type":"create"}"#),
        (.do(seq: 2, group: 2, label: "style.padding", changes: [try set("/style/padding", 0.08, 0.1)], at: date),
         #"{"at":"2026-11-15T20:12:03Z","changes":[{"after":0.1,"before":0.08,"op":"set","path":"/style/padding"}],"#
            + #""group":2,"label":"style.padding","seq":2,"type":"do"}"#),
        (.undo(seq: 3, group: 2), #"{"group":2,"seq":3,"type":"undo"}"#),
        (.redo(seq: 4, group: 2), #"{"group":2,"seq":4,"type":"redo"}"#),
    ]
    for (entry, line) in lines {
        #expect(try entry.jsonLine() == line)
        #expect(try EditLogEntry(jsonLine: line) == entry)
    }
    #expect(lines.map(\.0.seq) == [1, 2, 3, 4])
}

@Test func everyOpAndEntryHasItsLine() throws {
    let document = SmallDocument.document
    let range = SourceRange(take: "take-001", start: ns(5), end: ns(6))
    let rangeJSON = #"{"end":6,"start":5,"take":"take-001"}"#
    var trimmed = document.sequence[0]
    trimmed.end = ns(1_500)
    let changes: [(EditChange, String)] = [
        (document.insertChange(.zoomSuppressed, at: 0, range),
         #"{"collection":"/zoom/suppressed","index":0,"op":"insert","value":"# + rangeJSON + "}"),
        (.remove(collection: try JSONPointer("/zoom/suppressed"), index: 0, value: try JSONValue(encoding: range)),
         #"{"collection":"/zoom/suppressed","index":0,"op":"remove","value":"# + rangeJSON + "}"),
        (try #require(document.replaceChange(.sequence, id: "c-00000001", with: trimmed)),
         #"{"after":{"end":1500,"id":"c-00000001","speed":1,"start":1000,"take":"take-001"},"#
            + #""before":{"end":2000,"id":"c-00000001","speed":1,"start":1000,"take":"take-001"},"#
            + #""collection":"/sequence","id":"c-00000001","op":"replace"}"#),
        (try #require(document.setChange("/screens/initial/take-001", "display-2")),
         #"{"after":"display-2","before":"display-1","op":"set","path":"/screens/initial/take-001"}"#),
    ]
    for (change, json) in changes {
        let entry = EditLogEntry.do(seq: 7, group: 5, label: "zoom.delete", changes: [change], at: date)
        let line = try entry.jsonLine()
        #expect(line == #"{"at":"2026-11-15T20:12:03Z","changes":["# + json + #"],"group":5,"label":"zoom.delete","seq":7,"type":"do"}"#)
        #expect(try EditLogEntry(jsonLine: line) == entry)
    }
    let migrate = EditLogEntry.migrate(seq: 9, from: 1, to: 2)
    #expect(try migrate.jsonLine() == #"{"from":1,"seq":9,"to":2,"type":"migrate"}"#)
    #expect(try EditLogEntry(jsonLine: migrate.jsonLine()) == migrate)
    #expect(migrate.seq == 9)

    for bad in [
        "not json",
        #"{"seq":1,"type":"comment"}"#,
        #"{"group":2,"type":"undo"}"#,
        #"{"app":{"name":"Toma","version":"0.2.0"},"seq":1,"type":"create"}"#,
        #"{"at":"2026-11-15T20:12:03Z","changes":[{"op":"move","path":"/a"}],"group":2,"label":"x","seq":2,"type":"do"}"#,
        #"{"at":"2026-11-15T20:12:03Z","changes":[{"after":1,"op":"set","path":"/a"}],"group":2,"label":"x","seq":2,"type":"do"}"#,
        #"{"at":"2026-11-15T20:12:03Z","changes":[{"after":1,"before":0,"op":"set","path":"a"}],"group":2,"label":"x","seq":2,"type":"do"}"#,
    ] {
        #expect(throws: (any Error).self) { try EditLogEntry(jsonLine: bad) }
    }
}

@Test func dateIsWrittenToTheSecond() throws {
    let changes = [try set("/style/padding", 0.08, 0.1)]
    let entry = EditLogEntry.do(seq: 2, group: 2, label: "style.padding", changes: changes, at: date.addingTimeInterval(0.75))
    let line = try entry.jsonLine()
    #expect(line.contains(#""at":"2026-11-15T20:12:03Z""#))
    // The fraction does not come back: whoever builds a `do` truncates its date first (`roundedToWholeSeconds`).
    let read = try EditLogEntry(jsonLine: line)
    #expect(read != entry)
    #expect(read == .do(seq: 2, group: 2, label: "style.padding", changes: changes, at: date))
}

// MARK: - Reading

@Test func truncatingTheLastLineAtEveryByteGivesBeforeOrAfter() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        let start = DesignExample.document
        let region = ZoomRegion(
            id: "z-00c0ffee", take: "take-001", start: ns(81_310_000_000_000), end: ns(81_312_000_000_000), origin: .user, depth: 1.8,
            focus: .fixed(x: 0.25, y: 0.75), instant: true)
        let entries: [EditLogEntry] = [
            .create(seq: 1, document: start, app: app),
            doLine(2, group: 2, try set("/style/padding", 0.08, 0.1)),
            .undo(seq: 3, group: 2),
            .do(
                seq: 4, group: 4, label: "zoom.add",
                changes: [start.insertChange(.zoomRegions, at: 2, region), try set("/zoom/motionBlur", 0.5, 0.25)], at: date),
        ]
        let head = Array(try entries.dropLast().map { try $0.jsonLine() + "\n" }.joined().utf8)
        let last = Array(try entries[3].jsonLine().utf8) + [UInt8(ascii: "\n")]
        let before = try replay(Array(entries.dropLast())).document
        let after = try replay(entries).document
        #expect(before == at(3, start))
        #expect(after.zoom.regions.count == 3)
        #expect(after.zoom.motionBlur == 0.25)

        for length in 0...last.count {
            try Data(head + last.prefix(length)).write(to: url)
            let read = try EditLogReader.read(url)
            // Only the last line can be cut short; without its line break, a whole one still counts.
            let whole = length >= last.count - 1
            #expect(read.damagedLine == nil)
            #expect(read.droppedTruncatedTail == (length > 0 && !whole))
            let replayed = try replay(read.entries)
            #expect(replayed.mismatchSeq == nil)
            #expect(replayed.document == (whole ? after : before), "cut at \(length) of \(last.count) bytes")

            // Before more lines are appended, the file is made to end at a line break, keeping a whole last line.
            #expect(try EditLogReader.truncateIncompleteTail(url) == (length > 0 && length < last.count))
            #expect(try SafeRead.regularFile(at: url) == Data(head + (whole ? last : [])))
            #expect(try EditLogReader.read(url).entries == read.entries)
        }
    }
}

@Test func damagedMiddleLineStopsTheRead() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        let start = DesignExample.document
        let good: [EditLogEntry] = [
            .create(seq: 1, document: start, app: app),
            doLine(2, group: 2, try set("/style/padding", 0.08, 0.1)),
            doLine(3, group: 3, try set("/style/shadow", 0.6, 0.5)),
            doLine(4, group: 4, try set("/style/shadow", 0.5, 0.4)),
            .undo(seq: 5, group: 4),
        ]
        let lines = try good.map { try $0.jsonLine() }
        func write(_ lines: [String], lastBreak: Bool = true) throws {
            try Data((lines.joined(separator: "\n") + (lastBreak ? "\n" : "")).utf8).write(to: url)
        }

        // Whole lines that are not an entry that can follow the two before them: what comes after is not read.
        for damage in [
            "garbage", "", #"{"seq":3,"type":"comment"}"#, #"{"group":2,"seq":2,"type":"undo"}"#,
            try EditLogEntry.create(seq: 3, document: start, app: app).jsonLine(),
        ] {
            var damaged = lines
            damaged[2] = damage
            try write(damaged)
            let read = try EditLogReader.read(url)
            #expect(read.entries == Array(good.prefix(2)), "line 2 is \(damage)")
            #expect(read.damagedLine == 2)
            #expect(!read.droppedTruncatedTail)
        }

        // The first line is the create.
        try write(Array(lines.dropFirst()))
        let headless = try EditLogReader.read(url)
        #expect(headless.entries.isEmpty)
        #expect(headless.damagedLine == 0)

        // A whole last line without its line break that is not an entry is damaged, not cut short.
        try write(Array(lines.prefix(2)) + [#"{"seq":3,"type":"comment"}"#], lastBreak: false)
        let tail = try EditLogReader.read(url)
        #expect(tail.entries == Array(good.prefix(2)))
        #expect(tail.damagedLine == 2)
        #expect(!tail.droppedTruncatedTail)

        try write(lines)
        let read = try EditLogReader.read(url)
        #expect(read.entries == good)
        #expect(read.damagedLine == nil)
        #expect(!read.droppedTruncatedTail)

        try Data().write(to: url)
        let empty = try EditLogReader.read(url)
        #expect(empty.entries.isEmpty)
        #expect(empty.damagedLine == nil)
        #expect(!empty.droppedTruncatedTail)
    }
}

@Test func newerDocumentInTheLogIsRefused() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        let line = try EditLogEntry.create(seq: 1, document: DesignExample.document, app: app).jsonLine()
        let newer = line.replacingOccurrences(of: #""documentVersion":1"#, with: #""documentVersion":2"#)
        #expect(newer != line)
        #expect(throws: EditDocumentError.newerVersion(2)) { try EditLogEntry(jsonLine: newer) }
        // Thrown, never read as damage, which would be repaired: a newer app wrote it.
        try Data((newer + "\n").utf8).write(to: url)
        #expect(throws: EditDocumentError.newerVersion(2)) { try EditLogReader.read(url) }
    }
}

@Test func fifoLogIsRefusedQuickly() throws {
    try withTemporaryDirectory { dir in
        let fifo = dir.appending(path: "edit-log.jsonl")
        #expect(mkfifo(fifo.path, 0o644) == 0)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(throws: POSIXError(.EFTYPE)) { try EditLogReader.read(fifo) }
        #expect(throws: POSIXError(.EFTYPE)) { try EditLogReader.truncateIncompleteTail(fifo) }
        #expect(throws: POSIXError(.EFTYPE)) { try SafeRead.regularFile(at: fifo) }
        #expect(clock.now - started < .milliseconds(100))

        let target = dir.appending(path: "target.jsonl")
        let line = try EditLogEntry.create(seq: 1, document: SmallDocument.document, app: app).jsonLine() + "\n"
        try Data(line.utf8).write(to: target)
        let link = dir.appending(path: "link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: POSIXError(.ELOOP)) { try EditLogReader.read(link) }
        #expect(throws: POSIXError(.ELOOP)) { try EditLogReader.truncateIncompleteTail(link) }
        #expect(throws: POSIXError(.ELOOP)) { try SafeRead.regularFile(at: link) }
        #expect(throws: POSIXError(.EFTYPE)) { try SafeRead.regularFile(at: dir) }
        #expect(throws: POSIXError(.ENOENT)) { try SafeRead.regularFile(at: dir.appending(path: "missing")) }
        #expect(try EditLogReader.read(target).entries == [.create(seq: 1, document: SmallDocument.document, app: app)])
    }
}

@Test func safeReadReadsTheWholeFile() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit.json")
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: url)
        #expect(try SafeRead.regularFile(at: url) == bytes)
        try Data().write(to: url)
        #expect(try SafeRead.regularFile(at: url).isEmpty)
    }
}

// MARK: - Replay

@Test func replayAppliesTheTailAfterTheSnapshot() throws {
    let start = DesignExample.document
    let entries: [EditLogEntry] = [
        .create(seq: 1, document: start, app: app),
        doLine(2, group: 2, try set("/style/padding", 0.08, 0.09)),
        doLine(3, group: 3, try set("/style/cornerRadius", 0.012, 0.02)),
        doLine(4, group: 4, try set("/style/padding", 0.09, 0.1)),
        doLine(5, group: 5, try set("/style/shadow", 0.6, 0.3)),
    ]
    var snapshot = start
    snapshot.style.padding = 0.09
    snapshot.style.cornerRadius = 0.02
    snapshot.logSequence = 3
    // What no line touches tells the snapshot from a replay from `create`.
    snapshot.cursor.scale = 2
    var expected = snapshot
    expected.style.padding = 0.1
    expected.style.shadow = 0.3

    let tail = try replay(entries, from: snapshot)
    #expect(tail.document == at(5, expected))
    #expect(tail.lastAppliedSeq == 5)
    #expect(tail.mismatchSeq == nil)

    // Already up to date.
    let current = try replay(entries, from: tail.document)
    #expect(current.document == tail.document)
    #expect(current.lastAppliedSeq == 5)

    // A snapshot whose logSequence is not in the log: from `create`.
    snapshot.logSequence = 9
    expected.cursor.scale = start.cursor.scale
    let full = try replay(entries, from: snapshot)
    #expect(full.document == at(5, expected))
    #expect(full.lastAppliedSeq == 5)
    #expect(try replay(entries).document == at(5, expected))

    // Nothing to start from.
    #expect(EditReplay.replay(snapshot: nil, entries: []) == nil)
    #expect(EditReplay.replay(snapshot: snapshot, entries: []) == nil)
    #expect(EditReplay.replay(snapshot: nil, entries: Array(entries.dropFirst())) == nil)
}

@Test func replayUndoesAndRedoesGroups() throws {
    let start = DesignExample.document
    // One group of three lines, with two sets on the same path: undone in any other order than from the last to the
    // first, the `before` of one of them would not match.
    let entries: [EditLogEntry] = [
        .create(seq: 1, document: start, app: app),
        doLine(2, group: 2, try set("/style/padding", 0.08, 0.09)),
        doLine(3, group: 2, try set("/style/padding", 0.09, 0.1), try set("/style/shadow", 0.6, 0.5)),
        doLine(4, group: 2, try set("/style/shadow", 0.5, 0.4)),
        .undo(seq: 5, group: 2),
        .redo(seq: 6, group: 2),
        .undo(seq: 7, group: 2),
    ]
    var after = start
    after.style.padding = 0.1
    after.style.shadow = 0.4
    for (seq, expected) in [(4, after), (5, start), (6, after), (7, start)] {
        let replayed = try replay(entries.filter { $0.seq <= seq })
        #expect(replayed.document == at(seq, expected), "after line \(seq)")
        #expect(replayed.lastAppliedSeq == seq)
        #expect(replayed.mismatchSeq == nil)
    }

    // From a snapshot in the middle of the group, the undo still finds the lines of the group before it.
    var snapshot = start
    snapshot.style.padding = 0.1
    snapshot.style.shadow = 0.5
    snapshot.logSequence = 3
    #expect(try replay(Array(entries.prefix(5)), from: snapshot).document == at(5, start))
    #expect(try replay(entries, from: at(5, start)).document == at(7, start))
}

@Test func undoneGroupsReplayInTheCompactedOrder() throws {
    // Plan decision 4: compaction writes the do lines of the undone groups in the order they were done, then their undo
    // lines in reverse order.
    let start = DesignExample.document
    let entries: [EditLogEntry] = [
        .create(seq: 1, document: start, app: app),
        doLine(2, group: 2, try set("/style/padding", 0.08, 0.1)),
        doLine(3, group: 3, try set("/style/padding", 0.1, 0.2)),
        .undo(seq: 4, group: 3),
        .undo(seq: 5, group: 2),
    ]
    let undone = try replay(entries)
    #expect(undone.document == at(5, start))
    #expect(undone.mismatchSeq == nil)
    var redone = start
    redone.style.padding = 0.2
    let both = try replay(entries + [.redo(seq: 6, group: 2), .redo(seq: 7, group: 3)])
    #expect(both.document == at(7, redone))
    #expect(both.mismatchSeq == nil)
}

@Test func replayStopsAtTheFirstLineThatDoesNotMatch() throws {
    let start = DesignExample.document
    let create = EditLogEntry.create(seq: 1, document: start, app: app)
    let padding = doLine(2, group: 2, try set("/style/padding", 0.08, 0.1))
    var padded = start
    padded.style.padding = 0.1
    var shadowed = start
    shadowed.style.shadow = 0.1
    let cases: [(String, [EditLogEntry], EditDocument, Int)] = [
        ("a before that does not match",
         [create, padding, doLine(3, group: 3, try set("/style/padding", 0.08, 0.2)), doLine(4, group: 4, try set("/style/shadow", 0.6, 0.1))],
         at(2, padded), 3),
        ("a change that breaks the document",
         [create, padding, doLine(3, group: 3, .set(path: try JSONPointer("/aspect"), before: .string("16:9"), after: .string("4:3")))],
         at(2, padded), 3),
        ("an undo of a group that has no lines", [create, padding, .undo(seq: 3, group: 9)], at(2, padded), 3),
        ("an undo of a group already undone", [create, padding, .undo(seq: 3, group: 2), .undo(seq: 4, group: 2)], at(3, start), 4),
        ("a redo of a group that is not undone", [create, padding, .redo(seq: 3, group: 2)], at(2, padded), 3),
        ("a redo after a new group, which ends what could be redone",
         [create, padding, .undo(seq: 3, group: 2), doLine(4, group: 4, try set("/style/shadow", 0.6, 0.1)), .redo(seq: 5, group: 2)],
         at(4, shadowed), 5),
        ("a do of a group that is undone",
         [create, padding, .undo(seq: 3, group: 2), doLine(4, group: 2, try set("/style/shadow", 0.6, 0.1))], at(3, start), 4),
        ("a second create", [create, padding, .create(seq: 3, document: start, app: app)], at(2, padded), 3),
        // documentVersion 1 has no migrations: every migrate names a version this app does not know.
        ("a migrate", [create, padding, .migrate(seq: 3, from: 1, to: 2)], at(2, padded), 3),
    ]
    for (name, entries, document, mismatch) in cases {
        let replayed = try replay(entries)
        #expect(replayed.document == document, "\(name)")
        #expect(replayed.mismatchSeq == mismatch, "\(name)")
        #expect(replayed.lastAppliedSeq == document.logSequence, "\(name)")
    }

    // Nothing before a migrate can be undone, even from a snapshot taken after it.
    let migrated = [create, padding, .migrate(seq: 3, from: 1, to: 1), .undo(seq: 4, group: 2)]
    let afterMigrate = try replay(migrated, from: at(3, padded))
    #expect(afterMigrate.document == at(3, padded))
    #expect(afterMigrate.mismatchSeq == 4)
}
