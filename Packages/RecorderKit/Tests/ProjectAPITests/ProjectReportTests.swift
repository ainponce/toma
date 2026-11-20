// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import ProjectAPI

/// What the API reads of a project: in seconds of the output, the source in nanoseconds.

@MainActor @Test func readModeExposesTheDiskDocumentAndVisibleMarkers() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        // A marker cut away, made by an editor.
        let editor = try await TomaProject.open(url, mode: .edit, environment: environment)
        _ = try await editor.apply(.cut(from: 6.5, to: 7.5))
        await editor.close()

        let project = try await TomaProject.open(url, mode: .read, environment: environment)
        let (_, disk) = try EditSession.readDocument(url, take: nil, context: environment.editContext)
        #expect(project.document == disk)
        let loaded = try LoadedProject.load(url)
        let recorded = CommandScope.recordedMarkers(of: loaded)
        let visible = MarkerList.visible(document: disk, recorded: recorded, timeMap: TimeMap(sequence: disk.sequence))
        let markers = await project.markers
        #expect(markers == visible)
        // The one at 7 s is cut; the one at 3 s shows at 3 s.
        #expect(markers.count == 1)
        #expect(abs(Double(try #require(markers.first).output) / 1e9 - 3) < 0.001)
        await project.close()
    }
}

@MainActor @Test func timesAreOutputSecondsAndSourceNanoseconds() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        let before = project.document
        let cutEnd = try #require(TimeMap(sequence: before.sequence).source(atOutput: APIFixtures.ns(2)))
        let result = try await project.apply(.cut(from: 1, to: 2))
        #expect(result.changed && result.label == "delete")
        let report = await project.report()
        #expect(report.sequence.count == 2)
        let second = report.sequence[1]
        #expect(abs(second.start - 1.0) < 1e-6)
        #expect(second.sourceStart == cutEnd.source.nanoseconds)
        #expect(abs(report.duration - (TimeMap(sequence: before.sequence).durationSeconds - 1)) < 1e-6)
        #expect(abs(result.duration - report.duration) < 1e-9)
        #expect(report.sequence[0].start == 0)
        #expect(report.sequence[0].sourceStart == before.sequence[0].start.nanoseconds)
        await project.close()
    }
}

@MainActor @Test func chaptersAreChaptersList() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        let recorded = try #require(await project.markers.last)
        _ = try await project.apply(.renameMarker(id: recorded.id, name: "Second part"))
        _ = try await project.apply(.addMarker(at: 5, name: "Middle"))
        let document = project.document
        let visible = await project.markers
        let map = TimeMap(sequence: document.sequence)
        // FakeTranscript speaks Spanish: the first chapter is «Introducción».
        let expected = Chapters.list(visible, duration: map.duration, introTitle: "Introducción")
        let report = await project.report()
        #expect(report.chapters == expected.map { ChapterReport(start: Double($0.start) / 1e9, title: $0.title) })
        #expect(report.chapters.map(\.title) == ["Introducción", "Middle", "Second part"])
        let markers = await project.markersReport()
        #expect(markers.chapters == report.chapters)
        #expect(markers.youTube == Chapters.youTubeText(expected, duration: map.duration))
        #expect(markers.youTube.hasPrefix("00:00 Introducción\n00:05 Middle"))
        await project.close()
    }
}

@MainActor @Test func cutMarkersAreNotListed() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        #expect(await project.report().markers.count == 2)
        _ = try await project.apply(.cut(from: 2.5, to: 3.5))
        let markers = await project.report().markers
        #expect(markers.count == 1)
        // The one at 7 s of the take now shows at 6 s.
        #expect(abs(try #require(markers.first).at - 6) < 0.001)
        #expect(markers.first?.origin == "recorded")
        #expect(markers.first?.t == APIFixtures.base.adding(seconds: 7).nanoseconds)
        await project.close()
    }
}

@MainActor @Test func transcriptWordsCarryOutputTimesAndCut() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        _ = try await project.apply(.cut(from: 1, to: 3))
        let report = try #require(project.transcriptReport())
        #expect(report.language == "es-MX")
        let document = project.document
        let take = try #require(document.transcript?.takes.first)
        #expect(report.words.count == take.words.count)
        let kept = TranscriptTiming.keptWords(of: document, timeMap: TimeMap(sequence: document.sequence))
        #expect(report.text == kept.map(\.text).joined(separator: " "))
        #expect(report.words.contains { $0.cut } && report.words.contains { !$0.cut })
        for (word, original) in zip(report.words, take.words) {
            #expect(word.sourceStart == original.start.nanoseconds)
            #expect(word.cut == TranscriptTiming.isCut(original, take: take.take, in: document.sequence))
            #expect((word.start == nil) == word.cut)
            if let start = word.start, let end = word.end { #expect(start <= end && end <= Double(10)) }
        }
        // A word after the cut is said 2 s sooner than in the take.
        let late = try #require(report.words.last { !$0.cut })
        let offset = Double(late.sourceStart - document.sequence[0].start.nanoseconds) / 1e9
        #expect(abs(try #require(late.start) - (offset - 2)) < 0.01)
        let summary = try #require(await project.report().transcript)
        #expect(summary.words == take.words.count && summary.takes == 1)
        await project.close()
    }
}

