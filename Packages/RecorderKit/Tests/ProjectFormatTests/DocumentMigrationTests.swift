// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// @testable for `ProjectJSON.compactEncoder()`, the encoder a `JSONValue` goes through.
@testable import ProjectFormat

private func ns(_ nanoseconds: UInt64) -> HostTime { HostTime(nanoseconds: nanoseconds) }

private func parsed(_ text: String) throws -> JSONValue {
    try ProjectJSON.decoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func compact(_ value: some Encodable) throws -> String {
    String(decoding: try ProjectJSON.compactEncoder().encode(value), as: UTF8.self)
}

private func pretty(_ value: some Encodable) throws -> String {
    String(decoding: try ProjectJSON.encoder().encode(value), as: UTF8.self)
}

extension JSONValue {
    /// The member `key` of an object; `nil` removes it. Reading or writing it on anything else does nothing.
    fileprivate subscript(key: String) -> JSONValue? {
        get {
            guard case let .object(members) = self else { return nil }
            return members[key]
        }
        set {
            guard case var .object(members) = self else { return }
            members[key] = newValue
            self = .object(members)
        }
    }

    /// The element `index` of an array.
    fileprivate subscript(index: Int) -> JSONValue? {
        get {
            guard case let .array(elements) = self, elements.indices.contains(index) else { return nil }
            return elements[index]
        }
        set {
            guard case var .array(elements) = self, elements.indices.contains(index), let newValue else { return }
            elements[index] = newValue
            self = .array(elements)
        }
    }
}

/// The example of `edit.json` of 1b design §6.2 as 1b wrote it, in `documentVersion` 1: `DesignExample.canonical` while
/// the document was at version 1, as it was.
enum DocumentV1Example {
    static let canonical = """
        {
          "aspect" : "16:9",
          "audio" : {
            "limiter" : true,
            "tracks" : {
              "take-001/mic" : {
                "gain" : 1,
                "muted" : false
              },
              "take-001/system-audio" : {
                "gain" : 0.8,
                "muted" : false
              }
            }
          },
          "camera" : {
            "changes" : [
              {
                "id" : "k-1c2d0a9e",
                "origin" : "recorded",
                "style" : {
                  "anchor" : "topLeading",
                  "shape" : "circle",
                  "size" : 0.24
                },
                "t" : 81290000000000,
                "take" : "take-001"
              }
            ],
            "initial" : {
              "take-001" : {
                "anchor" : "bottomTrailing",
                "shape" : "circle",
                "size" : 0.24
              }
            },
            "show" : true
          },
          "cursor" : {
            "clickEffect" : "ripple-1",
            "clickSound" : "none",
            "clickSoundGain" : 0.5,
            "hideWhenIdle" : true,
            "idleDelay" : 2,
            "motionBlur" : 0.5,
            "scale" : 1.5,
            "show" : true,
            "smoothing" : {
              "damping" : 1,
              "response" : 0.16
            },
            "style" : "system"
          },
          "documentVersion" : 1,
          "frameRate" : 60,
          "logSequence" : 128,
          "screens" : {
            "changes" : [
              {
                "id" : "p-9a01b2c3",
                "origin" : "auto",
                "t" : 81260000000000,
                "take" : "take-001",
                "track" : "display-2"
              }
            ],
            "initial" : {
              "take-001" : "display-1"
            },
            "planner" : "screenFollow-1"
          },
          "sequence" : [
            {
              "end" : 81276901234567,
              "id" : "c-00a1b2c3",
              "speed" : 1,
              "start" : 81234567890123,
              "take" : "take-001"
            },
            {
              "end" : 81334000000000,
              "id" : "c-00d4e5f6",
              "speed" : 2,
              "start" : 81277458000000,
              "take" : "take-001"
            }
          ],
          "style" : {
            "background" : {
              "type" : "wallpaper",
              "wallpaper" : "aurora-1"
            },
            "backgroundBlur" : 0,
            "cornerRadius" : 0.012,
            "frame" : {
              "type" : "none"
            },
            "geometryTransition" : "spring",
            "padding" : 0.08,
            "screenSampling" : "mipmapped",
            "shadow" : 0.6
          },
          "zoom" : {
            "auto" : {
              "depth" : 2,
              "enabled" : true,
              "follow" : true,
              "groupGap" : 2.5,
              "holdWhileTyping" : true,
              "leadIn" : 0.5,
              "leadOut" : 1,
              "planner" : "autoZoom-1",
              "triggers" : "clicks"
            },
            "motionBlur" : 0.5,
            "regions" : [
              {
                "end" : 81245000000000,
                "focus" : {
                  "type" : "follow"
                },
                "id" : "z-3fa2b1c0",
                "instant" : false,
                "origin" : "auto",
                "start" : 81241000000000,
                "take" : "take-001"
              },
              {
                "depth" : 1.6,
                "end" : 81300000000000,
                "focus" : {
                  "type" : "fixed",
                  "x" : 0.31,
                  "y" : 0.72
                },
                "id" : "z-7e11d0aa",
                "instant" : false,
                "origin" : "user",
                "start" : 81296000000000,
                "take" : "take-001"
              }
            ],
            "show" : true,
            "spring" : {
              "damping" : 1,
              "response" : 0.7
            },
            "suppressed" : [
              {
                "end" : 81320000000000,
                "start" : 81318000000000,
                "take" : "take-001"
              }
            ]
          }
        }
        """
}

/// The `camera` section of 1c design §13.1: a new project with three blocks; the second was a bubble before it was a
/// split, and the project's layout was a split for a while. Both keep those settings.
enum CameraSectionExample {
    /// As the design writes it, with objects on one line.
    static let json = """
        {
          "border" : { "color" : [ 1, 1, 1, 1 ], "width" : 0 },
          "changes" : [
            { "id" : "k-1c2d0a9e", "origin" : "recorded", "style" : { "anchor" : "topLeading", "shape" : "circle", "size" : 0.24 }, "t" : 81290000000000, "take" : "take-001" }
          ],
          "initial" : { "take-001" : { "anchor" : "bottomTrailing", "shape" : "circle", "size" : 0.24 } },
          "layout" : { "kind" : "bubble", "split" : { "side" : "end" } },
          "layoutRules" : "cameraLayout-1",
          "layouts" : [
            { "end" : 81239567890123, "id" : "l-5b0e19c2", "instant" : false, "kind" : "cameraFull", "start" : 81234567890123, "take" : "take-001" },
            { "bubble" : { "style" : { "anchor" : "bottomTrailing", "shape" : "circle", "size" : 0.24 } }, "end" : 81300000000000, "id" : "l-0a77de31", "instant" : false, "kind" : "split", "split" : { "share" : 0.34, "side" : "end" }, "start" : 81280000000000, "take" : "take-001" },
            { "bubble" : { "style" : { "anchor" : "topLeading", "shape" : "roundedSquare", "size" : 0.33 } }, "end" : 81320000000000, "id" : "l-c4e2a913", "instant" : true, "kind" : "bubble", "start" : 81310000000000, "take" : "take-001" }
          ],
          "mirror" : true,
          "shadow" : 0.4,
          "show" : true,
          "sizeReference" : "shortSide",
          "spring" : { "damping" : 0.95, "response" : 0.5 }
        }
        """

    /// The value it holds, field by field.
    static let camera = CameraPlan(
        show: true,
        initial: ["take-001": CameraStyle(shape: .circle, size: 0.24, anchor: .bottomTrailing)],
        changes: [
            CameraChange(
                id: "k-1c2d0a9e", take: "take-001", t: ns(81_290_000_000_000),
                style: CameraStyle(shape: .circle, size: 0.24, anchor: .topLeading), origin: .recorded),
        ],
        layout: CameraLayout(kind: .bubble, split: SplitLayout(side: .end)),
        layouts: [
            LayoutBlock(
                id: "l-5b0e19c2", take: "take-001", start: ns(81_234_567_890_123), end: ns(81_239_567_890_123), kind: .cameraFull,
                instant: false),
            LayoutBlock(
                id: "l-0a77de31", take: "take-001", start: ns(81_280_000_000_000), end: ns(81_300_000_000_000), kind: .split,
                instant: false, bubble: BubbleLayout(style: CameraStyle(shape: .circle, size: 0.24, anchor: .bottomTrailing)),
                split: SplitLayout(side: .end, share: 0.34)),
            LayoutBlock(
                id: "l-c4e2a913", take: "take-001", start: ns(81_310_000_000_000), end: ns(81_320_000_000_000), kind: .bubble,
                instant: true, bubble: BubbleLayout(style: CameraStyle(shape: .roundedSquare, size: 0.33, anchor: .topLeading))),
        ],
        mirror: true,
        border: CameraBorder(width: 0, color: RGBA(1, 1, 1, 1)),
        shadow: 0.4,
        sizeReference: .shortSide,
        spring: SpringSpec(damping: 0.95, response: 0.5),
        layoutRules: "cameraLayout-1")

    /// The section as `ProjectJSON.encoder()` writes it.
    static let canonical = """
        {
          "border" : {
            "color" : [
              1,
              1,
              1,
              1
            ],
            "width" : 0
          },
          "changes" : [
            {
              "id" : "k-1c2d0a9e",
              "origin" : "recorded",
              "style" : {
                "anchor" : "topLeading",
                "shape" : "circle",
                "size" : 0.24
              },
              "t" : 81290000000000,
              "take" : "take-001"
            }
          ],
          "initial" : {
            "take-001" : {
              "anchor" : "bottomTrailing",
              "shape" : "circle",
              "size" : 0.24
            }
          },
          "layout" : {
            "kind" : "bubble",
            "split" : {
              "side" : "end"
            }
          },
          "layoutRules" : "cameraLayout-1",
          "layouts" : [
            {
              "end" : 81239567890123,
              "id" : "l-5b0e19c2",
              "instant" : false,
              "kind" : "cameraFull",
              "start" : 81234567890123,
              "take" : "take-001"
            },
            {
              "bubble" : {
                "style" : {
                  "anchor" : "bottomTrailing",
                  "shape" : "circle",
                  "size" : 0.24
                }
              },
              "end" : 81300000000000,
              "id" : "l-0a77de31",
              "instant" : false,
              "kind" : "split",
              "split" : {
                "share" : 0.34,
                "side" : "end"
              },
              "start" : 81280000000000,
              "take" : "take-001"
            },
            {
              "bubble" : {
                "style" : {
                  "anchor" : "topLeading",
                  "shape" : "roundedSquare",
                  "size" : 0.33
                }
              },
              "end" : 81320000000000,
              "id" : "l-c4e2a913",
              "instant" : true,
              "kind" : "bubble",
              "start" : 81310000000000,
              "take" : "take-001"
            }
          ],
          "mirror" : true,
          "shadow" : 0.4,
          "show" : true,
          "sizeReference" : "shortSide",
          "spring" : {
            "damping" : 0.95,
            "response" : 0.5
          }
        }
        """

    /// The design example with this camera section.
    static var document: EditDocument {
        var document = DesignExample.document
        document.camera = camera
        return document
    }

    /// `document` as JSON, with the section as the design writes it.
    static func documentJSON() throws -> JSONValue {
        var document = try parsed(DesignExample.canonical)
        document["camera"] = try parsed(Self.json)
        return document
    }
}

// MARK: - Version 1 is read migrated

@Test func version1DecodesMigrated() throws {
    let document = try EditDocument.decode(Data(DocumentV1Example.canonical.utf8))
    #expect(document.documentVersion == EditDocument.currentVersion)
    let camera = document.camera
    #expect(camera.layout == .bubble)
    #expect(camera.layout == CameraLayout(kind: .bubble))
    #expect(camera.layouts.isEmpty)
    #expect(!camera.mirror)
    #expect(camera.border == .none)
    #expect(camera.border == CameraBorder(width: 0, color: RGBA(1, 1, 1, 1)))
    #expect(camera.shadow == 0)
    #expect(camera.sizeReference == .height)
    #expect(camera.spring == SpringSpec(damping: 0.95, response: 0.5))
    #expect(camera.layoutRules == "cameraLayout-1")
    #expect(document == DesignExample.document)
    // Everything else is what 1b read from it: 1b wrote it back byte for byte. (In version 2, without what version 3
    // adds: `MigrationTo3Tests`.)
    var asIn1b = try #require(DocumentMigration.reverted(JSONValue(encoding: document), to: 2))
    asIn1b["documentVersion"] = .integer(1)
    for key in DocumentMigration.addedCameraFields {
        asIn1b["camera"]?[key] = nil
    }
    #expect(asIn1b == (try parsed(DocumentV1Example.canonical)))

    // The same rule from its JSON, and inside another value, as in the `create` line of a 1b edit log.
    #expect(try EditDocument.decode(json: parsed(DocumentV1Example.canonical)) == document)
    struct Entry: Decodable {
        var document: EditDocument
    }
    let entry = try ProjectJSON.decoder().decode(Entry.self, from: Data("{\"document\" : \(DocumentV1Example.canonical)}".utf8))
    #expect(entry.document == document)
    let createLine = #"{"app":{"name":"Toma","version":"0.2.0"},"document":"#
        + (try compact(parsed(DocumentV1Example.canonical))) + #","seq":1,"type":"create"}"#
    let app = AppInfo(name: "Toma", version: "0.2.0")
    #expect(try EditLogEntry(jsonLine: createLine) == .create(seq: 1, document: document, app: app))
}

@Test func a1bLogIsReadMigrated() throws {
    try withTemporaryDirectory { dir in
        // A log as 1b writes it: its `create` holds a version 1 document, and a step of 1b follows.
        let app = AppInfo(name: "Toma", version: "0.2.0")
        let create = #"{"app":{"name":"Toma","version":"0.2.0"},"document":"#
            + (try compact(parsed(DocumentV1Example.canonical))) + #","seq":1,"type":"create"}"#
        let padding = EditChange.set(path: try JSONPointer("/style/padding"), before: .number(0.08), after: .number(0.1))
        let at = Date(timeIntervalSince1970: 1_794_773_523)
        let step = try EditLogEntry.do(seq: 2, group: 2, label: "style.padding", changes: [padding], at: at).jsonLine()
        let url = dir.appending(path: "edit-log.jsonl")
        try Data((create + "\n" + step + "\n").utf8).write(to: url)

        let read = try EditLogReader.read(url)
        #expect(read.damagedLine == nil)
        #expect(!read.droppedTruncatedTail)
        #expect(read.entries == [
            .create(seq: 1, document: DesignExample.document, app: app),
            .do(seq: 2, group: 2, label: "style.padding", changes: [padding], at: at),
        ])
        let replay = try #require(EditReplay.replay(snapshot: nil, entries: read.entries))
        #expect(replay.mismatchSeq == nil)
        #expect(replay.lastAppliedSeq == 2)
        #expect(replay.document.documentVersion == EditDocument.currentVersion)
        #expect(replay.document.style.padding == 0.1)
        #expect(replay.document.camera == DesignExample.document.camera)
    }
}

