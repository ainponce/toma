// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// Edit documents of milestones 1b and 1c and of phases 2 and 3 (`documentVersion` 1 to 4) sound the same from the code
/// of phase 3 (the commit of the base of phases 4 and 5 before document 5) to every later version of the export, once
/// migrated (phases 4 and 5 design §4.2, "golden 4"). It lives here and not next to `golden4FramesMatch` because only
/// this target sees `MP4Exporter.mixSamples`. It runs only with `TOMA_GOLDEN_4_DIR` set (`make golden-4`): the samples
/// the AAC encoder gets at 60 fps (`MP4Exporter.mixSamples(of:document:framesPerSecond:analysis:)`) of the cases of
/// `GoldenPhase3Project.golden4Cases` that mix, each with its document read from `documents/<case>.json` there
/// (`EditDocument.decode`, which migrates it in phases 4 and 5) and what it reads of the caches (`golden4Analysis`: the
/// loudness of its tracks with Normalize, its music's themes and where its microphones have a voice), as little-endian
/// Float32, one case after the other, must equal `frames.bin.mix` there bit for bit. With `TOMA_GOLDEN_RECORD=1` as
/// well (`make golden-4-record`, only from a commit with `EditDocument.currentVersion` 4), it writes them to that file
/// instead, mixed with each case's `makeDocument` as its recorded JSON decodes (the document `golden4FramesMatch`
/// records), once every check passed, and never over a file already there. Without the file and without the switch it
/// fails: it never passes without comparing.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_GOLDEN_4_DIR"] != nil))
func golden4MixMatches() async throws {
    let environment = ProcessInfo.processInfo.environment
    let dir = URL(fileURLWithPath: try #require(environment["TOMA_GOLDEN_4_DIR"]), isDirectory: true)
    let recording = environment["TOMA_GOLDEN_RECORD"] == "1"
    let url = dir.appending(path: "frames.bin.mix")
    let documentsURL = dir.appending(path: "documents", directoryHint: .isDirectory)
    let exists = FileManager.default.fileExists(atPath: url.path)
    if recording {
        try #require(
            EditDocument.currentVersion == 4, """
                The golden mix of golden 4 is of documents of 1b, 1c and phases 2 and 3 (documentVersion 1 to 4): it is \
                recorded only from a commit of phase 3's document, never from later code (phases 4 and 5 design §4.2)
                """)
        try #require(!exists, "\(url.path) is already there: the golden mix of golden 4 is never recorded over another")
    } else {
        try #require(
            exists, """
                No golden mix at \(url.path): the golden files of golden 4 are recorded whole with `make golden-4-record` \
                from the commit in \(dir.appending(path: "COMMIT").path), never from later code (phases 4 and 5 design §4.2)
                """)
    }
    var bytes = Data()
    // Where each case starts in `bytes`, and its channels.
    var spans: [(name: String, start: Int, channels: Int)] = []
    // Every check is a `#require`: when recording, nothing is written unless they all passed.
    try await withTemporaryDirectory { tmp in
        var themes: [String: URL] = [:]
        for golden in GoldenPhase3Project.golden4Cases where golden.mixes {
            let project = try await GoldenPhase3Project.makeProject(golden.name, in: tmp)
            try #require(
                project.manifest.formatVersion == golden.formatVersion,
                "\(golden.name) is a package of format version \(golden.formatVersion)")
            let document: EditDocument
            if recording {
                let made = try GoldenPhase3Project.makeDocument(golden.name, for: project)
                try #require(made.documentVersion == 4, "\(golden.name)'s document is of version 4, as phase 3 writes it")
                document = try EditDocument.decode(try GoldenDocuments.recordedJSON(of: made, for: golden))
                try #require(document == made, "\(golden.name)'s recorded document decodes to the one made")
            } else {
                let json = try Data(contentsOf: documentsURL.appending(path: "\(golden.name).json"))
                try #require(
                    try ProjectJSON.decoder().decode(RecordedVersion.self, from: json).documentVersion == golden.documentVersion,
                    "documents/\(golden.name).json is a document of version \(golden.documentVersion)")
                document = try EditDocument.decode(json)
            }
            let analysis = try await golden4Analysis(of: project, document: document, themes: &themes, in: tmp)
            let samples = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 60, analysis: analysis)
            // The frames of video at 60 fps, rounded to 48 kHz, worked out apart from the exporter.
            let frames = Int((Double(TimeMap(sequence: document.sequence).frameCount(frameRate: 60)) / 60 * 48_000).rounded())
            try #require(
                frames > 0 && (samples.count == frames || samples.count == 2 * frames),
                "\(golden.name): \(samples.count) samples for \(frames) frames")
            spans.append((golden.name, bytes.count, samples.count / frames))
            for sample in samples {
                withUnsafeBytes(of: sample.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
            }
        }
    }
    if recording {
        try bytes.write(to: url, options: .withoutOverwriting)
        return
    }
    let golden = try Data(contentsOf: url)
    try #require(golden.count == bytes.count, "\(golden.count) bytes in \(url.path), \(bytes.count) mixed")
    guard golden != bytes else { return }
    let first = try #require(golden.indices.first { golden[$0] != bytes[$0] })
    let span = try #require(spans.last { $0.start <= first })
    let sample = (first - span.start) / MemoryLayout<Float>.size
    let differing = stride(from: 0, to: bytes.count, by: MemoryLayout<Float>.size).reduce(0) {
        $0 + (golden[$1..<$1 + MemoryLayout<Float>.size] != bytes[$1..<$1 + MemoryLayout<Float>.size] ? 1 : 0)
    }
    Issue.record("""
        \(differing) samples differ, the first in \(span.name) at \(Double(sample / span.channels) / 48_000) s: the mix of a \
        1b, 1c, phase-2 or phase-3 document changed. Never record the golden files of golden 4 again from this code, only \
        from the commit in \(dir.appending(path: "COMMIT").path) when the system changed (phases 4 and 5 design §4.2)
        """)
}