@Test func reportJSONIsStable() throws {
    let report = ProjectReport(
        path: "/Projects/Demo.toma", name: "Demo", mode: .read, formatVersion: 3, documentVersion: 5,
        info: ProjectInfo(title: "Demo", summary: ""), duration: 9.5, frameRate: 30, aspect: "16:9",
        takes: [
            TakeReport(
                id: "take-001", status: "complete", startedAt: Date(timeIntervalSince1970: 1_800_000_000), seconds: 10,
                inSequence: true, tracks: [TrackReport(id: "display-1", kind: "display", name: "Display")])
        ],
        sequence: [
            ClipReport(id: "c-1", take: "take-001", start: 0, end: 9.5, sourceStart: 5_000_000_000_000, sourceEnd: 5_009_500_000_000, speed: 1, content: nil)
        ],
        markers: [MarkerReport(id: "m-1", name: "Setup", at: 3, take: "take-001", t: 5_003_000_000_000, origin: "added")],
        chapters: [ChapterReport(start: 0, title: "Intro"), ChapterReport(start: 3, title: "Setup")],
        zoom: ZoomReport(
            enabled: true, followsFocus: false, depth: 2,
            blocks: [
                ZoomBlockReport(
                    id: "z-1", origin: "user", take: "take-001", start: 4, end: 6, sourceStart: 5_004_000_000_000,
                    sourceEnd: 5_006_000_000_000, depth: nil, focus: .fixed(x: 0.25, y: 0.5), mode: nil)
            ]),
        style: StyleReport(style: .object(["padding": .number(0.08)]), cameraLayout: "bubble"),
        music: [MusicReport(id: "mu-1", source: "library:music-1/calm", start: 0, end: 9.5, gain: -14)],
        transcript: TranscriptSummary(language: "en-US", words: 12, takes: 1))
    let text = String(decoding: try ProjectJSON.encoder().encode(report), as: UTF8.self)
    #expect(text == """
        {
          "aspect" : "16:9",
          "chapters" : [
            {
              "start" : 0,
              "title" : "Intro"
            },
            {
              "start" : 3,
              "title" : "Setup"
            }
          ],
          "documentVersion" : 5,
          "duration" : 9.5,
          "formatVersion" : 3,
          "frameRate" : 30,
          "info" : {
            "summary" : "",
            "title" : "Demo"
          },
          "markers" : [
            {
              "at" : 3,
              "id" : "m-1",
              "name" : "Setup",
              "origin" : "added",
              "t" : 5003000000000,
              "take" : "take-001"
            }
          ],
          "mode" : "read",
          "music" : [
            {
              "end" : 9.5,
              "gain" : -14,
              "id" : "mu-1",
              "source" : "library:music-1/calm",
              "start" : 0
            }
          ],
          "name" : "Demo",
          "path" : "/Projects/Demo.toma",
          "sequence" : [
            {
              "end" : 9.5,
              "id" : "c-1",
              "sourceEnd" : 5009500000000,
              "sourceStart" : 5000000000000,
              "speed" : 1,
              "start" : 0,
              "take" : "take-001"
            }
          ],
          "style" : {
            "cameraLayout" : "bubble",
            "style" : {
              "padding" : 0.08
            }
          },
          "takes" : [
            {
              "id" : "take-001",
              "inSequence" : true,
              "seconds" : 10,
              "startedAt" : "2027-01-15T08:00:00Z",
              "status" : "complete",
              "tracks" : [
                {
                  "id" : "display-1",
                  "kind" : "display",
                  "name" : "Display"
                }
              ]
            }
          ],
          "transcript" : {
            "language" : "en-US",
            "takes" : 1,
            "words" : 12
          },
          "zoom" : {
            "blocks" : [
              {
                "end" : 6,
                "focus" : {
                  "x" : 0.25,
                  "y" : 0.5
                },
                "id" : "z-1",
                "origin" : "user",
                "sourceEnd" : 5006000000000,
                "sourceStart" : 5004000000000,
                "start" : 4,
                "take" : "take-001"
              }
            ],
            "depth" : 2,
            "enabled" : true,
            "followsFocus" : false
          }
        }
        """)
    // And back.
    #expect(try ProjectJSON.decoder().decode(ProjectReport.self, from: Data(text.utf8)) == report)
}
