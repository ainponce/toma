// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Render
import Testing

/// Edit documents of milestone 1b (`documentVersion` 1) draw the same bytes from the code of the commit that closes 1b
/// to every later version of the render, once migrated (plan 1c decision 2). It runs only with `TOMA_GOLDEN_1C_DIR` set
/// (`make golden-1c`): the frames of every case of `GoldenDocuments`, its document read from `documents/<case>.json`
/// there (`EditDocument.decode`, which migrates it in 1c), drawn by `FrameRenderer(project:document:outputSize:)` at the
/// case's `outputSize` at its times, one after the other in the order of the cases, must equal `frames.bin` there byte
/// for byte. With `TOMA_GOLDEN_RECORD=1` as well (`make golden-1c-record`, only from that commit, with
/// `EditDocument.currentVersion` 1), it writes `documents/<case>.json` (`GoldenDocuments.makeDocument`, as 1b writes
/// `edit.json`), `frames.bin`, drawn from those documents as they decode, and `fixtures.sha` instead, once every check
/// passed, and never over files already there. Without the files and without the switch it fails: it never passes
/// without comparing.
///
/// Every run writes the cases' video again, with the hardware encoder alone, and the frames are drawn from it; so that a
/// difference tells the render from the encoder, as 1b's `goldenFramesMatch` does:
/// - `fixtures.sha` holds the digests of the cases' video the golden frames were drawn from
///   (`GoldenProjects.videoDigests`). With the video the same as those, a difference is the render's, and fails at once;
///   with other video, the encoder's, and the cases are written again.
/// - A difference draws the same packages again: other bytes the second time mean a render that is not deterministic,
///   which fails at once.
/// - The cases are written up to `golden1cAttempts` times while the difference can be the encoder's, each attempt told on
///   the standard output. A render that changed differs every time, so the gate still fails on it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_GOLDEN_1C_DIR"] != nil))
func golden1cFramesMatch() async throws {
    let environment = ProcessInfo.processInfo.environment
    let dir = URL(fileURLWithPath: try #require(environment["TOMA_GOLDEN_1C_DIR"]), isDirectory: true)
    let recording = environment["TOMA_GOLDEN_RECORD"] == "1"
    let framesURL = dir.appending(path: "frames.bin")
    let documentsURL = dir.appending(path: "documents", directoryHint: .isDirectory)
    let fixturesURL = dir.appending(path: "fixtures.sha")
    let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
    if recording {
        try #require(
            EditDocument.currentVersion == 1, """
                The golden files of 1c hold documents of 1b (documentVersion 1): they are recorded only from the commit \
                that closes milestone 1b, never from later code (plan 1c decision 2)
                """)
        for url in [framesURL, documentsURL, fixturesURL] {
            try #require(!exists(url), "\(url.path) is already there: the golden files of 1c are never recorded over others")
        }
        // Every check is a `#require`: nothing is written unless they all passed.
        let outcome = try await withTemporaryDirectory { tmp in
            try await golden1cOutcome(in: tmp, documents: nil, golden: nil, recordedDigests: nil)
        }
        guard case let .matched(bytes, digests, documents) = outcome else {
            Issue.record("recording drew no frames: \(outcome)")
            return
        }
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: false)
        for (name, json) in documents {
            try json.write(to: documentsURL.appending(path: "\(name).json"), options: .withoutOverwriting)
        }
        try Data(bytes).write(to: framesURL, options: .withoutOverwriting)
        try Data((digests.joined(separator: "\n") + "\n").utf8).write(to: fixturesURL, options: .withoutOverwriting)
        return
    }

    for url in [framesURL, documentsURL, fixturesURL] {
        try #require(
            exists(url), """
                No \(url.path): the golden files of 1c are recorded whole with `make golden-1c-record` from the commit in \
                \(dir.appending(path: "COMMIT").path), never from later code (plan 1c decision 2)
                """)
    }
    var documents: [String: EditDocument] = [:]
    for golden in GoldenDocuments.cases {
        let json = try Data(contentsOf: documentsURL.appending(path: "\(golden.name).json"))
        try #require(
            try ProjectJSON.decoder().decode(RecordedVersion.self, from: json).documentVersion == 1,
            "documents/\(golden.name).json is a document of 1b (documentVersion 1)")
        documents[golden.name] = try EditDocument.decode(json)
    }
    let recordedDigests = try String(contentsOf: fixturesURL, encoding: .utf8).split(separator: "\n").map(String.init)
    let golden = try Data(contentsOf: framesURL)
    var earlier: [String] = []
    for attempt in 1...golden1cAttempts {
        let outcome = try await withTemporaryDirectory { tmp in
            try await golden1cOutcome(in: tmp, documents: documents, golden: golden, recordedDigests: recordedDigests)
        }
        switch outcome {
        case let .matched(_, digests, _):
            if !earlier.isEmpty { print("golden 1c: the frames matched at attempt \(attempt) of \(golden1cAttempts)") }
            if digests != recordedDigests {
                let changes = golden1cChanges(from: recordedDigests, to: digests)
                print("golden 1c: the frames matched with video other than the recorded digests: \(changes)")
            }
            return
        case let .differs(reason, encoderMayExplainIt):
            guard encoderMayExplainIt, attempt < golden1cAttempts else {
                Issue.record("""
                    \(reason)\(earlier.isEmpty ? "" : "; earlier attempts: " + earlier.joined(separator: "; ")). Never \
                    record the golden files of 1c again from this code, only from the commit in \
                    \(dir.appending(path: "COMMIT").path) when the system changed (plan 1c decision 2)
                    """)
                return
            }
            earlier.append(reason)
            print("golden 1c: attempt \(attempt) of \(golden1cAttempts): \(reason); writing the cases again")
        }
    }
}

