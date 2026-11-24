// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import ProjectAPI

/// `toma validate`: whether Toma reads a package whole, and what is wrong with it (plan 4b, Task A4).
@Suite struct ProjectValidationTests {
    @MainActor @Test func aWholeProjectIsValid() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.transcribed(in: dir, environment: environment)
            let before = try treeHash(url)
            let report = await ProjectRunner.validate(url, environment: environment)
            #expect(report == ValidationReport(
                valid: true, formatVersion: Manifest.currentFormatVersion, documentVersion: EditDocument.currentVersion,
                problems: [], skippedEventLines: 0, missingFiles: []))
            #expect(try treeHash(url) == before)
        }
    }

    @MainActor @Test func validateReportsProblems() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let project = try await APIFixtures.package(in: dir)
            let package = project.package
            // A document edited by hand: a title of 201 characters, in the log's `create` and the snapshot.
            let ids = APIFixtures.IDs()
            var document = NewDocument.make(project: project, defaultStyle: .toma, makeID: { ids.make($0) })
            document.info = ProjectInfo(title: String(repeating: "a", count: ProjectInfo.titleLimit + 1), summary: "")
            document.logSequence = 1
            let line = try EditLogEntry.create(seq: 1, document: document, app: APIFixtures.app)
                .jsonLine(writingDocumentAt: EditDocument.currentVersion)
            try DurableFile.writeAtomically(Data((line + "\n").utf8), to: package.editLogURL)
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(document), to: package.editURL)
            // A segment that is not there.
            let segment = try #require(project.take.track("mic")?.segments.first?.file)
            try FileManager.default.removeItem(at: package.url.appending(path: segment))
            // A line of the event log that is not an event.
            let events = package.url.appending(path: "takes/\(project.take.id)/events.jsonl")
            let handle = try FileHandle(forWritingTo: events)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("this is not an event\n".utf8))
            try handle.close()
            let before = try treeHash(package.url)

            let report = await ProjectRunner.validate(package.url, environment: environment)
            #expect(!report.valid)
            #expect(report.formatVersion == Manifest.currentFormatVersion)
            #expect(report.documentVersion == EditDocument.currentVersion)
            #expect(report.problems == ["the title is longer than 200 characters"])
            #expect(report.missingFiles == [segment])
            #expect(report.skippedEventLines == 1)
            #expect(try treeHash(package.url) == before)
        }
    }

    @MainActor @Test func notAProjectIsNotValid() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let folder = dir.appending(path: "Plain.toma", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let report = await ProjectRunner.validate(folder, environment: environment)
            #expect(!report.valid && report.formatVersion == nil && report.documentVersion == nil)
            #expect(report.problems.count == 1 && report.problems[0].hasPrefix("notAProject: "))
            // A manifest of a newer version: its version is said.
            let newer = try await APIFixtures.package(in: dir, name: "Newer").package
            let manifest = String(decoding: try Data(contentsOf: newer.manifestURL), as: UTF8.self)
                .replacingOccurrences(of: "\"formatVersion\" : \(Manifest.currentFormatVersion)", with: "\"formatVersion\" : 99")
            try DurableFile.writeAtomically(Data(manifest.utf8), to: newer.manifestURL)
            let newerReport = await ProjectRunner.validate(newer.url, environment: environment)
            #expect(!newerReport.valid && newerReport.formatVersion == 99)
            #expect(newerReport.problems.first?.hasPrefix("newerVersion: ") == true)
        }
    }
}

