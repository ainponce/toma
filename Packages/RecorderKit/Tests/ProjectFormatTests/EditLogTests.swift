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
        documentVersion: EditDocument.currentVersion,
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

    static let json = #"{"aspect":"16:9","audio":{"limiter":false,"tracks":{}},"camera":{"border":{"color":[1,1,1,1],"width":0},"#
        + #""changes":[],"initial":{},"layout":{"kind":"bubble"},"layoutRules":"cameraLayout-1","layouts":[],"mirror":false,"#
        + #""shadow":0,"show":true,"sizeReference":"height","spring":{"damping":0.95,"response":0.5}},"#
        + #""cursor":{"clickEffect":"none","clickSound":"none","clickSoundGain":0.5,"hideWhenIdle":false,"idleDelay":2,"#
        + #""motionBlur":0,"scale":1,"show":true,"smoothing":"off","style":"toma"},"documentVersion":2,"frameRate":60,"#
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
        let newer = line.replacingOccurrences(of: #""documentVersion":2"#, with: #""documentVersion":3"#)
        #expect(newer != line)
        #expect(throws: EditDocumentError.newerVersion(3)) { try EditLogEntry(jsonLine: newer) }
        // Thrown, never read as damage, which would be repaired: a newer app wrote it.
        try Data((newer + "\n").utf8).write(to: url)
        #expect(throws: EditDocumentError.newerVersion(3)) { try EditLogReader.read(url) }

        // The same for a `migrate` to a newer documentVersion; one to this app's is a line like any other (followed by
        // one: a `migrate` the entries end with is a first edit cut short, left out).
        let padding = try doLine(2, group: 2, try set("/style/padding", 0.08, 0.1)).jsonLine()
        let undo = try EditLogEntry.undo(seq: 4, group: 2).jsonLine()
        for (to, refused) in [(3, true), (2, false)] {
            let migrate = try EditLogEntry.migrate(seq: 3, from: 2, to: to).jsonLine()
            try Data([line, padding, migrate, undo].map { $0 + "\n" }.joined().utf8).write(to: url)
            if refused {
                #expect(throws: EditDocumentError.newerVersion(3)) { try EditLogReader.read(url) }
            } else {
                #expect(try EditLogReader.read(url).entries.count == 4)
            }
        }
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
        // A migrate that does not follow (`DocumentMigration.follows`): from 1, after a create of version 2.
        ("a migrate", [create, padding, .migrate(seq: 3, from: 1, to: 2)], at(2, padded), 3),
    ]
    for (name, entries, document, mismatch) in cases {
        let replayed = try replay(entries)
        #expect(replayed.document == document, "\(name)")
        #expect(replayed.mismatchSeq == mismatch, "\(name)")
        #expect(replayed.lastAppliedSeq == document.logSequence, "\(name)")
    }

    // Nothing before a migrate that does not follow can be undone, even from a snapshot taken after it.
    let migrated = [create, padding, .migrate(seq: 3, from: 1, to: 1), .undo(seq: 4, group: 2)]
    let afterMigrate = try replay(migrated, from: at(3, padded))
    #expect(afterMigrate.document == at(3, padded))
    #expect(afterMigrate.mismatchSeq == 4)
}

@Test func aDoOfAnUndoneGroupBeforeTheStartChangesNothing() throws {
    // A line the app never writes: before the start lines are not checked, and one that does not follow is not kept.
    let start = DesignExample.document
    let entries: [EditLogEntry] = [
        .create(seq: 1, document: start, app: app),
        doLine(2, group: 2, try set("/style/padding", 0.08, 0.1)),
        .undo(seq: 3, group: 2),
        doLine(4, group: 2, try set("/style/shadow", 0.6, 0.5)),
        .redo(seq: 5, group: 2),
    ]
    var snapshot = start
    snapshot.style.shadow = 0.5
    var expected = snapshot
    expected.style.padding = 0.1
    // The redo applies the padding alone: with the shadow too, its `before` (0.6) would not match.
    let replayed = try replay(entries, from: at(4, snapshot))
    #expect(replayed.mismatchSeq == nil)
    #expect(replayed.document == at(5, expected))
}

