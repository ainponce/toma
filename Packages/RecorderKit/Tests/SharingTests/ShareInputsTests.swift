// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import RecorderKitTestSupport
@testable import Sharing
import Testing

// What a project shares (plan 5a decisions 9 to 11): its title and summary, the editor's chapters, the poster's frame,
// the 1080p size of its format, its frame rate and the hash of its document.

private let second: Int64 = 1_000_000_000

/// `cutsAndSpeed`'s take (4 s; [0, 1) s at 1× and [1.5, 4) s at 2×: 2.25 s of output) and its document.
private func cutsAndSpeed(in dir: URL) async throws -> (LoadedProject, EditDocument) {
    let project = try await GoldenDocuments.makeProject("cutsAndSpeed", in: dir)
    return (project, try GoldenDocuments.makeDocument("cutsAndSpeed", for: project))
}

/// The source instant `cutsAndSpeed`'s document shows at its legacy output second `t` (the take's own second `t`).
private func source(_ project: LoadedProject, _ document: EditDocument, _ t: Double) -> HostTime {
    document.sequence[0].start.adding(seconds: t)
}

private func make(
    _ project: LoadedProject, _ document: EditDocument, recorded: MarkerList.Recorded = [:], name: String = "Demo"
) throws -> ShareInputs {
    try ShareInputs.make(project: project, document: document, recorded: recorded, projectName: name, introTitle: "Intro")
}

@Suite struct ShareInputsTests {
    @Test func titleFromInfoElseProjectName() async throws {
        try await withTemporaryDirectory { dir in
            var (project, document) = try await cutsAndSpeed(in: dir)
            #expect(try make(project, document, name: "Mi proyecto").title == "Mi proyecto")
            document.info = ProjectInfo(title: "  Demo de Toma \n", summary: "")
            #expect(try make(project, document).title == "Demo de Toma")
            document.info = ProjectInfo(title: " \n ", summary: "Algo.")
            #expect(try make(project, document, name: "Mi proyecto").title == "Mi proyecto")
        }
    }

    @Test func summaryOnlyWhenNotEmpty() async throws {
        try await withTemporaryDirectory { dir in
            var (project, document) = try await cutsAndSpeed(in: dir)
            #expect(try make(project, document).summary == nil)
            document.info = ProjectInfo(title: "Demo", summary: "\n  ")
            #expect(try make(project, document).summary == nil)
            document.info = ProjectInfo(title: "", summary: " Dos frases.\nOtra. ")
            #expect(try make(project, document).summary == "Dos frases.\nOtra.")
        }
    }