@Test func writtenVersionReadsOnlyTheVersion() {
    #expect(EditDocument.writtenVersion(of: Data(DocumentV1Example.canonical.utf8)) == 1)
    #expect(EditDocument.writtenVersion(of: Data(DesignExample.canonical.utf8)) == 2)
    #expect(EditDocument.writtenVersion(of: Data(#"{"aspect":"4:3","documentVersion":3}"#.utf8)) == 3)
    #expect(EditDocument.writtenVersion(of: Data(#"{"aspect":"16:9"}"#.utf8)) == nil)
    #expect(EditDocument.writtenVersion(of: Data(#"{"documentVersion":"2"}"#.utf8)) == nil)
    #expect(EditDocument.writtenVersion(of: Data("{\"documentVersion\":".utf8)) == nil)
}

@Test func migrationAddsOnlyTheCameraFields() throws {
    let v1 = try parsed(DocumentV1Example.canonical)
    let migrated = try DocumentMigration.migrate(v1, from: 1)
    #expect(migrated["documentVersion"] == .integer(2))
    // 1c design §13.2, as it writes them.
    let added = try parsed("""
        {
          "border" : { "width" : 0, "color" : [ 1, 1, 1, 1 ] }, "layout" : { "kind" : "bubble" }, "layoutRules" : "cameraLayout-1",
          "layouts" : [], "mirror" : false, "shadow" : 0, "sizeReference" : "height", "spring" : { "damping" : 0.95, "response" : 0.5 }
        }
        """)
    guard case let .object(addedMembers) = added else {
        Issue.record("The added members are an object.")
        return
    }
    #expect(DocumentMigration.addedCameraFields == addedMembers.keys.sorted())
    var rest = migrated
    rest["documentVersion"] = .integer(1)
    for key in DocumentMigration.addedCameraFields {
        #expect(migrated["camera"]?[key] == added[key], "\(key)")
        #expect(v1["camera"]?[key] == nil, "\(key)")
        rest["camera"]?[key] = nil
    }
    #expect(rest == v1)

    // What was already there is overwritten.
    var handWritten = v1
    handWritten["camera"]?["mirror"] = .bool(true)
    handWritten["camera"]?["layouts"] = .array([.string("l-00000001")])
    #expect(try DocumentMigration.migrate(handWritten, from: 1) == migrated)

    #expect(DocumentMigration.isAdditive(from: 1))
    // From 2 too, since phase 2 (`MigrationTo3Tests`), from 3 since phase 3 (`DocumentV4Tests`) and from 4 since phases 4
    // and 5 (`Document5Tests`).
    #expect(DocumentMigration.isAdditive(from: 2))
    #expect(DocumentMigration.isAdditive(from: 3))
    #expect(DocumentMigration.isAdditive(from: 4))
    #expect(!DocumentMigration.isAdditive(from: 5))
    #expect(!DocumentMigration.isAdditive(from: 0))
    // No migration from another version, nor of a document of another version.
    for (document, version) in [(v1, 2), (v1, 0), (migrated, 1), (migrated, 3)] {
        #expect(throws: EditChangeError.invalidDocument("/documentVersion"), "\(version)") {
            try DocumentMigration.migrate(document, from: version)
        }
    }
    var withoutCamera = v1
    withoutCamera["camera"] = nil
    #expect(throws: EditChangeError.invalidDocument("/camera")) { try DocumentMigration.migrate(withoutCamera, from: 1) }
}