/// How many times `golden1cFramesMatch` writes the cases while a difference can be the encoder's.
private let golden1cAttempts = 3

/// The version a recorded document says it is, read before it is decoded (and, in 1c, migrated).
private struct RecordedVersion: Decodable {
    var documentVersion: Int
}

/// What one attempt of `golden1cFramesMatch` found.
private enum Golden1cOutcome {
    /// The frames drawn equal the golden ones (when recording, there are none to compare with), the digests of the cases'
    /// video, and the JSON of each case's document as it was drawn, by name (when recording, to be written).
    case matched(bytes: [UInt8], digests: [String], documents: [(name: String, json: Data)])
    /// They differ, as `reason` says, and whether the encoder may explain it (the cases may be written again).
    case differs(reason: String, encoderMayExplainIt: Bool)
}

/// One case as it is drawn: its take, its document and the times of its frames.
private struct Golden1cCase: Sendable {
    var name: String
    var project: LoadedProject
    var document: EditDocument
    var times: [Double]
}

/// Writes the cases of `GoldenDocuments` into `dir`, their video by the hardware encoder alone, and draws their frames
/// with `documents` (recorded, by name), or when recording (`nil`) with each case's `makeDocument` as its JSON decodes;
/// compares them with `golden` (none when recording), drawing them again and looking at `recordedDigests` when they differ.
private func golden1cOutcome(
    in dir: URL, documents: [String: EditDocument]?, golden: Data?, recordedDigests: [String]?
) async throws -> Golden1cOutcome {
    var cases: [Golden1cCase] = []
    var digests: [String] = []
    var jsons: [(name: String, json: Data)] = []
    for golden in GoldenDocuments.cases {
        let project = try await GoldenDocuments.makeProject(golden.name, in: dir)
        try #require(project.manifest.formatVersion == 3, "\(golden.name) is a package of format version 3")
        let document: EditDocument
        if let documents {
            document = try #require(documents[golden.name], "a document of \(golden.name)")
        } else {
            // Drawn as the recorded file decodes, which must be the document made.
            let made = try GoldenDocuments.makeDocument(golden.name, for: project)
            try #require(made.documentVersion == 1, "\(golden.name)'s document is of version 1")
            let json = try ProjectJSON.encoder().encode(made)
            document = try EditDocument.decode(json)
            try #require(document == made, "\(golden.name)'s document decodes to itself")
            jsons.append((golden.name, json))
        }
        digests += try await GoldenProjects.videoDigests(of: project).map { "\(golden.name) \($0)" }
        cases.append(Golden1cCase(name: golden.name, project: project, document: document, times: golden.times))
    }
    let bytes = try await golden1cFrames(of: cases)
    guard let golden else {
        // Recording: the same packages draw the same bytes again, or nothing is recorded.
        try #require(try await golden1cFrames(of: cases) == bytes, "the render is not deterministic: the same packages drew other bytes")
        return .matched(bytes: bytes, digests: digests, documents: jsons)
    }
    try #require(golden.count == bytes.count, "\(golden.count) bytes of golden frames, \(bytes.count) drawn")
    guard golden != Data(bytes) else { return .matched(bytes: bytes, digests: digests, documents: jsons) }

    let first = try #require(golden.indices.first { golden[$0] != bytes[$0] })
    var start = 0
    var place = "?"
    search: for c in cases {
        let size = GoldenDocuments.outputSize(of: c.document)
        let frameBytes = size.x * size.y * 4
        for time in c.times {
            if first < start + frameBytes {
                place = "\(c.name) at \(time) s (byte \(first - start) of its \(size.x) × \(size.y) frame)"
                break search
            }
            start += frameBytes
        }
    }
    let differing = zip(golden, bytes).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
    let difference = "\(differing) bytes differ, the first in \(place)"
    guard try await golden1cFrames(of: cases) == bytes else {
        return .differs(
            reason: "the render is not deterministic: the same packages drew other bytes the second time (\(difference))",
            encoderMayExplainIt: false)
    }
    guard let recordedDigests, digests == recordedDigests else {
        return .differs(
            reason: """
                the cases' video differs from the recorded digests, so the encoder and not the render: \
                \(golden1cChanges(from: recordedDigests ?? [], to: digests)) (\(difference))
                """,
            encoderMayExplainIt: true)
    }
    return .differs(
        reason: "the render of a 1b document changed: \(difference), drawn from video with the recorded digests",
        encoderMayExplainIt: false)
}

