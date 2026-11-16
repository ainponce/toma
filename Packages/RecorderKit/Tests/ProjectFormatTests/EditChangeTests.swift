// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the editor uses only the public API.
import ProjectFormat

private func ns(_ nanoseconds: UInt64) -> HostTime { HostTime(nanoseconds: nanoseconds) }

private func pointer(_ string: String) throws -> JSONPointer { try JSONPointer(string) }

private func value(_ encodable: some Encodable) throws -> JSONValue { try JSONValue(encoding: encodable) }

// MARK: - JSON values and pointers

@Test func pointerEscapesSlashAndTilde() throws {
    let path = try pointer("/audio/tracks/take-001~1mic/gain")
    #expect(path.components == ["audio", "tracks", "take-001/mic", "gain"])
    #expect(path.string == "/audio/tracks/take-001~1mic/gain")
    #expect(JSONPointer.escape("a~b/c") == "a~0b~1c")
    // `~01` is a tilde and a 1, never a slash: `~1` is unescaped before `~0`.
    #expect(try pointer("/a~01").components == ["a~1"])
    #expect(try pointer("").components == [])
    #expect(try pointer("/").components == [""])
    #expect(JSONPointer(components: ["take-001/mic", "a~b"]).string == "/take-001~1mic/a~0b")
    for bad in ["style", "/a~2", "/a~", "~0"] {
        #expect(throws: (any Error).self) { try JSONPointer(bad) }
    }
    let encoded = try JSONEncoder().encode(path)
    #expect(String(decoding: encoded, as: UTF8.self) == #""\/audio\/tracks\/take-001~1mic\/gain""#)
    #expect(try JSONDecoder().decode(JSONPointer.self, from: encoded) == path)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(JSONPointer.self, from: Data(#""style""#.utf8)) }
}

@Test func integersAreReadExactly() throws {
    let text = #"[1, -3, 1.0, 9007199254740993, 18446744073709551615, 0.1, 2.5e300, true, null, "x", {"a": []}]"#
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let expected: [JSONValue] = [
        .integer(1), .integer(-3), .integer(1), .integer(9_007_199_254_740_993), .unsigned(.max), .number(0.1), .number(2.5e300),
        .bool(true), .null, .string("x"), .object(["a": .array([])]),
    ]
    // Each case on its own, not through `==`, which compares numbers across cases.
    #expect(identical(decoded, .array(expected)), "\(decoded)")
    #expect(identical(try value(HostTime(nanoseconds: (1 << 60) + 1)), .integer((1 << 60) + 1)))
    #expect(identical(try value(UInt64.max), .unsigned(.max)))
    #expect(identical(try value(0.1), .number(0.1)))
    #expect(try JSONValue.integer((1 << 60) + 1).decoded(as: HostTime.self) == ns((1 << 60) + 1))
    #expect(try JSONValue.unsigned(.max).decoded(as: HostTime.self) == ns(.max))
    #expect(try JSONValue.number(2).decoded(as: Int.self) == 2)
    #expect(throws: (any Error).self) { try value(Double.nan) }
}

/// Whether `a` and `b` hold the same cases with the same payloads, unlike `==`, which compares numbers across cases.
private func identical(_ a: JSONValue, _ b: JSONValue) -> Bool {
    switch (a, b) {
    case let (.array(x), .array(y)):
        x.count == y.count && zip(x, y).allSatisfy(identical)
    case let (.object(x), .object(y)):
        x.keys.sorted() == y.keys.sorted() && x.allSatisfy { key, value in y[key].map { identical(value, $0) } ?? false }
    default:
        "\(a)" == "\(b)"
    }
}