// MARK: - The camera section of version 2

@Test func cameraSectionExampleRoundTrips() throws {
    let document = CameraSectionExample.document
    let text = try compact(CameraSectionExample.documentJSON())
    #expect(try EditDocument.decode(Data(text.utf8)) == document)
    // The section as version 2 writes it; in version 3 it has the camera's fields of phase 2 too.
    let inVersion2 = try #require(DocumentMigration.reverted(JSONValue(encoding: document), to: 2))
    #expect(try pretty(#require(inVersion2["camera"])) == CameraSectionExample.canonical)
    #expect(try ProjectJSON.decoder().decode(CameraPlan.self, from: Data(pretty(document.camera).utf8)) == document.camera)
    #expect(try EditDocument.decode(ProjectJSON.encoder().encode(document)) == document)
    // The split block keeps the bubble it was, and the project's bubble the split it was.
    let split = document.camera.layouts[1]
    #expect(split.kind == .split)
    #expect(split.bubble == BubbleLayout(style: CameraStyle(shape: .circle, size: 0.24, anchor: .bottomTrailing)))
    #expect(split.split == SplitLayout(side: .end, share: 0.34))
    #expect(document.camera.layout.split == SplitLayout(side: .end))
    #expect(CameraSectionExample.canonical.components(separatedBy: "\"bubble\" : {").count == 3)
}