@Test func sessionAndReplayAgreeOnLongDecimals() throws {
    try withTemporaryDirectory { dir in
        // Three steps through the public API, as a session takes them, each reading the document again.
        var document = DesignExample.document
        document.zoom.regions[1].focus = .fixed(x: 7.0 / 267, y: 1.0 / 86)
        let created = document
        let padding = try #require(document.setChange("/style/padding", 0.1))
        document = try document.applying([padding])
        let shadow = try #require(document.setChange("/style/shadow", 0.5))
        document = try document.applying([shadow])
        var region = document.zoom.regions[1]
        region.depth = 1.7
        let depth = try #require(document.replaceChange(.zoomRegions, id: region.id, with: region))
        document = try document.applying([depth])

        let entries: [EditLogEntry] = [
            .create(seq: 1, document: created, app: app),
            .do(seq: 2, group: 2, label: "style.padding", changes: [padding], at: date),
            .do(seq: 3, group: 3, label: "style.shadow", changes: [shadow], at: date),
            .do(seq: 4, group: 4, label: "zoom.change", changes: [depth], at: date),
        ]
        let url = dir.appending(path: "edit-log.jsonl")
        try Data(try entries.map { try $0.jsonLine() + "\n" }.joined().utf8).write(to: url)
        let replayed = try replay(try EditLogReader.read(url).entries)
        #expect(replayed.mismatchSeq == nil)
        #expect(replayed.lastAppliedSeq == 4)
        #expect(replayed.document == at(4, document))
        #expect(try canonical(replayed.document) == canonical(at(4, document)))
        #expect(replayed.document.zoom.regions[1].focus == .fixed(x: 7.0 / 267, y: 1.0 / 86))
    }
}

@Test func randomDoublesInvertAndReplayExactly() throws {
    let values = randomDoubles(600, seed: 17)
    for index in stride(from: 0, to: values.count, by: 2) {
        var document = DesignExample.document
        document.zoom.regions[1].focus = .fixed(x: values[index], y: 0.5)
        let change = try #require(document.setChange("/style/padding", values[index + 1]))
        let changed = try document.applying([change])
        #expect(changed.zoom.regions[1].focus == .fixed(x: values[index], y: 0.5), "x = \(values[index])")
        #expect(changed.style.padding.bitPattern == values[index + 1].bitPattern, "padding = \(values[index + 1])")
        #expect(try canonical(changed.applying([change.inverse])) == canonical(document), "x = \(values[index])")
        // Through the lines, as the log holds them.
        let entries = try [EditLogEntry.create(seq: 1, document: document, app: app), doLine(2, group: 2, change)].map {
            try EditLogEntry(jsonLine: $0.jsonLine())
        }
        let replayed = try replay(entries)
        #expect(replayed.mismatchSeq == nil, "x = \(values[index])")
        #expect(try canonical(replayed.document) == canonical(at(2, changed)), "x = \(values[index])")
    }
}

