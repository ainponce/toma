// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app, the API and the AI use only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share: the title and the summary of a project (`InfoCommands`, fases 4 y 5 design §4.1),
/// and a project of phase 3 (its document in `documentVersion` 4) opened and given a title in phases 4 and 5, whose
/// document is of version 5.
private enum Info {
    static let app = AppInfo(name: "Toma", version: "0.5.0")
    /// The `at` of every step of the fixtures: 2026-11-15T20:12:03Z.
    static let date = Date(timeIntervalSince1970: 1_794_773_523)

    static let document = EditDocument.legacy(
        take: TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: []), events: [])

    static func applied(_ step: EditStep?, to document: EditDocument) throws -> EditDocument {
        try document.applying(try #require(step).changes)
    }

    static func context(caches: URL, io: EditJournalIO = .system) -> EditContext {
        let clock = Mutex(Date(timeIntervalSince1970: 1_794_780_000))
        let count = Mutex(0)
        return EditContext(
            app: AppInfo(name: "Toma", version: "0.6.0"), cachesRoot: caches, defaultStyle: .toma,
            now: { clock.withLock { date in
                defer { date += 2 }
                return date
            } },
            makeID: { prefix in count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            } },
            journalIO: io)
    }

    static func lines(_ url: URL) throws -> [String] {
        String(decoding: try Data(contentsOf: ProjectPackage(url: url).editLogURL), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// The marker the project of phase 3 adds, in a place only version 4 has.
    static let marker = Marker(id: "m-0000abcd", take: "take-001", t: HostTime(nanoseconds: 5_000_500_000_000), name: "Demo", origin: .added)

    /// A project edited in phase 3, as its app left it on disk: a take of 1 s, the `create` of its legacy document and
    /// three steps of the style and a marker after it, all in `documentVersion` 4, and `edit.json` after the last one,
    /// in 4 too (`<directory>/v4.toma`).
    @concurrent static func phase3Project(in directory: URL) async throws -> URL {
        let builder = try TakeBuilder(in: directory, name: "v4")
        let base = HostTime(nanoseconds: 5_000_000_000_000)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        let project = try builder.write()

        var document = EditDocument.legacy(for: project)
        document.logSequence = 1
        var lines = [try EditLogEntry.create(seq: 1, document: document, app: app).jsonLine(writingDocumentAt: 4)]
        for step in 1...4 {
            let seq = step + 1
            let label: String
            let change: EditChange
            if step <= 3 {
                label = DocumentV1Fixture.labels[step - 1]
                change = try #require(document.setChange(DocumentV1Fixture.paths[step - 1], 0.001 * Double(step) + 0.05))
            } else {
                label = EditLabel.markerAdd.rawValue
                change = document.insertChange(.markers, at: 0, marker)
            }
            lines.append(try EditLogEntry.do(seq: seq, group: seq, label: label, changes: [change], at: date).jsonLine())
            document = try document.applying([change])
            document.logSequence = seq
        }
        try DurableFile.writeAtomically(Data(lines.map { $0 + "\n" }.joined().utf8), to: project.package.editLogURL)
        let written = try #require(DocumentMigration.reverted(try JSONValue(encoding: document), to: 4))
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(written), to: project.package.editURL)
        return project.package.url
    }

    /// The system's calls, keeping the bytes of each write.
    final class Writes: Sendable {
        private let writes = Mutex<[[UInt8]]>([])

        var all: [[UInt8]] { writes.withLock { $0 } }

        var io: EditJournalIO {
            EditJournalIO(
                open: { try EditJournalIO.system.open($0, $1, $2) },
                write: { [self] descriptor, bytes in
                    let written = try EditJournalIO.system.write(descriptor, bytes)
                    writes.withLock { $0.append(Array(bytes[..<written])) }
                    return written
                },
                fullSync: { try EditJournalIO.system.fullSync($0) },
                fsync: { try EditJournalIO.system.fsync($0) },
                syncDirectory: { try EditJournalIO.system.syncDirectory($0) })
        }
    }
}

// MARK: - The commands