@Test func automaticShareIsOmitted() throws {
    #expect(try compact(SplitLayout(side: .end)) == #"{"side":"end"}"#)
    #expect(try compact(SplitLayout()) == #"{"side":"end"}"#)
    #expect(try compact(SplitLayout(side: .start, share: 0.5)) == #"{"share":0.5,"side":"start"}"#)
    #expect(try compact(CameraLayout.bubble) == #"{"kind":"bubble"}"#)
    #expect(try compact(CameraBorder.none) == #"{"color":[1,1,1,1],"width":0}"#)
    let block = LayoutBlock(
        id: "l-00000001", take: "take-001", start: ns(1_000), end: ns(2_000), kind: .split, instant: false, split: SplitLayout())
    let blockText = #"{"end":2000,"id":"l-00000001","instant":false,"kind":"split","split":{"side":"end"},"#
        + #""start":1000,"take":"take-001"}"#
    #expect(try compact(block) == blockText)
    var document = CameraSectionExample.document
    document.camera.layouts[1].split?.share = nil
    let text = try pretty(document)
    #expect(!text.contains("\"share\""))
    #expect(!text.contains("null"))
    #expect(try EditDocument.decode(Data(text.utf8)) == document)
    #expect(SplitLayout.shareRange == 0.25...0.60)
    #expect(CameraBorder.widthFactor == 0.012)
    #expect(CameraLayoutRules.id == "cameraLayout-1")
    #expect(CameraLayoutRules.spring == SpringSpec(damping: 0.95, response: 0.5))
}