/// The version a recorded document says it is, read before it is decoded (and migrated).
private struct RecordedVersion: Decodable {
    var documentVersion: Int
}

/// What the mix of `document` reads of the project's caches, as the export gets it (phase 2 design §10, phase 3 design
/// §7.4 to §7.6), made here without `ProjectJobs` and the caches: golden 3's (`golden3Analysis`, the loudness with
/// Normalize) and, with music, what `MusicAnalysis` prepares for it: the file of each theme of the library it plays
/// (`themes`, made once per run into `dir`: `MusicSynth.render` of its score, `music-1`, written by `MusicFile.write`,
/// as `MusicLibrary` makes it) and, with the ducking on, where each microphone and iPhone's sound with segments of
/// every take the sequence shows has a voice (`VoiceActivityFinder.voiced`, `ducking-1`), by
/// `AudioPlan.key(take:track:)`.
private func golden4Analysis(
    of project: LoadedProject, document: EditDocument, themes: inout [String: URL], in dir: URL
) async throws -> AnalysisInputs {
    var analysis = try await golden3Analysis(of: project, document: document)
    guard !document.music.items.isEmpty else { return analysis }
    for item in document.music.items {
        let id = try #require(MusicThemes.id(ofSource: item.source), "\(item.source) is a theme of the library")
        if themes[id] == nil {
            let score = try #require(MusicThemes.score(id), "the score of \(id)")
            let file = dir.appending(path: "music-\(id).caf", directoryHint: .notDirectory)
            try await offThePool {
                let samples = MusicSynth.render(score)
                guard samples.count == MusicFile.channels * MusicThemes.loopFrames else {
                    throw TestSupportError.failed("\(id): \(samples.count) samples")
                }
                try MusicFile.write(interleaved: samples, to: file)
            }
            themes[id] = file
        }
        analysis.musicFiles[item.source] = themes[id]
    }
    guard document.music.ducking.enabled else { return analysis }
    for shown in project.takesShown(by: document) {
        for track in shown.take.tracks where [.microphone, .deviceAudio].contains(track.kind) && !track.segments.isEmpty {
            analysis.voiceActivity[AudioPlan.key(take: shown.take.id, track: track.id)] =
                try await VoiceActivityFinder.voiced(try await TrackAudio.load(shown, track: track.id))
        }
    }
    try #require(!analysis.voiceActivity.isEmpty, "the takes of \(project.package.url.lastPathComponent) have a voice to duck the music")
    return analysis
}