/// What a read leaves out of the document as written, or would set aside, is said: by `validate`, `info`, the export
/// and the first edit (final review, area 1, I2).
@Suite struct WhatTheReadLeavesOutTests {
    /// `project` with `document` written as the log's `create` and the snapshot.
    private func write(_ document: EditDocument, into package: ProjectPackage) throws {
        var document = document
        document.logSequence = 1
        let line = try EditLogEntry.create(seq: 1, document: document, app: APIFixtures.app)
            .jsonLine(writingDocumentAt: EditDocument.currentVersion)
        try DurableFile.writeAtomically(Data((line + "\n").utf8), to: package.editLogURL)
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(document), to: package.editURL)
    }

    @MainActor @Test func aDocumentThatBreaksARuleIsNotValidAndSaysWhatIsLeftOut() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let project = try await APIFixtures.package(in: dir)
            let ids = APIFixtures.IDs()
            var document = NewDocument.make(project: project, defaultStyle: .toma, makeID: { ids.make($0) })
            // Music of a file outside `assets/`: the read leaves it out, and the editor opens the project read-only.
            document.music.items = [MusicCommands.newItem(id: "mu-00000001", source: "Music/x.m4a", output: 0..<APIFixtures.ns(5))]
            try write(document, into: project.package)
            let url = project.package.url

            let validation = await ProjectRunner.validate(url, environment: environment)
            #expect(!validation.valid)
            #expect(validation.problems.contains { $0.contains("Music/x.m4a") })
            let report = try await ProjectRunner.report(url, environment: environment)
            #expect(report.music.isEmpty)
            #expect(report.warnings?.contains { $0.contains("Music/x.m4a") && $0.contains("read-only") } == true)
            let edit = await ProjectRunner.apply([.setTitle("x")], to: url, environment: environment)
            #expect(edit.error?.code == .refused)
            #expect(edit.error?.message.contains("Music/x.m4a") == true)
            let export = try await ProjectRunner.export(
                url, to: dir.appending(path: "out.gif"), request: ExportRequest(kind: .gif, size: 480, fps: 10),
                environment: environment, progress: nil)
            #expect(export.warnings.contains { $0.contains("Music/x.m4a") })
        }
    }

    @MainActor @Test func anUnreadableSnapshotIsNotValidAndItsSettingAsideIsSaid() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let package = try await APIFixtures.package(in: dir).package
            try Data(#"{"documentVersion":5, garbage"#.utf8).write(to: package.editURL)

            let validation = await ProjectRunner.validate(package.url, environment: environment)
            #expect(!validation.valid)
            #expect(validation.problems.contains { $0.hasPrefix("edit.json cannot be read") })
            let report = try await ProjectRunner.report(package.url, environment: environment)
            #expect(report.warnings?.contains { $0.hasPrefix("edit.json cannot be read") } == true)

            let edit = await ProjectRunner.apply([.setTitle("Again"), .setSummary("Then")], to: package.url, environment: environment)
            #expect(edit.error == nil)
            #expect(edit.results.first?.warnings?.first?.contains("set aside") == true)
            #expect(edit.results.last?.warnings == nil)
            let names = try FileManager.default.contentsOfDirectory(atPath: package.url.path)
            #expect(names.contains { $0.hasPrefix("edit.json.damaged-") })
        }
    }

    @MainActor @Test func aDamagedLogIsSaidAsItIsReadAndRewritten() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.transcribed(in: dir, environment: environment)
            _ = await ProjectRunner.apply([.setTitle("Before")], to: url, environment: environment)
            let handle = try FileHandle(forWritingTo: ProjectPackage(url: url).editLogURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"do\",garbage\n".utf8))
            try handle.close()

            let report = try await ProjectRunner.report(url, environment: environment)
            #expect(report.info?.title == "Before")
            #expect(report.warnings?.contains { $0.hasPrefix("edit-log.jsonl is damaged") } == true)
            #expect(await !ProjectRunner.validate(url, environment: environment).valid)
            let edit = await ProjectRunner.apply([.setTitle("After")], to: url, environment: environment)
            #expect(edit.results.first?.warnings?.first?.hasPrefix("edit-log.jsonl was damaged") == true)
            #expect(try await ProjectRunner.report(url, environment: environment).warnings == nil)
        }
    }
}