@Test func layoutBlocksAreACollection() throws {
    #expect(EditCollection.cameraLayouts.rawValue == "/camera/layouts")
    let document = DesignExample.document
    let block = LayoutBlock(
        id: "l-00000001", take: "take-001", start: ns(81_240_000_000_000), end: ns(81_250_000_000_000), kind: .cameraOnly,
        instant: false)
    let added = try document.applying([document.insertChange(.cameraLayouts, at: 0, block)])
    #expect(added.camera.layouts == [block])
    var split = block
    split.kind = .split
    split.split = SplitLayout()
    let change = try #require(added.replaceChange(.cameraLayouts, id: "l-00000001", with: split))
    #expect(try added.applying([change]).camera.layouts == [split])
    let remove = try #require(added.removeChange(.cameraLayouts, at: 0))
    #expect(try added.applying([remove]) == document)
}

@Test func bubbleBlockWithoutStyleIsInvalid() throws {
    var text = try CameraSectionExample.documentJSON()
    #expect(text["camera"]?["layouts"]?[2]?["kind"] == .string("bubble"))
    text["camera"]?["layouts"]?[2]?["bubble"] = nil
    #expect(throws: DecodingError.self) { try EditDocument.decode(json: text) }
    #expect(throws: DecodingError.self) { try EditDocument.decode(Data(compact(text).utf8)) }
    // A block of another kind needs none.
    text["camera"]?["layouts"]?[2]?["kind"] = .string("screenOnly")
    #expect(try EditDocument.decode(json: text).camera.layouts[2].bubble == nil)
    // A change that leaves a bubble block without its style is refused, and says where.
    let document = CameraSectionExample.document
    var dropped = document.camera.layouts[2]
    dropped.bubble = nil
    let change = try #require(document.replaceChange(.cameraLayouts, id: "l-c4e2a913", with: dropped))
    #expect(throws: EditChangeError.invalidDocument("/camera/layouts/2/bubble")) { try document.applying([change]) }
}