@Test func setTitleIsOneUndoStep() throws {
    let document = Info.document
    #expect(document.info == nil)
    // Trimmed, and one change of `/info`, from nothing.
    let step = try #require(InfoCommands.setTitle(document, "  Demo de Toma \n"))
    #expect(step.label == .projectTitle)
    #expect(step.target == "/info")
    let info = ProjectInfo(title: "Demo de Toma", summary: "")
    #expect(step.changes == [.set(path: try JSONPointer("/info"), before: .null, after: try JSONValue(encoding: info))])
    let titled = try Info.applied(step, to: document)
    #expect(titled.info == info)
    // Its inverse is the undo: back to no `info`.
    #expect(try titled.applying(step.changes.map(\.inverse)) == document)
    // The same title, however it is spaced, is nothing.
    #expect(InfoCommands.setTitle(titled, "Demo de Toma") == nil)
    #expect(InfoCommands.setTitle(titled, "\tDemo de Toma  ") == nil)
    // Typing in the field: each step has the same label and target, so the session joins them into one undo group.
    let typed = try #require(InfoCommands.setTitle(titled, "Demo de Toma 2"))
    #expect((typed.label, typed.target) == (step.label, step.target))
    #expect(try Info.applied(typed, to: titled).info == ProjectInfo(title: "Demo de Toma 2", summary: ""))
    // The summary is a step of its own, which keeps the title.
    let summary = try #require(InfoCommands.setSummary(titled, " Cómo grabar.\nEn dos minutos.  "))
    #expect(summary.label == .projectSummary)
    #expect(summary.target == "/info")
    let both = try Info.applied(summary, to: titled)
    #expect(both.info == ProjectInfo(title: "Demo de Toma", summary: "Cómo grabar.\nEn dos minutos."))
    #expect(InfoCommands.setSummary(both, "Cómo grabar.\nEn dos minutos.") == nil)
    // Held to the limits, so a step never leaves a document with a problem.
    let long = try Info.applied(InfoCommands.setTitle(both, String(repeating: "t", count: 250)), to: both)
    #expect(long.info?.title == String(repeating: "t", count: ProjectInfo.titleLimit))
    #expect(InfoCommands.setTitle(long, String(repeating: "t", count: 300)) == nil)
    let longer = try Info.applied(InfoCommands.setSummary(long, String(repeating: "s", count: 2500)), to: long)
    #expect(longer.info?.summary.count == ProjectInfo.summaryLimit)
    #expect(DocumentRules.problems(in: longer).isEmpty)
    // The labels are the last two, with their names in the log.
    #expect(EditLabel.projectTitle.rawValue == "project.title")
    #expect(EditLabel.projectSummary.rawValue == "project.summary")
    #expect(Array(EditLabel.allCases.suffix(3).prefix(2)) == [.projectTitle, .projectSummary])
}

@Test func emptyTitleAndSummaryRemoveInfo() throws {
    let document = Info.document
    // Nothing to remove: nothing.
    #expect(InfoCommands.setTitle(document, "") == nil)
    #expect(InfoCommands.setSummary(document, "  \n ") == nil)
    // A title alone, emptied: `info` goes away, as the legacy document has none.
    let titled = try Info.applied(InfoCommands.setTitle(document, "Demo"), to: document)
    let emptied = try #require(InfoCommands.setTitle(titled, "   "))
    #expect(emptied.changes == [.set(path: try JSONPointer("/info"), before: try JSONValue(encoding: titled.info), after: .null)])
    let untitled = try Info.applied(emptied, to: titled)
    #expect(untitled.info == nil)
    #expect(untitled == document)
    #expect(!String(decoding: try ProjectJSON.encoder().encode(untitled), as: UTF8.self).contains("\"info\""))
    // With a summary, an empty title keeps `info`; emptying the summary too takes it away.
    let both = try Info.applied(InfoCommands.setSummary(titled, "Resumen"), to: titled)
    let noTitle = try Info.applied(InfoCommands.setTitle(both, ""), to: both)
    #expect(noTitle.info == ProjectInfo(title: "", summary: "Resumen"))
    let none = try Info.applied(InfoCommands.setSummary(noTitle, " "), to: noTitle)
    #expect(none.info == nil)
    #expect(none == document)
}

// MARK: - A project of phase 3

