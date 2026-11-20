// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Render
import Testing

/// Edit documents of milestones 1b and 1c and of phase 2 (`documentVersion` 1, 2 and 3) draw the same bytes from the code
/// of the branch `golden-3-base` (`main` with only test code and the `Makefile` changed) to every later version of the
/// render, once migrated (phase 3 design §16, "golden 3"). It runs only with `TOMA_GOLDEN_3_DIR` set (`make golden-3`):
/// the frames of every case of `GoldenDocuments.golden3Cases`, its document read from `documents/<case>.json` there
/// (`EditDocument.decode`, which migrates it in phase 3), drawn by `FrameRenderer(project:document:outputSize:)` at the
/// case's `outputSize(of:document:project:)` at its times, one after the other in the order of the cases, must equal
/// `frames.bin` there byte for byte. With `TOMA_GOLDEN_RECORD=1` as well (`make golden-3-record`, only from that branch,
/// with `EditDocument.currentVersion` 3), it writes `documents/<case>.json` (`GoldenDocuments.makeDocument`, as the app
/// writes `edit.json`: a case of 1b reverted to `documentVersion` 1, one of 1c to 2, one of phase 2 in 3), `frames.bin`,
/// drawn from those documents as they decode, and `fixtures.sha` instead, once every check passed, and never over files
/// already there. Without the files and without the switch it fails: it never passes without comparing.
///
/// Every run writes the cases' video again, with the hardware encoder alone, and the frames are drawn from it; so that a
/// difference tells the render from the encoder, as `golden2FramesMatch` does:
/// - `fixtures.sha` holds the digests of the cases' video the golden frames were drawn from
///   (`GoldenProjects.videoDigests`). With the video the same as those, a difference is the render's, and fails at once;
///   with other video, the encoder's, and the cases are written again.
/// - A difference draws the same packages again: other bytes the second time mean a render that is not deterministic,
///   which fails at once.
/// - The cases are written up to `golden3Attempts` times while the difference can be the encoder's, each attempt told on
///   the standard output. A render that changed differs every time, so the gate still fails on it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_GOLDEN_3_DIR"] != nil))
func golden3FramesMatch() async throws {
    let environment = ProcessInfo.processInfo.environment
    let dir = URL(fileURLWithPath: try #require(environment["TOMA_GOLDEN_3_DIR"]), isDirectory: true)
    let recording = environment["TOMA_GOLDEN_RECORD"] == "1"
    let framesURL = dir.appending(path: "frames.bin")
    let documentsURL = dir.appending(path: "documents", directoryHint: .isDirectory)
    let fixturesURL = dir.appending(path: "fixtures.sha")
    let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
    if recording {
        try #require(
            EditDocument.currentVersion == 3, """
                The golden files of phase 3 hold documents of 1b, 1c and phase 2 (documentVersion 1 to 3): they are \
                recorded only from the branch golden-3-base, never from later code (phase 3 design §16)
                """)
        for url in [framesURL, documentsURL, fixturesURL] {
            try #require(!exists(url), "\(url.path) is already there: the golden files of phase 3 are never recorded over others")
        }
        // Every check is a `#require`: nothing is written unless they all passed.
        let outcome = try await withTemporaryDirectory { tmp in
            try await golden3Outcome(in: tmp, documents: nil, golden: nil, recordedDigests: nil)
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
                No \(url.path): the golden files of phase 3 are recorded whole with `make golden-3-record` from the commit \
                in \(dir.appending(path: "COMMIT").path), never from later code (phase 3 design §16)
                """)
    }
    var documents: [String: EditDocument] = [:]
    for golden in GoldenDocuments.golden3Cases {
        let json = try Data(contentsOf: documentsURL.appending(path: "\(golden.name).json"))
        try #require(
            try ProjectJSON.decoder().decode(RecordedVersion.self, from: json).documentVersion == golden.documentVersion,
            "documents/\(golden.name).json is a document of version \(golden.documentVersion)")
        documents[golden.name] = try EditDocument.decode(json)
    }
    let recordedDigests = try String(contentsOf: fixturesURL, encoding: .utf8).split(separator: "\n").map(String.init)
    let golden = try Data(contentsOf: framesURL)
    var earlier: [String] = []
    for attempt in 1...golden3Attempts {
        let outcome = try await withTemporaryDirectory { tmp in
            try await golden3Outcome(in: tmp, documents: documents, golden: golden, recordedDigests: recordedDigests)
        }
        switch outcome {
        case let .matched(_, digests, _):
            if !earlier.isEmpty { print("golden 3: the frames matched at attempt \(attempt) of \(golden3Attempts)") }
            if digests != recordedDigests {
                let changes = golden3Changes(from: recordedDigests, to: digests)
                print("golden 3: the frames matched with video other than the recorded digests: \(changes)")
            }
            return
        case let .differs(reason, encoderMayExplainIt):
            guard encoderMayExplainIt, attempt < golden3Attempts else {
                Issue.record("""
                    \(reason)\(earlier.isEmpty ? "" : "; earlier attempts: " + earlier.joined(separator: "; ")). Never \
                    record the golden files of phase 3 again from this code, only from the commit in \
                    \(dir.appending(path: "COMMIT").path) when the system changed (phase 3 design §16)
                    """)
                return
            }
            earlier.append(reason)
            print("golden 3: attempt \(attempt) of \(golden3Attempts): \(reason); writing the cases again")
        }
    }
}

/// How many times `golden3FramesMatch` writes the cases while a difference can be the encoder's.
private let golden3Attempts = 3

/// The version a recorded document says it is, read before it is decoded (and migrated).
private struct RecordedVersion: Decodable {
    var documentVersion: Int
}

/// What one attempt of `golden3FramesMatch` found.
private enum Golden3Outcome {
    /// The frames drawn equal the golden ones (when recording, there are none to compare with), the digests of the cases'
    /// video, and the JSON of each case's document as it was drawn, by name (when recording, to be written).
    case matched(bytes: [UInt8], digests: [String], documents: [(name: String, json: Data)])
    /// They differ, as `reason` says, and whether the encoder may explain it (the cases may be written again).
    case differs(reason: String, encoderMayExplainIt: Bool)
}

/// One case as it is drawn: its take, its document, the times of its frames and their size.
private struct Golden3Case: Sendable {
    var name: String
    var project: LoadedProject
    var document: EditDocument
    var times: [Double]
    var size: SIMD2<Int>
}

/// Writes the cases of `GoldenDocuments.golden3Cases` into `dir`, their video by the hardware encoder alone, and draws
/// their frames with `documents` (recorded, by name), or when recording (`nil`) with each case's `makeDocument` as its
/// recorded JSON decodes; compares them with `golden` (none when recording), drawing them again and looking at
/// `recordedDigests` when they differ.
private func golden3Outcome(
    in dir: URL, documents: [String: EditDocument]?, golden: Data?, recordedDigests: [String]?
) async throws -> Golden3Outcome {
    var cases: [Golden3Case] = []
    var digests: [String] = []
    var jsons: [(name: String, json: Data)] = []
    for golden in GoldenDocuments.golden3Cases {
        let project = try await GoldenDocuments.makeProject(golden.name, in: dir)
        try #require(
            project.manifest.formatVersion == golden.formatVersion, "\(golden.name) is a package of format version \(golden.formatVersion)")
        let document: EditDocument
        if let documents {
            document = try #require(documents[golden.name], "a document of \(golden.name)")
        } else {
            // Drawn as the recorded file decodes, which must be the document made.
            let made = try GoldenDocuments.makeDocument(golden.name, for: project)
            try #require(made.documentVersion == 3, "\(golden.name)'s document is of version 3, as main writes it")
            let json = try GoldenDocuments.recordedJSON(of: made, for: golden)
            try #require(
                try ProjectJSON.decoder().decode(RecordedVersion.self, from: json).documentVersion == golden.documentVersion,
                "\(golden.name)'s document is recorded in version \(golden.documentVersion)")
            document = try EditDocument.decode(json)
            try #require(document == made, "\(golden.name)'s recorded document decodes to the one made")
            jsons.append((golden.name, json))
        }
        digests += try await GoldenProjects.videoDigests(of: project).map { "\(golden.name) \($0)" }
        cases.append(Golden3Case(
            name: golden.name, project: project, document: document, times: golden.times,
            size: GoldenDocuments.outputSize(of: golden, document: document, project: project)))
    }
    let bytes = try await golden3Frames(of: cases)
    guard let golden else {
        // Recording: the same packages draw the same bytes again, or nothing is recorded.
        try #require(try await golden3Frames(of: cases) == bytes, "the render is not deterministic: the same packages drew other bytes")
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
    guard try await golden3Frames(of: cases) == bytes else {
        return .differs(
            reason: "the render is not deterministic: the same packages drew other bytes the second time (\(difference))",
            encoderMayExplainIt: false)
    }
    guard let recordedDigests, digests == recordedDigests else {
        return .differs(
            reason: """
                the cases' video differs from the recorded digests, so the encoder and not the render: \
                \(golden3Changes(from: recordedDigests ?? [], to: digests)) (\(difference))
                """,
            encoderMayExplainIt: true)
    }
    return .differs(
        reason: "the render of a 1b, 1c or phase-2 document changed: \(difference), drawn from video with the recorded digests",
        encoderMayExplainIt: false)
}

/// The frames of `cases`, drawn by a new `FrameRenderer` for each, of its document at its output size, at its times, off
/// the cooperative pool.
private func golden3Frames(of cases: [Golden3Case]) async throws -> [UInt8] {
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

/// The segments whose digest is not the recorded one, as `<case> <track> <segment> <recorded> → <now>` (12 digits).
private func golden3Changes(from recorded: [String], to now: [String]) -> String {
    guard recorded.count == now.count else { return "\(recorded.count) segments recorded, \(now.count) written" }
    return zip(recorded, now).filter { $0 != $1 }.map { recorded, now in
        let old = recorded.split(separator: " "), new = now.split(separator: " ")
        return "\(new.dropLast().joined(separator: " ")) \(old.last?.prefix(12) ?? "?") → \(new.last?.prefix(12) ?? "?")"
    }.joined(separator: ", ")
}