@Test func unknownLayoutKindIsInvalidNotNewer() throws {
    #expect(LayoutKind.allCases.map(\.rawValue) == ["bubble", "screenOnly", "split", "cameraOnly", "cameraFull"])
    var block = try CameraSectionExample.documentJSON()
    block["camera"]?["layouts"]?[0]?["kind"] = .string("faceCrop")
    var project = try CameraSectionExample.documentJSON()
    project["camera"]?["layout"]?["kind"] = .string("faceCrop")
    var side = try CameraSectionExample.documentJSON()
    side["camera"]?["layout"]?["split"]?["side"] = .string("left")
    var reference = try CameraSectionExample.documentJSON()
    reference["camera"]?["sizeReference"] = .string("width")
    for text in [block, project, side, reference] {
        // A `DecodingError`, never `EditDocumentError.newerVersion`: the document is damaged, not newer.
        #expect(throws: DecodingError.self) { try EditDocument.decode(json: text) }
        #expect(throws: DecodingError.self) { try EditDocument.decode(Data(compact(text).utf8)) }
        let line = #"{"app":{"name":"Toma","version":"0.2.0"},"document":"# + (try compact(text)) + #","seq":1,"type":"create"}"#
        #expect(throws: DecodingError.self) { try EditLogEntry(jsonLine: line) }
    }
    // Every field of the section is needed in version 2.
    for key in DocumentMigration.addedCameraFields {
        var missing = try CameraSectionExample.documentJSON()
        missing["camera"]?[key] = nil
        #expect(throws: DecodingError.self, "\(key)") { try EditDocument.decode(json: missing) }
    }
}

// MARK: - Undoing the migration, and what commutes with it

@Test func revertedUndoesTheMigration() throws {
    let v1 = try parsed(DocumentV1Example.canonical)
    let v2 = try DocumentMigration.migrate(v1, from: 1)
    #expect(DocumentMigration.reverted(v2, to: 1) == v1)
    // To the version it already is, it is itself; never forward, nor below version 1.
    #expect(DocumentMigration.reverted(v2, to: 2) == v2)
    #expect(DocumentMigration.reverted(v1, to: 1) == v1)
    #expect(DocumentMigration.reverted(v1, to: 2) == nil)
    #expect(DocumentMigration.reverted(v2, to: 0) == nil)
    #expect(DocumentMigration.reverted(.array([]), to: 1) == nil)

    // A document that uses what version 2 adds has no version 1.
    var mirrored = v2
    mirrored["camera"]?["mirror"] = .bool(true)
    #expect(DocumentMigration.reverted(mirrored, to: 1) == nil)
    var withBlock = v2
    let block = LayoutBlock(id: "l-00000001", take: "take-001", start: ns(1), end: ns(2), kind: .screenOnly, instant: false)
    withBlock["camera"]?["layouts"] = .array([try JSONValue(encoding: block)])
    #expect(DocumentMigration.reverted(withBlock, to: 1) == nil)
    var splitOnce = v2
    splitOnce["camera"]?["layout"] = try JSONValue(encoding: CameraLayout(kind: .bubble, split: SplitLayout()))
    #expect(DocumentMigration.reverted(splitOnce, to: 1) == nil)
    var missing = v2
    missing["camera"]?["spring"] = nil
    #expect(DocumentMigration.reverted(missing, to: 1) == nil)

    // The document a 1b project opens as: reverted, it is the bytes 1b wrote.
    let document = try EditDocument.decode(Data(DocumentV1Example.canonical.utf8))
    let back = try #require(DocumentMigration.reverted(JSONValue(encoding: document), to: 1))
    #expect(try pretty(back) == DocumentV1Example.canonical)
}