    @Test func chaptersAreTheEditorsChapters() async throws {
        try await withTemporaryDirectory { dir in
            var (project, document) = try await cutsAndSpeed(in: dir)
            let take = project.take.id
            #expect(try make(project, document).chapters.isEmpty)
            document.markers.items = [
                Marker(id: "m-00000001", take: take, t: source(project, document, 2.0), name: "Demo", origin: .added),
                // Cut: the output never shows [1, 1.5) s of the take.
                Marker(id: "m-00000002", take: take, t: source(project, document, 1.2), name: "Cortado", origin: .added),
                Marker(id: "m-00000003", take: take, t: source(project, document, 0.4), name: "", origin: .added),
                Marker(id: "m-00000004", take: take, t: source(project, document, 3.5), name: "Fin", origin: .added),
            ]
            let recorded: MarkerList.Recorded = [take: [source(project, document, 0.3)]]
            let map = TimeMap(sequence: document.sequence)
            let expected = Chapters.list(
                MarkerList.visible(document: document, recorded: recorded, timeMap: map), duration: map.duration,
                introTitle: "Intro")
            let chapters = try make(project, document, recorded: recorded).chapters
            #expect(chapters == expected)
            // Demo at 1.25 s and Fin at 2 s of output (the markers without a name are no chapter); Intro opens at 0.
            #expect(chapters == [
                Chapter(start: 0, title: "Intro"), Chapter(start: second, title: "Demo"), Chapter(start: 2 * second, title: "Fin"),
            ])
        }
    }

    @Test func posterAtTheFirstVisibleMarkerElseOneSecond() async throws {
        try await withTemporaryDirectory { dir in
            var (project, document) = try await cutsAndSpeed(in: dir)
            let take = project.take.id
            #expect(document.frameRate == 60)
            // No marker: 1 s.
            #expect(try make(project, document).posterTime == second)
            // The one cut does not count; the first shown, without a name, at 1.25 + 0.0125 s of output (source 2.025 s
            // at 2×), falls on frame 75 of 60 fps.
            document.markers.items = [
                Marker(id: "m-00000002", take: take, t: source(project, document, 1.2), name: "Cortado", origin: .added),
                Marker(id: "m-00000001", take: take, t: source(project, document, 2.025), name: "", origin: .added),
                Marker(id: "m-00000003", take: take, t: source(project, document, 3.0), name: "Más tarde", origin: .added),
            ]
            #expect(try make(project, document).posterTime == TimeMap.frameTime(75, frameRate: 60))
            // A recorded instant, with no entry, is a marker too: 0.71 s, frame 42.
            let recorded: MarkerList.Recorded = [take: [source(project, document, 0.71)]]
            #expect(try make(project, document, recorded: recorded).posterTime == TimeMap.frameTime(42, frameRate: 60))
            // At another frame rate, on its frames: 0.71 s at 24 fps is frame 17.
            document.frameRate = 24
            #expect(try make(project, document, recorded: recorded).posterTime == TimeMap.frameTime(17, frameRate: 24))
            // An output shorter than 1 s: its last frame.
            document.markers.items = []
            document.frameRate = 60
            document.sequence = [document.sequence[0]]
            document.sequence[0].end = source(project, document, 0.5)
            #expect(try make(project, document).posterTime == TimeMap.frameTime(29, frameRate: 60))
        }
    }

    @Test func outputSizeIs1080pOfTheFormat() async throws {
        try await withTemporaryDirectory { dir in
            var (project, document) = try await cutsAndSpeed(in: dir)
            #expect(try make(project, document).outputSize == [1920, 1080])
            document.aspect = .portrait
            #expect(try make(project, document).outputSize == [1080, 1920])
            document.aspect = .square
            #expect(try make(project, document).outputSize == [1080, 1080])
            // "Like the Recording" follows the recording: a display of 4:3.
            let recording = try await GoldenDocuments.makeProject("likeTheRecording", in: dir)
            var like = EditDocument.legacy(for: recording)
            like.aspect = .auto
            #expect(try make(recording, like).outputSize == [1440, 1080])
            // The frame rate is the document's, as the export sheet takes it.
            #expect(try make(project, document).framesPerSecond == 60)
            document.frameRate = 25
            #expect(try make(project, document).framesPerSecond == 25)
            document.frameRate = 59
            #expect(try make(project, document).framesPerSecond == 60)
        }
    }

    @Test func documentHashIsStableAndChangesWithAnEdit() async throws {
        try await withTemporaryDirectory { dir in
            var (project, document) = try await cutsAndSpeed(in: dir)
            let hash = try ShareInputs.documentHash(document)
            #expect(hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) })
            #expect(try ShareInputs.documentHash(document) == hash)
            #expect(try make(project, document).documentHash == hash)
            // Decoded again, the same document has the same hash.
            let again = try ProjectJSON.decoder().decode(EditDocument.self, from: ProjectJSON.encoder().encode(document))
            #expect(try ShareInputs.documentHash(again) == hash)
            document.sequence[1].speed = 1.5
            #expect(try ShareInputs.documentHash(document) != hash)
        }
    }

    @Test func recordedMarkersAreEachTakesMarkerEvents() async throws {
        try await withTemporaryDirectory { dir in
            let (project, _) = try await cutsAndSpeed(in: dir)
            // The golden take records no marker: none, and no empty list for it.
            #expect(ShareInputs.recordedMarkers(of: project).isEmpty)
        }
    }

    @Test func idsAreTenBase32() {
        let ids = (0..<1000).map { _ in ShareID.random() }
        #expect(ids.allSatisfy(ShareID.isValid))
        #expect(Set(ids).count == 1000)
        #expect(ShareID.alphabet.count == 32 && Set(ShareID.alphabet).count == 32)
        #expect(!ShareID.isValid("k3m7q2x9z") && !ShareID.isValid("k3m7q2x4za1") && !ShareID.isValid("K3M7Q2X9ZA"))
        #expect(ShareID.isValid("k3m7q2x4za"))
        // Every letter of the alphabet comes up.
        #expect(Set(ids.joined()) == Set(ShareID.alphabet))
    }

    @Test func aFrameIsTheOneShownThen() {
        for fps in EditDocument.frameRates {
            for n in 0..<200 {
                let start = TimeMap.frameTime(n, frameRate: fps)
                #expect(ShareInputs.frame(at: start, frameRate: fps) == n)
                #expect(ShareInputs.frame(at: TimeMap.frameTime(n + 1, frameRate: fps) - 1, frameRate: fps) == n)
            }
        }
        #expect(ShareInputs.frame(at: -1, frameRate: 60) == 0)
    }
}
