// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the editor uses only the public API.
import ProjectFormat

// One rule for the edit log's last line (final review A-M3): reading it and making the file end at a line break agree on
// whether a last line without its line break is a whole JSON object, so the lines the session holds from the read are
// the lines in the file once it ends at a line break. A tail read as cut short is truncated away; a whole line that is not
// an entry is kept, as the damage the read stopped at.

@Test func theLogsLastLineIsReadAndTruncatedByOneRule() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        let document = EditDocument.legacy(
            take: TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: []),
            events: [])
        let create = try EditLogEntry.create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.2.0")).jsonLine()
        let undo = try EditLogEntry.undo(seq: 2, group: 1).jsonLine()
        // Cut short, whole but not an entry, and the numbers and escapes where `JSONSerialization` and the decoder the
        // log falls back to with a `-0` could read differently.
        let tails = [
            String(undo.dropLast()), undo, #"{"seq":2,"type":"undo","group":"#, #"{"a":-0,"b":1e-400}"#, #"{"a":1e-400}"#,
            #"{"a":-0,"b":1e400}"#, #"{"a":-0,"b":"\ud800"}"#, #"{"a":-0,"b":123456789012345678901234567890}"#, #"{"a":-0,}"#,
            #"{"a":-0,"b":"x"}garbage"#, #"{"a":-01}"#,
        ]
        for tail in tails {
            try Data((create + "\n" + tail).utf8).write(to: url)
            let read = try EditLogReader.read(url)
            let changed = try EditLogReader.truncateIncompleteTail(url)
            let after = try EditLogReader.read(url)
            #expect(changed, "\(tail)")
            #expect(after.entries == read.entries, "\(tail)")
            #expect(after.damagedLine == read.damagedLine, "\(tail)")
            #expect(!after.droppedTruncatedTail, "\(tail)")
            let kept = read.droppedTruncatedTail ? "" : tail + "\n"
            #expect(try SafeRead.regularFile(at: url) == Data((create + "\n" + kept).utf8), "\(tail)")
        }
    }
}