@Test func bothReadingsGiveTheSameCases() throws {
    // `init(encoding:)` reads with `JSONSerialization`; the values of a log line are read with `init(from:)`.
    var document = DesignExample.document
    document.sequence[0].start = ns((1 << 60) + 1)
    document.sequence[0].end = ns(.max)
    document.style.padding = -0.0
    document.style.shadow = 1e-7
    let values: [any Encodable] = [
        document, [1.0, 100, 2.5, 1e19, 1e20, -1, 0, -0.0, 0.1], [Int64.min, Int64.max], UInt64.max, true, "x/y", [String: Int](),
    ]
    for value in values {
        let serialized = try JSONValue(encoding: value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(identical(serialized, decoded), "\(serialized) and \(decoded)")
    }
    #expect(identical(try JSONValue(encoding: [1e19, 1e20]), .array([.unsigned(10_000_000_000_000_000_000), .number(1e20)])))
}

@Test func integersCompareAsIntegers() {
    // Through a `Double`, 2⁵³ + 1 would be 2⁵³.
    #expect(JSONValue.integer(9_007_199_254_740_993) != .integer(9_007_199_254_740_992))
    #expect(JSONValue.integer(9_007_199_254_740_993) != .number(9_007_199_254_740_992))
    // `UInt64.max` as a `Double` is 2⁶⁴.
    #expect(JSONValue.unsigned(.max) != .number(0x1p64))
    // The same number, whatever the case holds it.
    #expect(JSONValue.integer(5) == .unsigned(5))
    #expect(JSONValue.integer(1) == .number(1))
    #expect(JSONValue.integer(0) == .number(-0.0))
    #expect(JSONValue.number(0.5) == .number(0.5))
    #expect(JSONValue.integer(-1) != .unsigned(.max))
    #expect(JSONValue.integer(1) != .number(1.5))
    #expect(JSONValue.integer(1) != .string("1"))
    #expect(JSONValue.bool(true) != .integer(1))
    #expect(JSONValue.object(["a": .integer(1)]) == .object(["a": .number(1)]))
    #expect(JSONValue.array([.integer(1)]) != .array([.integer(1), .null]))
}

// MARK: - Changes

@Test func everyChangeIsUndoneByItsInverse() throws {
    let original = DesignExample.document
    var clip = original.sequence[0]
    clip.end = ns(81_250_000_000_000)
    let suppressed = SourceRange(take: "take-001", start: ns(81_330_000_000_000), end: ns(81_331_000_000_000))
    let changes = [
        try #require(original.setChange("/style/padding", 0.1)),
        try #require(original.setChange("/audio/tracks/take-001~1mic/gain", 1.5)),
        try #require(original.setChange("/style/background", Background.tomaClassic)),
        original.insertChange(.zoomSuppressed, at: 1, suppressed),
        try #require(original.removeChange(.zoomRegions, at: 0)),
        try #require(original.replaceChange(.sequence, id: "c-00a1b2c3", with: clip)),
    ]
    for change in changes {
        let changed = try original.applying([change])
        #expect(changed != original)
        #expect(try changed.applying([change.inverse]) == original)
        #expect(try original.applying([change, change.inverse]) == original)
        #expect(change.inverse.inverse == change)
    }

    let changed = try original.applying(changes)
    #expect(changed.style.padding == 0.1)
    #expect(changed.audio.tracks["take-001/mic"] == TrackGain(gain: 1.5, muted: false))
    #expect(changed.style.background == .tomaClassic)
    #expect(changed.zoom.suppressed == [original.zoom.suppressed[0], suppressed])
    #expect(changed.zoom.regions == [original.zoom.regions[1]])
    #expect(changed.sequence == [clip, original.sequence[1]])
    // A list is undone by the inverses of its changes, from the last to the first.
    #expect(try changed.applying(changes.reversed().map(\.inverse)) == original)
}

@Test func constructorsGiveNilWhenNothingChanges() throws {
    let document = DesignExample.document
    #expect(document.setChange("/style/padding", 0.08) == nil)
    #expect(document.setChange("/style/nothing", 1) == nil)
    #expect(document.setChange("/sequence/2/end", ns(1)) == nil)
    #expect(document.setChange("style/padding", 0.1) == nil)
    #expect(document.setChange("/style/padding", Double.nan) == nil)
    #expect(document.removeChange(.zoomRegions, at: 2) == nil)
    #expect(document.removeChange(.zoomRegions, at: -1) == nil)
    #expect(document.replaceChange(.zoomRegions, id: "z-3fa2b1c0", with: document.zoom.regions[0]) == nil)
    #expect(document.replaceChange(.zoomRegions, id: "z-ffffffff", with: document.zoom.regions[0]) == nil)
    // The element keeps its id: replacing it with another one is not a replace.
    #expect(document.replaceChange(.zoomRegions, id: "z-3fa2b1c0", with: document.zoom.regions[1]) == nil)

    #expect(document.setChange("/style/padding", 0.1) == .set(path: try pointer("/style/padding"), before: .number(0.08), after: .number(0.1)))
    #expect(try #require(document.removeChange(.cameraChanges, at: 0)) == .remove(
        collection: try pointer("/camera/changes"), index: 0, value: try value(document.camera.changes[0])))
    let change = ScreenChange(id: "p-00000002", take: "take-001", t: ns(81_300_000_000_000), track: "display-1", origin: .user)
    #expect(document.insertChange(.screenChanges, at: 1, change) == .insert(
        collection: try pointer("/screens/changes"), index: 1, value: try value(change)))
}

