// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// A project edited in milestone 1b, as the app of 1b left it on disk (1c design §13.2): its edit document of
/// `documentVersion` 1, which this app reads migrated to version 2.
public enum DocumentV1Fixture {
    /// The app the `create` line names.
    public static let app = AppInfo(name: "Toma", version: "0.2.0")
    /// The `at` of every step: 2026-11-15T20:12:03Z, in whole seconds as a `do` line keeps it.
    public static let date = Date(timeIntervalSince1970: 1_794_773_523)

    /// The places the steps change, in turn: the padding, the corners and the shadow, which 1b writes the same way.
    public static let paths = ["/style/padding", "/style/cornerRadius", "/style/shadow"]
    /// The labels of those steps (`EditLabel` of the editor).
    public static let labels = ["style.padding", "style.cornerRadius", "style.shadow"]

    /// Writes `<directory>/1b-<steps>-<snapshotAt>.toma`, a version 3 package of `TakeBuilder` with a take of 1 s of one
    /// display, and returns its URL. Its `edit-log.jsonl` holds the `create` (`seq` 1) of the take's legacy document in
    /// version 1 and `steps` steps after it, step `k` with `seq` and group `k + 1`: the padding, the corners and the
    /// shadow in turn, each to a value of its own. With `snapshotAt`, its `edit.json` is the document after that many
    /// steps (0: the `create`'s), in version 1, with the `logSequence` of that step, `snapshotAt + 1`; `snapshotAt ==
    /// steps` is a snapshot of the last line. Everything is written as 1b writes it: the `create` with
    /// `jsonLine(writingDocumentAt: 1)` and `edit.json` with `DocumentMigration.reverted(_:to: 1)`.
    @concurrent public static func make(in directory: URL, steps: Int, snapshotAt: Int?) async throws -> URL {
        let builder = try TakeBuilder(in: directory, name: "1b-\(steps)-\(snapshotAt.map(String.init) ?? "none")")
        let base = HostTime(nanoseconds: 5_000_000_000_000)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        let project = try builder.write()

        var document = EditDocument.legacy(for: project)
        document.logSequence = 1
        var lines = [try EditLogEntry.create(seq: 1, document: document, app: app).jsonLine(writingDocumentAt: 1)]
        var snapshot = snapshotAt == 0 ? document : nil
        for step in stride(from: 1, through: steps, by: 1) {
            let seq = step + 1
            let index = (step - 1) % paths.count
            let change = try unwrap(document.setChange(paths[index], 0.001 * Double(step) + 0.05), "the change of step \(step)")
            lines.append(
                try EditLogEntry.do(seq: seq, group: seq, label: labels[index], changes: [change], at: date).jsonLine())
            document = try document.applying([change])
            document.logSequence = seq
            if step == snapshotAt { snapshot = document }
        }
        try DurableFile.writeAtomically(Data(lines.map { $0 + "\n" }.joined().utf8), to: project.package.editLogURL)
        if let snapshotAt {
            let taken = try unwrap(snapshot, "the document after \(snapshotAt) of \(steps) steps")
            let written = try unwrap(
                DocumentMigration.reverted(try JSONValue(encoding: taken), to: 1), "the snapshot in version 1")
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(written), to: project.package.editURL)
        }
        return project.package.url
    }
}