@MainActor @Test func openingAVersion4DocumentWritesNothing() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await Info.phase3Project(in: dir)
        let package = ProjectPackage(url: url)
        let snapshot = try Data(contentsOf: package.editURL)
        let log = try Data(contentsOf: package.editLogURL)
        let unchanged = try treeHash(url)
        #expect(EditDocument.writtenVersion(of: snapshot) == 4)
        #expect(try EditLogReader.read(package.editLogURL).createVersion == 4)

        // Opened, read as the export reads it, and closed without an edit: version 5 in memory, nothing on disk.
        let context = Info.context(caches: dir.appending(path: "Caches"))
        let session = try await EditSession.open(url, take: nil, context: context)
        #expect(session.access == .editable)
        #expect(session.notices.isEmpty)
        #expect(session.document.documentVersion == 5)
        #expect(session.document.info == nil)
        #expect(session.document.zoom.auto.followsFocus == false)
        #expect(session.document.markers.items == [Info.marker])
        #expect(session.undoLabel == .markerAdd)
        #expect(!session.documentIsCurrentOnDisk)
        let (_, exported, diskVersion) = try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context)
        #expect(diskVersion == 4)
        #expect(exported == session.document)
        #expect(await session.flushed() == 5)
        #expect(!session.hasUnsavedChanges)
        await session.close()
        #expect(try Data(contentsOf: package.editURL) == snapshot)
        #expect(try Data(contentsOf: package.editLogURL) == log)
        #expect(try treeHash(url) == unchanged)
        // Twice, the same.
        let again = try await EditSession.open(url, take: nil, context: context)
        #expect(again.document == session.document)
        await again.close()
        #expect(try treeHash(url) == unchanged)
    }
}

@MainActor @Test func firstEditOfAVersion4WritesMigrateAndTheStep() async throws {
    try await withTemporaryDirectory { dir in
        let url = try await Info.phase3Project(in: dir)
        let package = ProjectPackage(url: url)
        let before = try Info.lines(url)
        #expect(before.count == 5)
        let writes = Info.Writes()
        let caches = dir.appending(path: "Caches")
        let session = try await EditSession.open(url, take: nil, context: Info.context(caches: caches, io: writes.io))
        #expect(writes.all.isEmpty)
        let step = try #require(InfoCommands.setTitle(session.document, "Demo de Toma"))
        #expect(session.perform(step) == .applied)
        #expect(session.document.info == ProjectInfo(title: "Demo de Toma", summary: ""))
        #expect(await session.flushed() == 7)

        // The `migrate` from 4 to 5 and the step, in one write after the lines of phase 3.
        let lines = try Info.lines(url)
        #expect(Array(lines.prefix(5)) == before)
        #expect(lines.count == 7)
        let entries = try EditLogReader.read(package.editLogURL).entries
        #expect(entries[5] == .migrate(seq: 6, from: 4, to: 5))
        #expect(lines[5] == #"{"from":4,"seq":6,"to":5,"type":"migrate"}"#)
        if case let .do(seq, group, label, changes, _) = entries[6] {
            #expect((seq, group, label) == (7, 7, "project.title"))
            #expect(changes == step.changes)
        } else {
            Issue.record("no do line: \(entries)")
        }
        #expect(writes.all.count == 1)
        #expect(writes.all.first == Array(lines.dropFirst(5).map { $0 + "\n" }.joined().utf8))
        #expect(try EditLogReader.read(package.editLogURL).createVersion == 4)

        // One undo takes the title away, never the migration; the snapshot at closing is of version 5.
        #expect(session.undoLabel == .projectTitle)
        #expect(session.undo() == .applied)
        #expect(session.document.info == nil)
        #expect(session.document.documentVersion == 5)
        #expect(session.undoLabel == .markerAdd)
        #expect(session.redo() == .applied)
        #expect(await session.flushed() == 9)
        await session.close()
        let snapshot = try Data(contentsOf: package.editURL)
        #expect(EditDocument.writtenVersion(of: snapshot) == 5)
        let text = String(decoding: snapshot, as: UTF8.self)
        #expect(text.contains("\"followsFocus\" : false"))
        #expect(text.contains("\"title\" : \"Demo de Toma\""))
        #expect(try EditDocument.decode(snapshot) == session.document)
        let context = Info.context(caches: caches)
        #expect(try EditSession.readDocumentWithDiskVersion(url, take: nil, context: context).diskVersion == 5)
        let reopened = try await EditSession.open(url, take: nil, context: context)
        #expect(reopened.documentIsCurrentOnDisk)
        #expect(reopened.document.info == ProjectInfo(title: "Demo de Toma", summary: ""))
        await reopened.close()
    }
}
