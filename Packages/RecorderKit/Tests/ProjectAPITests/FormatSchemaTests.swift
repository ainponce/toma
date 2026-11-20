// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import ProjectAPI

/// The JSON Schemas of format 1.0 (`docs/format/schema/`, fases 4 y 5 design §6.1, plan 4b task A3): what they use,
/// that the command schema is the code's, and that they accept what Toma writes, refuse what it refuses and describe
/// every key it writes, on the golden documents, the documents the API's commands leave and the events of a take.

// MARK: - The validator

@Test func validatorFollowsItsKeywords() throws {
    func validator(_ text: String) throws -> SchemaValidator { SchemaValidator(schema: try FormatDocs.json(text)) }
    func accepts(_ validator: SchemaValidator, _ text: String) throws -> Bool { validator.problems(in: try FormatDocs.json(text)).isEmpty }

    let integer = try validator(#"{"type": "integer", "minimum": 0, "maximum": 10}"#)
    #expect(try accepts(integer, "3") && accepts(integer, "0") && accepts(integer, "10"))
    #expect(try !accepts(integer, "3.5") && !accepts(integer, "-1") && !accepts(integer, "11") && !accepts(integer, #""3""#))
    #expect(try accepts(integer, "18446744073709551615") == false)  // above the maximum, though an integer
    let unsigned = try validator(#"{"type": "integer", "minimum": 0}"#)
    #expect(try accepts(unsigned, "18446744073709551615"))

    let either = try validator(#"{"type": ["string", "number"]}"#)
    #expect(try accepts(either, #""a""#) && accepts(either, "1") && accepts(either, "1.5"))
    #expect(try !accepts(either, "true") && !accepts(either, "null") && !accepts(either, "[]"))

    let object = try validator(#"{"type": "object", "properties": {"a": {"type": "string"}}, "required": ["a"]}"#)
    #expect(try accepts(object, #"{"a": "x"}"#) && accepts(object, #"{"a": "x", "b": 1}"#))
    #expect(try !accepts(object, "{}") && !accepts(object, #"{"a": 1}"#))
    // A keyword about objects says nothing of a value that is not one.
    #expect(try accepts(validator(#"{"required": ["a"], "properties": {"a": {"type": "string"}}}"#), #""x""#))

    let choice = try validator(#"{"enum": ["a", 2]}"#)
    #expect(try accepts(choice, #""a""#) && accepts(choice, "2") && accepts(choice, "2.0"))
    #expect(try !accepts(choice, #""b""#) && !accepts(choice, #""2""#))
    let constant = try validator(#"{"const": 5}"#)
    #expect(try accepts(constant, "5") && !accepts(constant, "4"))

    let colour = try validator(
        #"{"$defs": {"rgba": {"type": "array", "items": {"type": "number"}, "minItems": 4, "maxItems": 4}},"#
            + ##" "type": "object", "properties": {"c": {"$ref": "#/$defs/rgba"}}}"##)
    #expect(try accepts(colour, #"{"c": [1, 0.5, 0, 1]}"#))
    #expect(try !accepts(colour, #"{"c": [1, 0.5, 0]}"#) && !accepts(colour, #"{"c": [1, 0.5, 0, 1, 1]}"#))
    #expect(try !accepts(colour, #"{"c": [1, "0.5", 0, 1]}"#))
    #expect(try !accepts(validator(##"{"$ref": "#/$defs/missing"}"##), "1"))

    let map = try validator(#"{"type": "object", "additionalProperties": {"type": "boolean"}, "properties": {"n": {}}}"#)
    #expect(try accepts(map, #"{"x": true, "n": 1}"#) && !accepts(map, #"{"x": 1}"#))

    let tagged = try validator(
        #"{"type": "object", "properties": {"type": {"enum": ["a", "b"]}, "x": {"type": "number"}}, "required": ["type"],"#
            + #" "allOf": [{"if": {"properties": {"type": {"const": "b"}}, "required": ["type"]}, "then": {"required": ["x"]}}]}"#)
    #expect(try accepts(tagged, #"{"type": "a"}"#) && accepts(tagged, #"{"type": "b", "x": 1}"#))
    #expect(try !accepts(tagged, #"{"type": "b"}"#) && !accepts(tagged, #"{"type": "c"}"#) && !accepts(tagged, "{}"))

    let one = try validator(#"{"oneOf": [{"type": "integer"}, {"type": "number", "minimum": 1}]}"#)
    #expect(try accepts(one, "0") && accepts(one, "1.5"))
    #expect(try !accepts(one, "2") && !accepts(one, #""x""#))  // 2 matches both; "x" none

    let described = try validator(
        #"{"type": "object", "properties": {"a": {"type": "object", "properties": {"b": {}}}, "m": {"additionalProperties": {}}}}"#)
    #expect(described.undescribedKeys(in: try FormatDocs.json(#"{"a": {"b": 1, "c": 2}, "m": {"k": 1}, "z": 0}"#)) == ["/a/c", "/z"])

    #expect(SchemaValidator.unknownKeywords(in: try FormatDocs.json(#"{"type": "string", "maxLength": 3}"#)) == ["/maxLength"])
    #expect(
        SchemaValidator.unknownKeywords(in: try FormatDocs.json(#"{"properties": {"a": {"additionalProperties": false}}}"#))
            == ["/properties/a/additionalProperties is false"])
    #expect(SchemaValidator.unknownKeywords(in: try FormatDocs.json(#"{"properties": {"maxLength": {"type": "string"}}}"#)).isEmpty)
}

// MARK: - The schemas

@Test func schemasUseOnlyKnownKeywords() throws {
    for name in FormatDocs.schemaNames {
        let schema = try FormatDocs.schema(name)
        #expect(SchemaValidator.unknownKeywords(in: schema) == [], "\(name)")
        guard case let .object(root) = schema else {
            Issue.record("\(name) is not an object")
            continue
        }
        #expect(root["$schema"] == .string("https://json-schema.org/draft/2020-12/schema"), "\(name)")
        #expect(root["title"] != nil && root["description"] != nil, "\(name)")
    }
}

@Test func commandSchemaFileIsTheCodes() throws {
    let written = try ProjectJSON.encoder().encode(CommandSchema.document) + Data("\n".utf8)
    let url = FormatDocs.schemaURL("edit-command")
    if ProcessInfo.processInfo.environment["TOMA_RECORD_SCHEMA"] == "1" { try written.write(to: url) }
    #expect(try Data(contentsOf: url) == written, "run with TOMA_RECORD_SCHEMA=1 to write it")
}

@Test func everyCommandExampleValidatesAgainstItsDefinition() throws {
    let document = CommandSchema.document
    let whole = SchemaValidator(schema: document), inline = SchemaValidator(schema: CommandSchema.inline)
    let examples = try FormatDocs.commandExamples()
    #expect(examples.map(\.name) == ProjectCommand.names)
    for (name, list) in examples {
        let own = try FormatDocs.validator(for: name, in: document)
        #expect(!list.isEmpty, "\(name) has no example")
        for example in list {
            #expect(own.problems(in: example) == [], "\(name): \(SchemaValidator.compact(example))")
            #expect(whole.problems(in: example) == [], "\(name): \(SchemaValidator.compact(example))")
            #expect(inline.problems(in: example) == [], "\(name): \(SchemaValidator.compact(example))")
            #expect(own.undescribedKeys(in: example) == [], "\(name)")
            #expect(throws: Never.self, "\(name)") { try ProjectCommand(json: example) }
        }
    }
    #expect(!whole.problems(in: .object(["command": .string("dance")])).isEmpty)
    #expect(!whole.problems(in: .object(["command": .string("cut"), "from": .number(1)])).isEmpty)
}

// MARK: - What Toma writes

/// Each document of golden 4 (golden 3's and the phase 3 project), as this version encodes it, with the manifest and the
/// events of its package: the schemas accept them, describe every key, and agree with Toma's readers on each small
/// change of them (`ReaderAgreement`).
@Test func goldenDocumentsValidate() async throws {
    var document = try ReaderAgreement.document()
    var manifest = try ReaderAgreement.manifest()
    var events = try ReaderAgreement.events()
    for golden in try await GoldenFiles.all() {
        #expect(document.disagreements(in: golden.document) == [], "\(golden.name): edit.json")
        #expect(manifest.disagreements(in: golden.manifest) == [], "\(golden.name): manifest.json")
        for line in golden.events {
            #expect(events.disagreements(in: line) == [], "\(golden.name): \(SchemaValidator.compact(line))")
        }
    }
    #expect(document.tried.count > 300 && manifest.tried.count > 40 && events.tried.count > 40)
}

/// A schema stricter or looser than Toma's reader is what `ReaderAgreement` finds: a closed list left open, a field
/// required that Toma leaves out, an integer that takes a fraction.
@Test func readerAgreementFindsASchemaThatIsNotTheReaders() throws {
    let written = try FormatDocs.json(Data(contentsOf: FormatExamples.folder(5).appending(path: "edit.json")))
    guard case var .object(root) = try FormatDocs.schema("edit-document"), case var .object(properties)? = root["properties"],
        case var .array(required)? = root["required"]
    else { throw TestSupportError.missing("the document's schema") }
    properties["aspect"] = .object(["type": .string("string")])
    properties["logSequence"] = .object(["type": .string("number")])
    required.append(.string("info"))
    root["properties"] = .object(properties)
    root["required"] = .array(required)
    var agreement = ReaderAgreement(validator: SchemaValidator(schema: .object(root))) { (try? EditDocument.decode(json: $0)) != nil }
    let found = agreement.disagreements(in: written)
    #expect(found.count == 3)
    #expect(found.contains("/aspect another string: Toma refuses it, the schema accepts it"))
    #expect(found.contains("/logSequence a fraction: Toma refuses it, the schema accepts it"))
    #expect(found.contains("/info missing: Toma reads it, the schema refuses it"))
}

/// Each example of `CommandSchema` but `transcribe` (no engine in the tests) and `applyStyle` (the style of a library),
/// applied in turn by `TomaProject` to a project of 70 s: the document after each, and `edit.json` once closed, are
/// documents the schema accepts.
@MainActor @Test func everyCommandLeavesADocumentTheSchemaAccepts() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await FormatDocs.longProject(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        var agreement = try ReaderAgreement.document()
        var changed: [String] = [], created: [String: String] = [:]
        // trimStart first, before a title card is at the start; the others that shorten the output last, so the times of
        // the rest are still in it.
        let shortening = ["cut", "trimEnd", "setSpeed", "removeFillers", "shortenPauses"]
        let examples = try FormatDocs.commandExamples().filter { !["transcribe", "applyStyle"].contains($0.name) }
        let first = examples.filter { $0.name == "trimStart" }, last = examples.filter { shortening.contains($0.name) }
        for (name, list) in first + examples.filter({ $0.name != "trimStart" && !shortening.contains($0.name) }) + last {
            for example in list {
                var json = example
                // The ids of the examples are made up: the last block or marker this test made.
                if case var .object(members) = json, members["id"] != nil {
                    members["id"] = created[name == "removeZoom" ? "addZoom" : "addMarker"].map(JSONValue.string)
                    json = .object(members)
                }
                let result = try await project.apply(try ProjectCommand(json: json))
                if result.changed { changed.append(name) }
                if let id = result.created { created[name] = id }
                #expect(agreement.validator.problems(in: try JSONValue(encoding: project.document)) == [], "after \(name)")
            }
        }
        #expect(Set(changed) == Set(examples.map(\.name)))
        await project.close()
        let onDisk = try FormatDocs.json(Data(contentsOf: ProjectPackage(url: url).editURL))
        #expect(agreement.disagreements(in: onDisk) == [])
        #expect(agreement.validator.undescribedKeys(in: onDisk) == [])
    }
}

/// The lines of a take `TakeBuilder` wrote, one event of each kind as this version writes it (`focus` of both kinds
/// included) and the lines of the README's "Una línea de cada tipo".
@Test func syntheticEventsValidate() async throws {
    var agreement = try ReaderAgreement.events()
    try await withTemporaryDirectory { dir in
        let project = try await APIFixtures.package(in: dir)
        let written = try FormatDocs.lines(of: project.package.eventsURL(take: project.take.id))
        #expect(written.contains { if case let .object(members) = $0 { members["type"] == .string("marker") } else { false } })
        for line in written { #expect(agreement.disagreements(in: line) == [], "\(SchemaValidator.compact(line))") }
    }
    let t = HostTime(nanoseconds: 81_234_567_000_000)
    let frame = Rect(x: -1920, y: 0, width: 1512, height: 982.5)
    let kinds: [InputEvent.Kind] = [
        .cursor(x: 10.5, y: -20), .mouseDown(.left, x: 1, y: 2), .mouseUp(.other, x: 1, y: 2),
        .displayGeometry(displayID: 4_294_967_295, frame: frame, scale: 2), .segmentStarted(track: "display-1", index: 2),
        .streamInterrupted(track: "display-1", domain: "SCStreamErrorDomain", code: -3821), .paused(reason: "user"), .resumed,
        .deviceChanged(track: "mic", deviceUniqueID: "BuiltInMicrophoneDevice"), .marker,
        .droppedSamples(track: "mic", count: 12), .audioClock(track: "mic", frame: 240_000),
        .windowGeometry(track: "window-4242", frame: frame, onScreen: false), .cameraStyle(.default),
        .cursorImage(hash: "3f2a9c0e3f2a9c0e3f2a9c0e3f2a9c0e", hotspot: SIMD2(0.16, 0.12), size: SIMD2(24, 32), kind: .iBeam),
        .cursorImage(hash: "00000000000000000000000000000000", hotspot: SIMD2(0, 0), size: SIMD2(16, 16), kind: nil),
        .scroll(dx: 0, dy: -42.5, x: 640.5, y: 402), .keyActivity,
        .keyPress(code: 65_535, chars: "$", mods: 4_294_967_295, isRepeat: false, key: "4"),
        .keyPress(code: 123, chars: nil, mods: 0, isRepeat: true),
        .focus(x: 100, y: 80, width: 320.25, height: 24, kind: .element), .focus(x: 640.5, y: -40, width: 2, height: 18, kind: .caret),
    ]
    for kind in kinds {
        let line = try FormatDocs.json(Data(InputEvent(t: t, kind: kind).jsonLine().utf8))
        #expect(agreement.disagreements(in: line) == [], "\(SchemaValidator.compact(line))")
        #expect(agreement.validator.undescribedKeys(in: line) == [], "\(SchemaValidator.compact(line))")
    }
    let readme = try FormatDocs.readmeEventLines()
    #expect(readme.count >= 19)
    for line in readme { #expect(agreement.validator.problems(in: line) == [], "\(SchemaValidator.compact(line))") }
    // A type of a later version is a line a reader skips: the schema takes it.
    #expect(agreement.validator.problems(in: .object(["t": .integer(5), "type": .string("gesture")])) == [])
}

@Test func readmeNamesTheVersionsAndTheErrorCodes() throws {
    let readme = try String(contentsOf: FormatDocs.folder.appending(path: "README.md"), encoding: .utf8)
    let header = "**Formato 1.0** (manifiesto 1–\(Manifest.newestFormatVersion), documento 1–\(EditDocument.currentVersion)): estable."
    #expect(readme.contains(header))
    #expect(!readme.contains("inestable"))
    for code in APIErrorCode.allCases { #expect(readme.contains("`\(code.rawValue)`"), "\(code)") }
    for name in FormatDocs.schemaNames { #expect(readme.contains("schema/\(name).schema.json"), "\(name)") }
    for version in 1...EditDocument.currentVersion { #expect(readme.contains("examples/document-\(version)/"), "\(version)") }
    for version in 1...Manifest.newestFormatVersion { #expect(readme.contains("| \(version) |"), "\(version)") }
}

// MARK: - Shared

/// The files of `docs/format/` and what the tests of the format share.
enum FormatDocs {
    /// The repository: this file is `<root>/Packages/RecorderKit/Tests/ProjectAPITests/FormatSchemaTests.swift`.
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let folder = root.appending(path: "docs/format")
    static let schemaNames = ["manifest", "events", "edit-document", "edit-command"]

    static func schemaURL(_ name: String) -> URL { folder.appending(path: "schema/\(name).schema.json") }

    static func json(_ data: Data) throws -> JSONValue { try ProjectJSON.decoder().decode(JSONValue.self, from: data) }

    static func json(_ text: String) throws -> JSONValue { try json(Data(text.utf8)) }

    static func schema(_ name: String) throws -> JSONValue { try json(Data(contentsOf: schemaURL(name))) }

    static func validator(_ name: String) throws -> SchemaValidator { SchemaValidator(schema: try schema(name)) }

    /// A validator of the command `name` alone: `$ref` to its definition in `document`.
    static func validator(for name: String, in document: JSONValue) throws -> SchemaValidator {
        guard case let .object(root) = document, let definitions = root["$defs"] else { throw TestSupportError.missing("$defs") }
        return SchemaValidator(schema: .object(["$defs": definitions, "$ref": .string("#/$defs/\(name)")]))
    }

    /// The examples of each command of `CommandSchema.document`, in the order of `ProjectCommand.names`.
    static func commandExamples() throws -> [(name: String, examples: [JSONValue])] {
        guard case let .object(root) = CommandSchema.document, case let .object(definitions)? = root["$defs"] else {
            throw TestSupportError.missing("$defs")
        }
        return ProjectCommand.names.map { name in
            guard case let .object(definition)? = definitions[name], case let .array(examples)? = definition["examples"] else {
                return (name, [])
            }
            return (name, examples)
        }
    }

    /// The lines of an `events.jsonl`, each as JSON.
    static func lines(of url: URL) throws -> [JSONValue] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try json(String($0)) }
    }

    /// The lines of the README's block of one event of each type.
    static func readmeEventLines() throws -> [JSONValue] {
        let readme = try String(contentsOf: folder.appending(path: "README.md"), encoding: .utf8)
        guard let start = readme.range(of: "Una línea de cada tipo, exactamente como se escribe:\n\n```\n"),
            let end = readme.range(of: "\n```", range: start.upperBound..<readme.endIndex)
        else { throw TestSupportError.missing("the README's lines of each type") }
        return try readme[start.upperBound..<end.lowerBound].split(separator: "\n").map { try json(String($0)) }
    }

    /// A project of 70 s of a screen and a microphone, with the made-up transcript of `FakeTranscript` added as the app
    /// adds one, closed: room for every example of the commands.
    @MainActor static func longProject(in dir: URL, environment: APIEnvironment) async throws -> URL {
        let project = try await longPackage(in: dir)
        let session = try await EditSession.open(project.package.url, take: nil, context: environment.editContext)
        let step = try unwrap(TranscriptCommands.create(session.document, FakeTranscript.make(for: project.take)), "transcript step")
        guard session.perform(step) == .applied else { throw TestSupportError.failed("the transcript was not applied") }
        _ = await session.flushed()
        await session.close()
        return project.package.url
    }

    @concurrent private static func longPackage(in dir: URL) async throws -> LoadedProject {
        let seconds = 70.0, base = APIFixtures.base
        let builder = try TakeBuilder(in: dir, name: "Long")
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 5, width: 160, height: 90)])
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "mic"),
            segments: [AudioSegmentSpec(start: base, seconds: seconds)])
        try builder.addEvents(
            [InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))]
                + [3.0, 41.0].map { InputEvent(t: base.adding(seconds: $0), kind: .marker) })
        return try builder.write()
    }
}

/// What Toma writes for each case of golden 4 (golden 3's and the phase 3 project), as this version encodes it: its
/// document, its package's manifest and the events of each take. The packages are written eight at a time.
struct GoldenFiles: Sendable {
    var name: String
    var document: JSONValue
    var manifest: JSONValue
    var events: [JSONValue]

    /// Every case, in the order of `GoldenPhase3Project.golden4Cases`.
    static func all() async throws -> [GoldenFiles] {
        let cases = GoldenPhase3Project.golden4Cases
        return try await withThrowingTaskGroup(of: (Int, GoldenFiles).self) { group in
            var next = 0, made: [(Int, GoldenFiles)] = []
            func start() {
                guard next < cases.count else { return }
                let index = next, golden = cases[index]
                group.addTask { (index, try await make(golden)) }
                next += 1
            }
            for _ in 0..<8 { start() }
            while let result = try await group.next() {
                made.append(result)
                start()
            }
            return made.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    @concurrent private static func make(_ golden: GoldenDocuments.Case) async throws -> GoldenFiles {
        try await withTemporaryDirectory { dir in
            let project = try await GoldenPhase3Project.makeProject(golden.name, in: dir)
            let document = try JSONValue(encoding: GoldenPhase3Project.makeDocument(golden.name, for: project))
            let manifest = try FormatDocs.json(Data(contentsOf: project.package.manifestURL))
            let events = try project.takes.flatMap { try FormatDocs.lines(of: project.package.eventsURL(take: $0.id)) }
            return GoldenFiles(name: golden.name, document: document, manifest: manifest, events: events)
        }
    }
}

/// Whether a schema and Toma's reader of the same file agree: on a value Toma writes, which the schema must accept, and
/// on each small change of it (a member taken away; a string, an integer, a number or a boolean of another kind or value;
/// an array one shorter), which the schema must accept exactly when the reader reads it. So the schema requires what
/// Toma requires, has the closed lists Toma has and the integers Toma reads as integers, and nothing stricter. A change
/// is tried once per place (array indices as `*`, a tagged object's `type` kept), across every value given.
struct ReaderAgreement {
    let validator: SchemaValidator
    /// Whether Toma reads a value.
    let reads: @Sendable (JSONValue) -> Bool
    /// Places (indices as `*`) whose other string Toma refuses though a schema cannot say so, like a date.
    var unsayable: Set<String> = []
    /// The changes tried, by place and kind.
    private(set) var tried: Set<String> = []

    init(validator: SchemaValidator, unsayable: Set<String> = [], reads: @escaping @Sendable (JSONValue) -> Bool) {
        self.validator = validator
        self.unsayable = unsayable
        self.reads = reads
    }

    /// `edit-document.schema.json` and `EditDocument.decode(json:)`.
    static func document() throws -> ReaderAgreement {
        ReaderAgreement(validator: try FormatDocs.validator("edit-document")) { (try? EditDocument.decode(json: $0)) != nil }
    }

    /// `manifest.schema.json` and a reader of the manifest: it decodes, of a version it reads. A date is ISO 8601, which
    /// the schema only describes.
    static func manifest() throws -> ReaderAgreement {
        ReaderAgreement(validator: try FormatDocs.validator("manifest"), unsayable: ["/createdAt", "/takes/*/startedAt"]) { value in
            guard let manifest = try? value.decoded(as: Manifest.self) else { return false }
            return Manifest.supportedFormatVersions.contains(manifest.formatVersion)
        }
    }

    /// `events.schema.json` and `InputEvent`'s decoding. A line of a type this version does not know is one a reader
    /// skips, which the schema takes.
    static func events() throws -> ReaderAgreement {
        ReaderAgreement(validator: try FormatDocs.validator("events"), unsayable: ["/type"]) { (try? $0.decoded(as: InputEvent.self)) != nil }
    }

    /// Where the schema and Toma's reader disagree on `value` and on its changes not tried before; empty if nowhere.
    mutating func disagreements(in value: JSONValue) -> [String] {
        var found: [String] = []
        if !reads(value) { found.append("Toma does not read it") }
        found += validator.problems(in: value)
        found += validator.undescribedKeys(in: value).map { "\($0): not described" }
        var sites: [Site] = []
        Self.collect(value, path: [], place: "", tagged: Self.tag(value), removable: false, into: &sites)
        for site in sites where tried.insert(site.tagged + " " + site.kind).inserted {
            let changed = Self.applying(site.change, at: site.path[...], to: value)
            let read = reads(changed), accepted = validator.problems(in: changed).isEmpty
            guard read != accepted, !(unsayable.contains(site.place) && !read) else { continue }
            let pointer = JSONPointer(components: site.path).string
            found.append("\(pointer) \(site.kind): Toma \(read ? "reads" : "refuses") it, the schema \(accepted ? "accepts" : "refuses") it")
        }
        return found
    }

    private enum Change {
        case remove
        case replace(JSONValue)
    }

    private struct Site {
        var path: [String]
        /// The path with array indices as `*`.
        var place: String
        /// `place` with each tagged object's `type`.
        var tagged: String
        var kind: String
        var change: Change
    }

    private static func tag(_ value: JSONValue) -> String {
        if case let .object(members) = value, case let .string(type)? = members["type"] { "{\(type)}" } else { "" }
    }

    private static func collect(
        _ value: JSONValue, path: [String], place: String, tagged: String, removable: Bool, into sites: inout [Site]
    ) {
        func site(_ kind: String, _ change: Change) {
            sites.append(Site(path: path, place: place, tagged: tagged, kind: kind, change: change))
        }
        if removable { site("missing", .remove) }
        switch value {
        case let .object(members):
            for (key, member) in members.sorted(by: { $0.key < $1.key }) {
                let name = "/" + JSONPointer.escape(key)
                collect(
                    member, path: path + [key], place: place + name, tagged: tagged + name + tag(member), removable: true,
                    into: &sites)
            }
        case let .array(elements):
            guard !elements.isEmpty else { return }
            site("shorter", .replace(.array(Array(elements.dropLast()))))
            for (index, element) in elements.enumerated() {
                collect(
                    element, path: path + [String(index)], place: place + "/*", tagged: tagged + "/*" + tag(element),
                    removable: false, into: &sites)
            }
        case .string:
            site("another string", .replace(.string("zz-not-a-value")))
        case .integer, .unsigned:
            site("a fraction", .replace(.number(0.5)))
            site("negative", .replace(.integer(-1)))
        case .number, .bool:
            site("a string", .replace(.string("zz")))
        case .null:
            break
        }
    }

    private static func applying(_ change: Change, at path: ArraySlice<String>, to value: JSONValue) -> JSONValue {
        guard let first = path.first else {
            if case let .replace(replacement) = change { return replacement }
            return value
        }
        switch value {
        case var .object(members):
            if path.count == 1, case .remove = change {
                members[first] = nil
            } else if let member = members[first] {
                members[first] = applying(change, at: path.dropFirst(), to: member)
            }
            return .object(members)
        case var .array(elements):
            guard let index = Int(first), elements.indices.contains(index) else { return value }
            elements[index] = applying(change, at: path.dropFirst(), to: elements[index])
            return .array(elements)
        default:
            return value
        }
    }
}