@Test func touchesAddedFieldsFindsRootAndCamera() throws {
    func set(_ path: String) throws -> EditChange {
        .set(path: try JSONPointer(path), before: .bool(false), after: .bool(true))
    }
    let block = try JSONValue(
        encoding: LayoutBlock(id: "l-00000001", take: "take-001", start: ns(1), end: ns(2), kind: .screenOnly, instant: false))
    let change = try JSONValue(encoding: DesignExample.document.camera.changes[0])
    // The whole camera of a document of version 1, shown and hidden: carried through the migration, it commutes.
    let camera = try #require(try parsed(DocumentV1Example.canonical)["camera"])
    var hidden = camera
    hidden["show"] = .bool(false)
    let cases: [(EditChange, Bool)] = [
        (try set(""), true),
        (.set(path: try JSONPointer("/camera"), before: camera, after: hidden), false),
        // Not a camera: the migration has nothing to write in.
        (try set("/camera"), true),
        (try set("/camera/mirror"), true),
        (try set("/camera/border/width"), true),
        (try set("/camera/layout/kind"), true),
        (try set("/camera/layoutRules"), true),
        (.insert(collection: try JSONPointer("/camera/layouts"), index: 0, value: block), true),
        (.replace(collection: try JSONPointer("/camera/layouts"), id: "l-00000001", before: block, after: block), true),
        (try set("/camera/show"), false),
        (.insert(collection: try JSONPointer("/camera/changes"), index: 0, value: change), false),
        (.replace(collection: try JSONPointer("/camera/changes"), id: "k-1c2d0a9e", before: change, after: change), false),
        (try set("/camera/initial/take-001"), false),
        (try set("/camera/layoutsAndMore"), false),
        (try set("/style/padding"), false),
        // The migration reads it and writes it.
        (try set("/documentVersion"), true),
    ]
    for (change, touches) in cases {
        #expect(DocumentMigration.touchesAddedFields(change, from: 1) == touches, "\(change)")
        #expect(DocumentMigration.touchesAddedFields(change.inverse, from: 1) == touches, "\(change)")
        // Nothing is known to commute with a migration that is not additive.
        #expect(DocumentMigration.touchesAddedFields(change, from: EditDocument.currentVersion), "\(change)")
    }
}

// MARK: - The documents 1b builds

@Test func legacyHasTheMigrationValues() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await GoldenProjects.make("phaseZero", in: dir)
        let legacy = EditDocument.legacy(for: project)
        #expect(legacy.documentVersion == EditDocument.currentVersion)
        // The legacy document as 1b built it: version 1, without what the migrations add.
        var of1b = try #require(DocumentMigration.reverted(JSONValue(encoding: legacy), to: 2))
        of1b["documentVersion"] = .integer(1)
        for key in DocumentMigration.addedCameraFields {
            of1b["camera"]?[key] = nil
        }
        let migrated = try EditDocument.decode(json: DocumentMigration.migrate(of1b, from: 1))
        #expect(migrated.camera == legacy.camera)
        #expect(migrated == legacy)
    }
    // Every new field of `CameraPlan` defaults to the migration's value.
    let plain = CameraPlan(show: true, initial: [:], changes: [])
    let migratedPlain = try DocumentMigration.migrate(
        .object(["camera": JSONValue(encoding: plain), "documentVersion": .integer(1)]), from: 1)
    #expect(try migratedPlain["camera"].map { try $0.decoded(as: CameraPlan.self) } == plain)
}
