// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat
import Testing
@testable import toma

/// The texts `toma` writes for a person, against literals (plan 4b, Task A4).
@Suite struct CLIOutputTests {
    static let report = ProjectReport(
        path: "/Users/me/Movies/Toma/Demo.toma", name: "Demo", mode: .read, formatVersion: 3, documentVersion: 5,
        info: ProjectInfo(title: "Launch", summary: "First line\nSecond line"), duration: 65.25, frameRate: 30,
        aspect: "16:9",
        takes: [
            TakeReport(
                id: "take-001", status: "complete", startedAt: Date(timeIntervalSince1970: 1_794_780_000), seconds: 70,
                inSequence: true,
                tracks: [
                    TrackReport(id: "display-1", kind: "display", name: "Built-in Display"),
                    TrackReport(id: "mic", kind: "microphone", name: "MacBook Pro Microphone"),
                ]),
            TakeReport(
                id: "take-002", status: "recovered", startedAt: Date(timeIntervalSince1970: 1_794_790_000), seconds: 3.5,
                inSequence: false, tracks: [TrackReport(id: "display-1", kind: "display", name: "Built-in Display")]),
        ],
        sequence: [
            ClipReport(id: "c-1", take: "take-001", start: 0, end: 30, sourceStart: 1, sourceEnd: 2, speed: 1, content: nil),
            ClipReport(id: "c-2", take: "take-001", start: 30, end: 65.25, sourceStart: 3, sourceEnd: 4, speed: 1, content: nil),
        ],
        markers: [
            MarkerReport(id: "rec-take-001-3000000000", name: "", at: 3, take: "take-001", t: 3, origin: "recorded"),
            MarkerReport(id: "m-0a1b2c3d", name: "Setup", at: 62.5, take: "take-001", t: 7, origin: "added"),
        ],
        chapters: [ChapterReport(start: 0, title: "Intro"), ChapterReport(start: 62.5, title: "Setup")],
        zoom: ZoomReport(
            enabled: true, followsFocus: true, depth: 2,
            blocks: [
                ZoomBlockReport(
                    id: "z-1", origin: "auto", take: "take-001", start: 1, end: 2, sourceStart: 1, sourceEnd: 2, depth: nil,
                    focus: .follow, mode: nil)
            ]),
        style: StyleReport(style: .null, cameraLayout: "bubble"),
        music: [MusicReport(id: "mu-1", source: "library:music-1/calm", start: 0, end: 65.25, gain: -14)],
        transcript: TranscriptSummary(language: "es-MX", words: 120, takes: 1))

    @Test func infoText() {
        #expect(CLIOutput.info(Self.report) == """
            Demo
            path        /Users/me/Movies/Toma/Demo.toma
            format      3, document 5
            title       Launch
            summary     First line
                        Second line
            duration    1:05.250, 30 fps, 16:9
            takes       take-001 complete, 1:10.000: display-1 (display), mic (microphone)
                        take-002 recovered, 0:03.500, not in the sequence: display-1 (display)
            sequence    2 clips
            markers     2 markers, 1 named
            chapters    0:00.000 Intro
                        1:02.500 Setup
            zoom        automatic, following the focus, depth 2×, 1 block
            camera      bubble
            music       library:music-1/calm 0:00.000–1:05.250, -14 dB
            transcript  es-MX, 120 words

            """)
        var plain = Self.report
        plain.documentVersion = nil
        plain.info = nil
        plain.markers = []
        plain.chapters = []
        plain.zoom = ZoomReport(enabled: false, followsFocus: true, depth: 1.75, blocks: [])
        plain.music = []
        plain.transcript = nil
        plain.takes.removeLast()
        #expect(CLIOutput.info(plain) == """
            Demo
            path        /Users/me/Movies/Toma/Demo.toma
            format      3, no edit document
            duration    1:05.250, 30 fps, 16:9
            takes       take-001 complete, 1:10.000: display-1 (display), mic (microphone)
            sequence    2 clips
            markers     no markers
            chapters    none
            zoom        not automatic, depth 1.75×, no blocks
            camera      bubble
            music       none
            transcript  none

            """)
    }

    @Test func markersAndChaptersText() {
        let markers = MarkersReport(
            markers: Self.report.markers, chapters: Self.report.chapters, youTube: "00:00 Intro\n01:02 Setup")
        #expect(CLIOutput.markers(markers) == """
            0:03.000  rec-take-001-3000000000
            1:02.500  m-0a1b2c3d  Setup

            """)
        #expect(CLIOutput.chapters(markers, youTube: false) == "0:00.000  Intro\n1:02.500  Setup\n")
        #expect(CLIOutput.chapters(markers, youTube: true) == "00:00 Intro\n01:02 Setup\n")
        let none = MarkersReport(markers: [], chapters: [], youTube: "")
        #expect(CLIOutput.markers(none).isEmpty && CLIOutput.chapters(none, youTube: true).isEmpty)
    }

    @Test func transcriptText() {
        let transcript = TranscriptReport(
            language: "es", text: "Hola a todos",
            words: [WordReport(take: "take-001", text: "eh", start: nil, end: nil, sourceStart: 1, sourceEnd: 2, cut: true)])
        #expect(CLIOutput.transcript(transcript) == "Hola a todos\n")
    }

    @Test func validationCommandAndExportText() {
        #expect(CLIOutput.validation(ValidationReport(
            valid: true, formatVersion: 3, documentVersion: 5, problems: [], skippedEventLines: 0, missingFiles: [])) == "valid (format 3, document 5)\n")
        #expect(CLIOutput.validation(ValidationReport(
            valid: false, formatVersion: 3, documentVersion: nil, problems: ["the title is longer than 200 characters"],
            skippedEventLines: 1, missingFiles: ["takes/take-001/mic/seg-0001.mov"])) == """
            not valid (format 3)
            problem: the title is longer than 200 characters
            missing: takes/take-001/mic/seg-0001.mov
            skipped: 1 line of the event logs that are not an event Toma reads

            """)
        #expect(CLIOutput.command(CommandResult(
            command: "addMarker", changed: true, label: "marker.add", created: "m-00000001", duration: 10, undo: "marker.add",
            via: .project)) == "addMarker: marker.add, created m-00000001, output 0:10.000\n")
        #expect(CLIOutput.command(CommandResult(
            command: "setAspect", changed: false, label: nil, created: nil, duration: 3725.5, undo: nil, via: .project))
            == "setAspect: no change, output 1:02:05.500\n")
        #expect(CLIOutput.export(ExportResult(
            path: "/tmp/out.mp4", format: "mp4", codec: "h264", width: 1920, height: 1080, framesPerSecond: 30, duration: 10,
            bytes: 2_345_678, chapters: 2, warnings: ["x"], fcpxml: nil, metadata: nil))
            == "/tmp/out.mp4 (h264, 1920×1080, 30 fps, 0:10.000, 2 chapters, 2.3 MB)\n")
    }

    @Test func errorJSON() throws {
        let text = CLIOutput.json(error: APIError(.locked, "another app is editing the project"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: String]])
        #expect(object == ["error": ["code": "locked", "message": "another app is editing the project"]])
        #expect(CLI.exitCode(.invalidCommand) == 2 && CLI.exitCode(.locked) == 3 && CLI.exitCode(.notAProject) == 1)
    }
}
