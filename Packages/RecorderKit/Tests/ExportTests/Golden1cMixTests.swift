// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// Edit documents of milestone 1b (`documentVersion` 1) sound the same from the code of the commit that closes 1b to every
/// later version of the export, once migrated (plan 1c decision 2). It runs only with `TOMA_GOLDEN_1C_DIR` set
/// (`make golden-1c`): the samples the AAC encoder gets at 60 fps (`MP4Exporter.mixSamples(of:document:framesPerSecond:)`)
/// of the cases of `GoldenDocuments` that mix, each with its document read from `documents/<case>.json` there
/// (`EditDocument.decode`, which migrates it in 1c), as little-endian Float32, one case after the other, must equal
/// `frames.bin.mix` there bit for bit. With `TOMA_GOLDEN_RECORD=1` as well (`make golden-1c-record`, only from that
/// commit, with `EditDocument.currentVersion` 1), it writes them to that file instead, mixed with each case's
/// `makeDocument` as its JSON decodes (the document `golden1cFramesMatch` records), once every check passed, and never
/// over a file already there. Without the file and without the switch it fails: it never passes without comparing.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_GOLDEN_1C_DIR"] != nil))
func golden1cMixMatches() async throws {
    let environment = ProcessInfo.processInfo.environment
    let dir = URL(fileURLWithPath: try #require(environment["TOMA_GOLDEN_1C_DIR"]), isDirectory: true)
    let recording = environment["TOMA_GOLDEN_RECORD"] == "1"
    let url = dir.appending(path: "frames.bin.mix")
    let documentsURL = dir.appending(path: "documents", directoryHint: .isDirectory)
    let exists = FileManager.default.fileExists(atPath: url.path)
    if recording {
        try #require(
            EditDocument.currentVersion == 1, """
                The golden mix of 1c is of documents of 1b (documentVersion 1): it is recorded only from the commit that \
                closes milestone 1b, never from later code (plan 1c decision 2)
                """)
        try #require(!exists, "\(url.path) is already there: the golden mix of 1c is never recorded over another")
    } else {
        try #require(
            exists, """
                No golden mix at \(url.path): the golden files of 1c are recorded whole with `make golden-1c-record` from \
                the commit in \(dir.appending(path: "COMMIT").path), never from later code (plan 1c decision 2)
                """)
    }
    var bytes = Data()
    // Where each case starts in `bytes`, and its channels.
    var spans: [(name: String, start: Int, channels: Int)] = []
    // Every check is a `#require`: when recording, nothing is written unless they all passed.
    try await withTemporaryDirectory { tmp in
        for golden in GoldenDocuments.cases where golden.mixes {
            let project = try await GoldenDocuments.makeProject(golden.name, in: tmp)
            try #require(project.manifest.formatVersion == 3, "\(golden.name) is a package of format version 3")
            let document: EditDocument
            if recording {
                let made = try GoldenDocuments.makeDocument(golden.name, for: project)
                try #require(made.documentVersion == 1, "\(golden.name)'s document is of version 1")
                document = try EditDocument.decode(try ProjectJSON.encoder().encode(made))
                try #require(document == made, "\(golden.name)'s document decodes to itself")
            } else {
                document = try EditDocument.decode(try Data(contentsOf: documentsURL.appending(path: "\(golden.name).json")))
            }
            let samples = try await MP4Exporter.mixSamples(of: project, document: document, framesPerSecond: 60)
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
        1b document changed. Never record the golden files of 1c again from this code, only from the commit in \
        \(dir.appending(path: "COMMIT").path) when the system changed (plan 1c decision 2)
        """)
}