/// The frames of `cases`, drawn by a new `FrameRenderer` for each, of its document at its output size, at its times, off
/// the cooperative pool.
private func golden1cFrames(of cases: [Golden1cCase]) async throws -> [UInt8] {
    var bytes: [UInt8] = []
    for c in cases {
        let size = GoldenDocuments.outputSize(of: c.document)
        let renderer = try FrameRenderer(project: c.project, document: c.document, outputSize: size)
        try #require(c.times.allSatisfy { $0 < renderer.duration }, "\(c.name) lasts \(renderer.duration) s, its times are \(c.times)")
        let times = c.times
        let frames = try await offThePool { try times.flatMap { try renderer.renderBytes(at: $0) } }
        try #require(frames.count == times.count * size.x * size.y * 4, "\(c.name): \(frames.count) bytes of frames")
        bytes += frames
        try #require(renderer.missingVideo.isEmpty, "\(c.name): \(renderer.missingVideo)")
    }
    return bytes
}

/// The segments whose digest is not the recorded one, as `<case> <track> <segment> <recorded> → <now>` (12 digits).
private func golden1cChanges(from recorded: [String], to now: [String]) -> String {
    guard recorded.count == now.count else { return "\(recorded.count) segments recorded, \(now.count) written" }
    return zip(recorded, now).filter { $0 != $1 }.map { recorded, now in
        let old = recorded.split(separator: " "), new = now.split(separator: " ")
        return "\(new.dropLast().joined(separator: " ")) \(old.last?.prefix(12) ?? "?") → \(new.last?.prefix(12) ?? "?")"
    }.joined(separator: ", ")
}