@Test func mismatchedBeforeIsRefused() throws {
    let document = DesignExample.document
    let padding = try pointer("/style/padding")
    #expect(throws: EditChangeError.mismatch("/style/padding")) {
        try document.applying([.set(path: padding, before: .number(0.07), after: .number(0.1))])
    }
    let suppressed = try pointer("/zoom/suppressed")
    let range = try value(SourceRange(take: "take-001", start: ns(1), end: ns(2)))
    #expect(throws: EditChangeError.indexOutOfRange("/zoom/suppressed", 2)) {
        try document.applying([.insert(collection: suppressed, index: 2, value: range)])
    }
    #expect(throws: EditChangeError.indexOutOfRange("/zoom/suppressed", -1)) {
        try document.applying([.insert(collection: suppressed, index: -1, value: range)])
    }
    #expect(throws: EditChangeError.noSuchID("/sequence", "c-ffffffff")) {
        try document.applying([.replace(collection: try pointer("/sequence"), id: "c-ffffffff", before: .null, after: .null)])
    }
    // `remove` checks what it removes, and `replace` what it replaces.
    #expect(throws: EditChangeError.mismatch("/zoom/suppressed/0")) {
        try document.applying([.remove(collection: suppressed, index: 0, value: range)])
    }
    #expect(throws: EditChangeError.indexOutOfRange("/zoom/suppressed", 1)) {
        try document.applying([.remove(collection: suppressed, index: 1, value: range)])
    }
    let regions = try pointer("/zoom/regions")
    let second = try value(document.zoom.regions[1])
    #expect(throws: EditChangeError.mismatch("/zoom/regions/0")) {
        try document.applying([.replace(collection: regions, id: "z-3fa2b1c0", before: second, after: second)])
    }
    // An `after` with another id could not be found again by its inverse.
    let first = try value(document.zoom.regions[0])
    #expect(throws: EditChangeError.mismatch("/zoom/regions/0")) {
        try document.applying([.replace(collection: regions, id: "z-3fa2b1c0", before: first, after: second)])
    }
    #expect(throws: EditChangeError.noSuchPath("/style/nothing")) {
        try document.applying([.set(path: try pointer("/style/nothing"), before: .null, after: .integer(1))])
    }
    #expect(throws: EditChangeError.noSuchPath("/style/padding/x")) {
        try document.applying([.set(path: try pointer("/style/padding/x"), before: .null, after: .integer(1))])
    }
    #expect(throws: EditChangeError.noSuchPath("/sequence/01")) {
        try document.applying([.set(path: try pointer("/sequence/01"), before: .null, after: .integer(1))])
    }
    #expect(throws: EditChangeError.noSuchPath("/style")) {
        try document.applying([.insert(collection: try pointer("/style"), index: 0, value: range)])
    }
    // A list that fails at its second change changes nothing: `applying` returns a new value or throws.
    #expect(throws: EditChangeError.mismatch("/style/padding")) {
        try document.applying([
            .set(path: padding, before: .number(0.08), after: .number(0.1)),
            .set(path: padding, before: .number(0.08), after: .number(0.2)),
        ])
    }
}

