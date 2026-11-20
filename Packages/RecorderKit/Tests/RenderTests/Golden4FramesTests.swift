// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Render
import Testing

/// Edit documents of milestones 1b and 1c and of phases 2 and 3 (`documentVersion` 1 to 4) draw the same bytes from the
/// code of phase 3 (the commit of the base of phases 4 and 5 before document 5) to every later version of the render,
/// once migrated (phases 4 and 5 design §4.2, "golden 4"). It runs only with `TOMA_GOLDEN_4_DIR` set (`make golden-4`):
/// the frames of every case of `GoldenPhase3Project.golden4Cases` (golden 3's, then the project of phase 3), its
/// document read from `documents/<case>.json` there (`EditDocument.decode`, which migrates it in phases 4 and 5), drawn
/// by `FrameRenderer(project:document:outputSize:)` at the case's `GoldenDocuments.outputSize(of:document:project:)` at
/// its times, one after the other in the order of the cases, must equal `frames.bin` there byte for byte. With
/// `TOMA_GOLDEN_RECORD=1` as well (`make golden-4-record`, only from a commit with `EditDocument.currentVersion` 4), it
/// writes `documents/<case>.json` (`GoldenPhase3Project.makeDocument(_:for:)`, as the app writes `edit.json`: a case of
/// 1b reverted to `documentVersion` 1, one of 1c to 2, one of phase 2 to 3, the project of phase 3 in 4), `frames.bin`,
/// drawn from those documents as they decode, and `fixtures.sha` instead, once every check passed, and never over files
/// already there. Without the files and without the switch it fails: it never passes without comparing.
///
/// Every run writes the cases' video again, with the hardware encoder alone, and the frames are drawn from it; so that
/// a difference tells the render from the encoder, as `golden3FramesMatch` does:
/// - `fixtures.sha` holds the digests of the video the golden frames were drawn from
///   (`GoldenPhase3Project.videoDigests(_:of:)`: the takes' segments, and the imported clip of the project of phase 3).
///   With the video the same as those, a difference is the render's, and fails at once; with other video, the
///   encoder's, and the cases are written again.
/// - A difference draws the same packages again: other bytes the second time mean a render that is not deterministic,
///   which fails at once.
/// - The cases are written up to `golden4Attempts` times while the difference can be the encoder's, each attempt told
///   on the standard output. A render that changed differs every time, so the gate still fails on it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_GOLDEN_4_DIR"] != nil))
func golden4FramesMatch() async throws {
    let environment = ProcessInfo.processInfo.environment
    let dir = URL(fileURLWithPath: try #require(environment["TOMA_GOLDEN_4_DIR"]), isDirectory: true)
    let recording = environment["TOMA_GOLDEN_RECORD"] == "1"
    let framesURL = dir.appending(path: "frames.bin")
    let documentsURL = dir.appending(path: "documents", directoryHint: .isDirectory)
    let fixturesURL = dir.appending(path: "fixtures.sha")
    let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
    if recording {
        try #require(
            EditDocument.currentVersion == 4, """
                The golden files of golden 4 hold documents of 1b, 1c and phases 2 and 3 (documentVersion 1 to 4): they \
                are recorded only from a commit of phase 3's document, never from later code (phases 4 and 5 design §4.2)
                """)
        for url in [framesURL, documentsURL, fixturesURL] {
            try #require(!exists(url), "\(url.path) is already there: the golden files of golden 4 are never recorded over others")
        }
        // Every check is a `#require`: nothing is written unless they all passed.
        let outcome = try await withTemporaryDirectory { tmp in
            try await golden4Outcome(in: tmp, documents: nil, golden: nil, recordedDigests: nil)
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
                No \(url.path): the golden files of golden 4 are recorded whole with `make golden-4-record` from the commit \
                in \(dir.appending(path: "COMMIT").path), never from later code (phases 4 and 5 design §4.2)
                """)
    }
    var documents: [String: EditDocument] = [:]
    for golden in GoldenPhase3Project.golden4Cases {
        let json = try Data(contentsOf: documentsURL.appending(path: "\(golden.name).json"))
        try #require(
            try ProjectJSON.decoder().decode(RecordedVersion.self, from: json).documentVersion == golden.documentVersion,
            "documents/\(golden.name).json is a document of version \(golden.documentVersion)")
        documents[golden.name] = try EditDocument.decode(json)
    }
    let recordedDigests = try String(contentsOf: fixturesURL, encoding: .utf8).split(separator: "\n").map(String.init)
    let golden = try Data(contentsOf: framesURL)
    var earlier: [String] = []
    for attempt in 1...golden4Attempts {
        let outcome = try await withTemporaryDirectory { tmp in
            try await golden4Outcome(in: tmp, documents: documents, golden: golden, recordedDigests: recordedDigests)
        }
        switch outcome {
        case let .matched(_, digests, _):
            if !earlier.isEmpty { print("golden 4: the frames matched at attempt \(attempt) of \(golden4Attempts)") }
            if digests != recordedDigests {
                let changes = golden4Changes(from: recordedDigests, to: digests)
                print("golden 4: the frames matched with video other than the recorded digests: \(changes)")
            }
            return
        case let .differs(reason, encoderMayExplainIt):
            guard encoderMayExplainIt, attempt < golden4Attempts else {
                Issue.record("""
                    \(reason)\(earlier.isEmpty ? "" : "; earlier attempts: " + earlier.joined(separator: "; ")). Never \
                    record the golden files of golden 4 again from this code, only from the commit in \
                    \(dir.appending(path: "COMMIT").path) when the system changed (phases 4 and 5 design §4.2)
                    """)
                return
            }
            earlier.append(reason)
            print("golden 4: attempt \(attempt) of \(golden4Attempts): \(reason); writing the cases again")
        }
    }
}

/// Every document golden 4 holds (of milestones 1b and 1c and of phases 2 and 3, as the app of phase 3 wrote them),
/// read from `documents/<case>.json` of `TOMA_GOLDEN_4_DIR` (`make golden-4`), is still that document byte for byte:
/// decoded (migrated to `EditDocument.currentVersion`) and written back in its own version
/// (`GoldenDocuments.recordedJSON(of:for:)`, `DocumentMigration.reverted(_:to:)` for an older one), it gives the bytes
/// on disk, so the migration adds nothing a document of those versions did not have; and, migrated, it keeps every rule
/// of the document (`DocumentRules.problems(in:)`, so none of them opens read-only), a document of phases 1 and 2 with
/// its sound cut with its picture. Not while recording (`TOMA_GOLDEN_RECORD=1`): `golden4FramesMatch` writes them then.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_GOLDEN_4_DIR"] != nil
    && ProcessInfo.processInfo.environment["TOMA_GOLDEN_RECORD"] != "1"))
func golden4DocumentsMatch() throws {
    let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TOMA_GOLDEN_4_DIR"]), isDirectory: true)
    let documentsURL = dir.appending(path: "documents", directoryHint: .isDirectory)
    try #require(
        FileManager.default.fileExists(atPath: documentsURL.path), """
            No \(documentsURL.path): the golden files of golden 4 are recorded whole with `make golden-4-record` from the \
            commit in \(dir.appending(path: "COMMIT").path), never from later code (phases 4 and 5 design §4.2)
            """)
    for golden in GoldenPhase3Project.golden4Cases {
        let json = try Data(contentsOf: documentsURL.appending(path: "\(golden.name).json"))
        try #require(
            try ProjectJSON.decoder().decode(RecordedVersion.self, from: json).documentVersion == golden.documentVersion,
            "documents/\(golden.name).json is a document of version \(golden.documentVersion)")
        let document = try EditDocument.decode(json)
        #expect(document.documentVersion == EditDocument.currentVersion, "\(golden.name) decodes migrated")
        let written = try GoldenDocuments.recordedJSON(of: document, for: golden)
        #expect(
            written == json, """
                documents/\(golden.name).json, migrated to version \(EditDocument.currentVersion) and written back in \
                version \(golden.documentVersion), is not the same bytes: \(json.count) on disk, \(written.count) written
                """)
        #expect(DocumentRules.problems(in: document) == [], "\(golden.name)")
        if golden.documentVersion < 4 {
            let map = TimeMap(sequence: document.sequence)
            #expect(map.audioStarts == map.clipOutputStarts, "\(golden.name)")
        }
    }
}

/// How many times `golden4FramesMatch` writes the cases while a difference can be the encoder's.
private let golden4Attempts = 3

/// The version a recorded document says it is, read before it is decoded (and migrated).
private struct RecordedVersion: Decodable {
    var documentVersion: Int
}

/// What one attempt of `golden4FramesMatch` found.
private enum Golden4Outcome {
    /// The frames drawn equal the golden ones (when recording, there are none to compare with), the digests of the
    /// cases' video, and the JSON of each case's document as it was drawn, by name (when recording, to be written).
    case matched(bytes: [UInt8], digests: [String], documents: [(name: String, json: Data)])
    /// They differ, as `reason` says, and whether the encoder may explain it (the cases may be written again).
    case differs(reason: String, encoderMayExplainIt: Bool)
}

/// One case as it is drawn: its package, its document, the times of its frames and their size.
private struct Golden4Case: Sendable {
    var name: String
    var project: LoadedProject
    var document: EditDocument
    var times: [Double]
    var size: SIMD2<Int>
}

/// Writes the cases of `GoldenPhase3Project.golden4Cases` into `dir`, their video by the hardware encoder alone, and
/// draws their frames with `documents` (recorded, by name), or when recording (`nil`) with each case's `makeDocument`
/// as its recorded JSON decodes; compares them with `golden` (none when recording), drawing them again and looking at
/// `recordedDigests` when they differ.
private func golden4Outcome(
    in dir: URL, documents: [String: EditDocument]?, golden: Data?, recordedDigests: [String]?
) async throws -> Golden4Outcome {
    var cases: [Golden4Case] = []
    var digests: [String] = []
    var jsons: [(name: String, json: Data)] = []
    for golden in GoldenPhase3Project.golden4Cases {
        let project = try await GoldenPhase3Project.makeProject(golden.name, in: dir)
        try #require(
            project.manifest.formatVersion == golden.formatVersion, "\(golden.name) is a package of format version \(golden.formatVersion)")
        let document: EditDocument
        if let documents {
            document = try #require(documents[golden.name], "a document of \(golden.name)")
        } else {
            // Drawn as the recorded file decodes, which must be the document made.
            let made = try GoldenPhase3Project.makeDocument(golden.name, for: project)
            try #require(made.documentVersion == 4, "\(golden.name)'s document is of version 4, as phase 3 writes it")
            let json = try GoldenDocuments.recordedJSON(of: made, for: golden)
            try #require(
                try ProjectJSON.decoder().decode(RecordedVersion.self, from: json).documentVersion == golden.documentVersion,
                "\(golden.name)'s document is recorded in version \(golden.documentVersion)")
            document = try EditDocument.decode(json)
            try #require(document == made, "\(golden.name)'s recorded document decodes to the one made")
            jsons.append((golden.name, json))
        }
        digests += try await GoldenPhase3Project.videoDigests(golden.name, of: project).map { "\(golden.name) \($0)" }
        cases.append(Golden4Case(
            name: golden.name, project: project, document: document, times: golden.times,
            size: GoldenDocuments.outputSize(of: golden, document: document, project: project)))
    }
    let bytes = try await golden4Frames(of: cases)
    guard let golden else {
        // Recording: the same packages draw the same bytes again, or nothing is recorded.
        try #require(try await golden4Frames(of: cases) == bytes, "the render is not deterministic: the same packages drew other bytes")
        return .matched(bytes: bytes, digests: digests, documents: jsons)
    }
    try #require(golden.count == bytes.count, "\(golden.count) bytes of golden frames, \(bytes.count) drawn")
    guard golden != Data(bytes) else { return .matched(bytes: bytes, digests: digests, documents: jsons) }

    let first = try #require(golden.indices.first { golden[$0] != bytes[$0] })
    var start = 0
    var place = "?"
    search: for c in cases {
        let size = c.size
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
    guard try await golden4Frames(of: cases) == bytes else {
        return .differs(
            reason: "the render is not deterministic: the same packages drew other bytes the second time (\(difference))",
            encoderMayExplainIt: false)
    }
    guard let recordedDigests, digests == recordedDigests else {
        return .differs(
            reason: """
                the cases' video differs from the recorded digests, so the encoder and not the render: \
                \(golden4Changes(from: recordedDigests ?? [], to: digests)) (\(difference))
                """,
            encoderMayExplainIt: true)
    }
    return .differs(
        reason: "the render of a 1b, 1c, phase-2 or phase-3 document changed: \(difference), drawn from video with the recorded digests",
        encoderMayExplainIt: false)
}

/// The frames of `cases`, drawn by a new `FrameRenderer` for each, of its document at its output size, at its times,
/// off the cooperative pool.
private func golden4Frames(of cases: [Golden4Case]) async throws -> [UInt8] {
    var bytes: [UInt8] = []
    for c in cases {
        let size = c.size
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

/// The video whose digest is not the recorded one, as `<case> <file> <recorded> → <now>` (12 digits).
private func golden4Changes(from recorded: [String], to now: [String]) -> String {
    guard recorded.count == now.count else { return "\(recorded.count) files recorded, \(now.count) written" }
    return zip(recorded, now).filter { $0 != $1 }.map { recorded, now in
        let old = recorded.split(separator: " "), new = now.split(separator: " ")
        return "\(new.dropLast().joined(separator: " ")) \(old.last?.prefix(12) ?? "?") → \(new.last?.prefix(12) ?? "?")"
    }.joined(separator: ", ")
}
