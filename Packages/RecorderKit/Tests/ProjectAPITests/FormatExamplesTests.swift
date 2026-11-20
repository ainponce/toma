// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// The example packages of `docs/format/examples/` (plan 4b decision 18): one per version of the edit document, each a
/// `manifest.json`, the `events.jsonl` of its take and an `edit.json` of that version, without video. They are read as
/// files, never opened as projects.

@Test func examplesValidate() throws {
    var manifest = try ReaderAgreement.manifest(), events = try ReaderAgreement.events(), document = try ReaderAgreement.document()
    for version in 1...EditDocument.currentVersion {
        let folder = FormatExamples.folder(version)
        let written = try FormatDocs.json(Data(contentsOf: folder.appending(path: "manifest.json")))
        #expect(manifest.disagreements(in: written) == [], "document-\(version): manifest.json")
        let lines = try FormatDocs.lines(of: folder.appending(path: "takes/take-001/events.jsonl"))
        #expect(lines.count >= 8, "document-\(version)")
        for line in lines { #expect(events.disagreements(in: line) == [], "document-\(version): \(SchemaValidator.compact(line))") }
        let focus = lines.filter { if case let .object(members) = $0 { members["type"] == .string("focus") } else { false } }
        #expect(focus.isEmpty == (version < 5), "document-\(version): its focus events")

        let data = try Data(contentsOf: folder.appending(path: "edit.json"))
        #expect(EditDocument.writtenVersion(of: data) == version)
        // An older one is read migrated: as this version writes it again, it is a document 5.
        let current = version == EditDocument.currentVersion ? try FormatDocs.json(data) : try JSONValue(encoding: EditDocument.decode(data))
        #expect(document.disagreements(in: current) == [], "document-\(version): edit.json")
    }
}

@Test func version5ExampleIsWhatTheCodeWrites() throws {
    if ProcessInfo.processInfo.environment["TOMA_RECORD_FORMAT_EXAMPLES"] == "1" {
        for version in 1...EditDocument.currentVersion {
            for (path, data) in try FormatExamples.files(version: version) {
                let url = FormatExamples.folder(version).appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }
    }
    for (path, data) in try FormatExamples.files(version: EditDocument.currentVersion) {
        let url = FormatExamples.folder(EditDocument.currentVersion).appending(path: path)
        #expect(try Data(contentsOf: url) == data, "\(path): run with TOMA_RECORD_FORMAT_EXAMPLES=1 to write it")
    }
}

/// The example package of each document version: a project Toma 0.2.0 (milestone 1b) created, with one take of a
/// display and a microphone, last edited by the app that writes that version.
enum FormatExamples {
    static let base = HostTime(nanoseconds: 81_234_567_000_000)
    static let take = "take-001"

    static func folder(_ version: Int) -> URL { FormatDocs.folder.appending(path: "examples/document-\(version)") }

    /// The package's files of `version`, by their path in it, as Toma writes them.
    static func files(version: Int) throws -> [(path: String, data: Data)] {
        let events = events(focus: version >= 5)
        let manifest = manifest()
        let document = try document(version: version, take: manifest.takes[0], events: events)
        return [
            ("manifest.json", try ProjectJSON.encoder().encode(manifest)),
            ("takes/\(take)/events.jsonl", Data(try events.map { try $0.jsonLine() + "\n" }.joined().utf8)),
            ("edit.json", try ProjectJSON.encoder().encode(document)),
        ]
    }

    static func manifest() -> Manifest {
        let end = base.adding(seconds: 12)
        func segment(_ track: String, _ start: HostTime) -> SegmentRecord {
            SegmentRecord(
                index: 1, file: "takes/\(take)/\(track)/seg-0001.mov", startHostTime: start, endHostTime: end, endReason: .stopped,
                droppedFrames: 0, heartbeatFrames: 0)
        }
        return Manifest(
            formatVersion: 3, app: AppInfo(name: "Toma", version: "0.2.0"), createdAt: Date(timeIntervalSince1970: 1_794_772_800),
            takes: [
                TakeRecord(
                    id: take, status: .complete, startedAt: Date(timeIntervalSince1970: 1_794_772_801),
                    tracks: [
                        TrackRecord(
                            id: "display-1", kind: .display,
                            source: TrackSource(
                                name: "Built-in Retina Display", displayID: 1, globalFrame: screen, pixelScale: 2),
                            segments: [segment("display-1", base)]),
                        TrackRecord(
                            id: "mic", kind: .microphone,
                            source: TrackSource(name: "MacBook Pro Microphone", deviceUniqueID: "BuiltInMicrophoneDevice"),
                            segments: [segment("mic", base.adding(seconds: 0.002))]),
                    ])
            ],
            projectID: "9d4f3b2a7c1e48d6b05a2f9e3c7d1a84")
    }

    static let screen = Rect(x: 0, y: 0, width: 1512, height: 982)

    /// The take's events, in the order a recording writes them; with `focus`, the keyboard's focus too (version 5).
    static func events(focus: Bool) -> [InputEvent] {
        func at(_ seconds: Double, _ kind: InputEvent.Kind) -> InputEvent { InputEvent(t: base.adding(seconds: seconds), kind: kind) }
        var events = [
            at(-0.001, .displayGeometry(displayID: 1, frame: screen, scale: 2)),
            at(0, .segmentStarted(track: "display-1", index: 1)),
            at(0.002, .segmentStarted(track: "mic", index: 1)),
            at(0.5, .cursor(x: 640.5, y: 402)),
            at(0.508, .cursor(x: 642.25, y: 401)),
        ]
        if focus {
            events.append(at(2.9, .focus(x: 420, y: 300, width: 480, height: 28, kind: .element)))
            events.append(at(3, .focus(x: 431.5, y: 305, width: 2, height: 18, kind: .caret)))
        }
        events += [
            at(3, .keyActivity),
            at(3.25, .keyActivity),
            at(5, .audioClock(track: "mic", frame: 239_904)),
            at(6, .marker),
            at(9, .cursor(x: 700, y: 512.75)),
        ]
        return events
    }

    /// The document of `version`: the legacy one of the take, with what that version added and a user would leave in a
    /// small project (3: a transcript and its captions; 4: the recorded marker named; 5: the title, the summary and the
    /// automatic zoom following the focus), written in that version as Toma writes `edit.json`.
    static func document(version: Int, take: TakeRecord, events: [InputEvent]) throws -> JSONValue {
        var document = EditDocument.legacy(take: take, events: events)
        document.logSequence = 1
        if version >= 3 {
            let words = [("Hola,", 1.0, 1.4), ("esto", 1.5, 1.8), ("es", 1.8, 1.95), ("Toma.", 2.0, 2.5)].map { text, start, end in
                TranscriptWord(start: base.adding(seconds: start), end: base.adding(seconds: end), text: text)
            }
            document.transcript = Transcript(
                language: "es-AR", engine: "speechTranscriber-1", takes: [TranscriptTake(take: take.id, track: "mic", words: words)])
            document.captions.show = true
        }
        if version >= 4 {
            document.markers.items = [
                Marker(id: "m-00000001", take: take.id, t: base.adding(seconds: 6), name: "Demo", origin: .recorded)
            ]
        }
        if version >= 5 {
            document.zoom.auto.enabled = true
            document.zoom.auto.followsFocus = true
            document.info = ProjectInfo(title: "Demo de Toma", summary: "Cómo grabar, editar y compartir.\nEn dos minutos.")
        }
        let json = try JSONValue(encoding: document)
        guard version != EditDocument.currentVersion else { return json }
        return try unwrap(DocumentMigration.reverted(json, to: version), "the example in version \(version)")
    }
}