@Test func changeThatBreaksTheDocumentIsInvalid() throws {
    let document = DesignExample.document
    let aspect = EditChange.set(path: try pointer("/aspect"), before: .string("16:9"), after: .string("4:3"))
    #expect(throws: EditChangeError.invalidDocument("/aspect")) { try document.applying([aspect]) }
    // `JSONValue` knows nothing of the document.
    let json = try value(document)
    let changed = try json.applying([aspect])
    #expect(changed != json)
    #expect(try changed.applying([aspect.inverse]) == json)

    let speed = EditChange.set(path: try pointer("/sequence/1/speed"), before: .integer(2), after: .string("fast"))
    #expect(throws: EditChangeError.invalidDocument("/sequence/1/speed")) { try document.applying([speed]) }
    // What the document has no place for would be dropped on decoding, and its inverse would no longer match.
    var region = try value(document.zoom.regions[0])
    if case var .object(members) = region {
        members["extra"] = .bool(true)
        region = .object(members)
    }
    #expect(throws: EditChangeError.invalidDocument("/zoom/regions/2/extra")) {
        try document.applying([.insert(collection: try pointer("/zoom/regions"), index: 2, value: region)])
    }
    let depth = EditChange.set(path: try pointer("/zoom/regions/1/depth"), before: .number(1.6), after: .null)
    #expect(throws: EditChangeError.invalidDocument("/zoom/regions/1/depth")) { try document.applying([depth]) }
    // A value that can't be encoded (a non-finite number) can't be in the document: its insert is refused.
    var broken = document.zoom.regions[0]
    broken.focus = .fixed(x: .nan, y: 0)
    let insert = document.insertChange(.zoomRegions, at: 0, broken)
    #expect(throws: EditChangeError.invalidDocument("/zoom/regions/0")) { try document.applying([insert]) }
}

@Test func numbersPrintExactly() throws {
    let document = DesignExample.document
    let end = try #require(document.setChange("/sequence/0/end", ns(9_007_199_254_740_993)))
    let padding = try #require(document.setChange("/style/padding", 0.1))
    let entry = EditLogEntry.do(seq: 2, group: 2, label: "trim", changes: [end, padding], at: Date(timeIntervalSince1970: 1_763_237_523))
    let line = try entry.jsonLine()
    #expect(line.contains(#"{"after":9007199254740993,"before":81276901234567,"op":"set","path":"/sequence/0/end"}"#))
    #expect(line.contains(#"{"after":0.1,"before":0.08,"op":"set","path":"/style/padding"}"#))
    #expect(try EditLogEntry(jsonLine: line) == entry)
    let changed = try document.applying([end, padding])
    #expect(changed.sequence[0].end == ns(9_007_199_254_740_993))
    #expect(changed.style.padding == 0.1)
}

@Test func hostTimesAbove2To53RoundTrip() throws {
    var document = DesignExample.document
    document.sequence[0].start = ns((1 << 60) + 1)
    let padding = try #require(document.setChange("/style/padding", 0.1))
    #expect(try document.applying([padding, padding.inverse]) == document)
    #expect(try document.applying([padding]).sequence[0].start == ns((1 << 60) + 1))
    var clip = document.sequence[0]
    clip.end = ns(.max)
    let replace = try #require(document.replaceChange(.sequence, id: clip.id, with: clip))
    #expect(try document.applying([replace]).sequence[0].end == ns(.max))
    #expect(try document.applying([replace, replace.inverse]) == document)

    let create = EditLogEntry.create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.2.0"))
    let line = try create.jsonLine()
    #expect(line.contains(#""start":1152921504606846977"#))
    #expect(try EditLogEntry(jsonLine: line) == create)
}