@Test func aBrokenLineInALongLogIsFoundBySeq() throws {
    // The lines are applied to the JSON and the document is decoded once at the end; when the end is no document, the
    // first line that left none is found, among 300.
    let start = DesignExample.document
    func padding(_ k: Int) -> Double { 0.08 + Double(k) / 10_000 }
    /// Padding lines, each from the padding the one before left, with `change` at `broken` (and `repair` after it).
    func log(breakingAt broken: Int, with change: EditChange, repairedBy repair: EditChange? = nil) throws -> [EditLogEntry] {
        var entries: [EditLogEntry] = [.create(seq: 1, document: start, app: app)]
        var steps = 0
        for seq in 2...301 {
            if seq == broken {
                entries.append(doLine(seq, group: seq, change))
            } else if seq == broken + 1, let repair {
                entries.append(doLine(seq, group: seq, repair))
            } else {
                entries.append(doLine(seq, group: seq, try set("/style/padding", padding(steps), padding(steps + 1))))
                steps += 1
            }
        }
        return entries
    }
    let aspect = EditChange.set(path: try JSONPointer("/aspect"), before: .string("16:9"), after: .string("4:3"))
    var region = try JSONValue(encoding: start.zoom.regions[0])
    if case var .object(members) = region {
        members["extra"] = .bool(true)
        region = .object(members)
    }
    let lossy = EditChange.insert(collection: try JSONPointer("/zoom/regions"), index: 2, value: region)
    for (broken, change) in [(157, aspect), (2, aspect), (301, lossy), (200, lossy)] {
        // Every line matches what is there: only the document after `broken` is none.
        let replayed = try replay(log(breakingAt: broken, with: change))
        var expected = start
        expected.style.padding = padding(broken - 2)
        #expect(replayed.mismatchSeq == broken)
        #expect(replayed.lastAppliedSeq == broken - 1)
        #expect(replayed.document == at(broken - 1, expected), "broken at \(broken)")
    }
    // A line whose damage the next line undoes is not found: the document is checked at the end.
    let repaired = try replay(log(breakingAt: 100, with: aspect, repairedBy: aspect.inverse))
    #expect(repaired.mismatchSeq == nil)
    #expect(repaired.document.aspect == .landscape)
    #expect(repaired.lastAppliedSeq == 301)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func largeDocumentReplaysItsTailFast() throws {
    // The review's document: 400 zooms with a fixed focus and 100 clips, about 147 KB indented (design §7.9 takes 1 h,
    // 500 clips and 300 zooms as its reference).
    var big = DesignExample.document
    let origin: UInt64 = 81_000_000_000_000
    // Random ids, as the format makes them: some start with `0` (`z-0a…`), like a `-0` written in the text.
    let zoomIDs = randomIDs(400, prefix: "z-", seed: 400)
    let clipIDs = randomIDs(100, prefix: "c-", seed: 100)
    big.zoom.regions = []
    for i in 0..<400 {
        let start = origin + UInt64(i) * 9_000_000_000
        let focus = ZoomFocus.fixed(x: Double(i % 97) / 97, y: Double(i % 89) / 89)
        big.zoom.regions.append(ZoomRegion(
            id: zoomIDs[i], take: "take-001", start: ns(start), end: ns(start + 4_000_000_000), origin: .auto,
            focus: focus, instant: false))
    }
    big.sequence = []
    for i in 0..<100 {
        let start = origin + UInt64(i) * 36_000_000_000
        big.sequence.append(
            Clip(id: clipIDs[i], take: "take-001", start: ns(start), end: ns(start + 30_000_000_000), speed: 1))
    }
    let bytes = try ProjectJSON.encoder().encode(big).count
    var entries: [EditLogEntry] = [.create(seq: 1, document: big, app: app)]
    func padding(_ k: Int) -> Double { 0.08 + Double(k) / 10_000 }
    for seq in 2...2_001 {
        entries.append(doLine(seq, group: seq, try set("/style/padding", padding(seq - 2), padding(seq - 1))))
    }
    let clock = ContinuousClock()
    var snapshot = big
    snapshot.style.padding = padding(1_800)
    let started = clock.now
    let tail = try replay(entries, from: at(1_801, snapshot))
    let tailTime = clock.now - started
    #expect(tail.mismatchSeq == nil)
    #expect(tail.lastAppliedSeq == 2_001)
    #expect(tailTime < .seconds(1))

    let fullStart = clock.now
    let full = try replay(entries)
    let fullTime = clock.now - fullStart
    #expect(full.mismatchSeq == nil)
    #expect(full.document == tail.document)

    #expect(zoomIDs.contains { $0.hasPrefix("z-0") } && clipIDs.contains { $0.hasPrefix("c-0") })
    let encodeStart = clock.now
    for _ in 0..<20 { _ = try JSONValue(encoding: big) }
    print("BENCH one JSONValue(encoding:) \((clock.now - encodeStart) / 20)")
    let change = try #require(big.setChange("/style/shadow", 0.5))
    let applyStart = clock.now
    for _ in 0..<20 { _ = try big.applying([change]) }
    let applyTime = (clock.now - applyStart) / 20
    print("BENCH document \(bytes) bytes: replay of the 200-line tail \(tailTime), of 2,000 lines from create \(fullTime)")
    print("BENCH one applying \(applyTime)")

    // The review's read: 20,001 lines of the design example's log, sets and replaces of a clip.
    try withTemporaryDirectory { dir in
        let small = DesignExample.document
        var lines = [try EditLogEntry.create(seq: 1, document: small, app: app).jsonLine()]
        var clip = small.sequence[0]
        for i in 0..<20_000 {
            if i % 2 == 0 {
                lines.append(try doLine(i + 2, group: i + 2, try set("/style/padding", 0.08, 0.1)).jsonLine())
            } else {
                let before = try JSONValue(encoding: clip)
                clip.end = ns(clip.end.nanoseconds - 1)
                let replace = EditChange.replace(
                    collection: try JSONPointer("/sequence"), id: clip.id, before: before, after: try JSONValue(encoding: clip))
                lines.append(try doLine(i + 2, group: i + 2, replace).jsonLine())
            }
        }
        let url = dir.appending(path: "edit-log.jsonl")
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try data.write(to: url)
        let readStart = clock.now
        let read = try EditLogReader.read(url)
        print("BENCH read of \(read.entries.count) entries, \(data.count) bytes: \(clock.now - readStart)")
        #expect(read.entries.count == 20_001)
    }
}
