// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the recorder and the render read key presses through the public API.
import ProjectFormat

@Test func keyPressLineIsExact() throws {
    let a = InputEvent(t: HostTime(nanoseconds: 5), kind: .keyPress(code: 0, chars: "a", mods: 256, isRepeat: false))
    let line = #"{"chars":"a","code":0,"mods":256,"repeat":false,"t":5,"type":"keyPress"}"#
    #expect(try a.jsonLine() == line)
    #expect(try InputEvent(jsonLine: line) == a)

    // A key that types nothing (an arrow, a function key) has no `chars`.
    let arrow = InputEvent(t: HostTime(nanoseconds: 7), kind: .keyPress(code: 123, chars: nil, mods: 0, isRepeat: true))
    let arrowLine = #"{"code":123,"mods":0,"repeat":true,"t":7,"type":"keyPress"}"#
    #expect(try arrow.jsonLine() == arrowLine)
    #expect(try InputEvent(jsonLine: arrowLine) == arrow)
    #expect(!(try arrow.jsonLine()).contains("chars"))

    // Every modifier bit and the highest key code come back as they were.
    let all = InputEvent(t: HostTime(nanoseconds: 9), kind: .keyPress(code: .max, chars: "é\n/\"", mods: .max, isRepeat: false))
    let allLine = try all.jsonLine()
    #expect(allLine.contains(#""mods":4294967295"#) && allLine.contains(#""code":65535"#))
    #expect(!allLine.contains("\n"))
    #expect(try InputEvent(jsonLine: allLine) == all)
}

@Test func keyIsWrittenOnlyWhenThereIsOneAndOldLinesReadWithoutIt() throws {
    // ⌘⇧4 on a keyboard where ⇧4 types "$": `chars` with ⇧, `key` with no modifier.
    let shifted = InputEvent(
        t: HostTime(nanoseconds: 6), kind: .keyPress(code: 21, chars: "$", mods: 0x12_0000, isRepeat: false, key: "4"))
    let line = #"{"chars":"$","code":21,"key":"4","mods":1179648,"repeat":false,"t":6,"type":"keyPress"}"#
    #expect(try shifted.jsonLine() == line)
    #expect(try InputEvent(jsonLine: line) == shifted)

    // A line recorded before `key` was written: read as it was, with no `key`, and written back the same.
    let old = #"{"chars":"$","code":21,"mods":1179648,"repeat":false,"t":6,"type":"keyPress"}"#
    let read = try InputEvent(jsonLine: old)
    #expect(read == InputEvent(t: HostTime(nanoseconds: 6), kind: .keyPress(code: 21, chars: "$", mods: 0x12_0000, isRepeat: false)))
    guard case .keyPress(_, _, _, _, let key) = read.kind else {
        Issue.record("not a key press")
        return
    }
    #expect(key == nil)
    #expect(try read.jsonLine() == old)

    // A key that types nothing has neither.
    let arrow = InputEvent(t: HostTime(nanoseconds: 7), kind: .keyPress(code: 123, chars: nil, mods: 0, isRepeat: false, key: nil))
    #expect(!(try arrow.jsonLine()).contains(#""key""#))
    // A `key` that is not text: not a key press this version wrote.
    #expect(throws: DecodingError.self) {
        try InputEvent(jsonLine: #"{"code":21,"key":4,"mods":0,"repeat":false,"t":6,"type":"keyPress"}"#)
    }
}

@Test func keyPressOutOfRangeOrIncompleteFailsToDecode() {
    // A code over 16 bits, negative modifiers, or a field missing: not a key press this version wrote.
    for line in [
        #"{"code":65536,"mods":0,"repeat":false,"t":5,"type":"keyPress"}"#,
        #"{"code":1,"mods":-1,"repeat":false,"t":5,"type":"keyPress"}"#,
        #"{"code":1,"mods":4294967296,"repeat":false,"t":5,"type":"keyPress"}"#,
        #"{"mods":0,"repeat":false,"t":5,"type":"keyPress"}"#,
        #"{"code":1,"repeat":false,"t":5,"type":"keyPress"}"#,
        #"{"code":1,"mods":0,"t":5,"type":"keyPress"}"#,
        #"{"code":1,"mods":0,"repeat":"no","t":5,"type":"keyPress"}"#,
    ] {
        #expect(throws: DecodingError.self, "\(line)") { try InputEvent(jsonLine: line) }
    }
}

@Test func onlyKeyPressNeedsFormatVersion4() throws {
    #expect(InputEvent.Kind.keyPress(code: 0, chars: nil, mods: 0, isRepeat: false).requiresFormatVersion4)
    // Every kind of version 3 and earlier, `keyActivity` included, stays readable by the app of phase 1.
    for (event, _) in InputEvent.documentedExamples {
        guard case .keyPress = event.kind else {
            #expect(!event.kind.requiresFormatVersion4, "\(event)")
            continue
        }
    }
}

@Test func keyPressesAreReadFromTheEventLog() throws {
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "events.jsonl")
        let events = [
            InputEvent(t: HostTime(nanoseconds: 1_000), kind: .keyActivity),
            InputEvent(t: HostTime(nanoseconds: 1_000), kind: .keyPress(code: 1, chars: "s", mods: 1 << 20, isRepeat: false)),
            InputEvent(t: HostTime(nanoseconds: 2_000), kind: .keyPress(code: 36, chars: "\r", mods: 0, isRepeat: false)),
        ]
        let writer = try EventLogWriter(url: url)
        for event in events { writer.append(event) }
        try writer.close()
        let read = try EventLogReader.read(url)
        #expect(read.events == events)
    }
}
