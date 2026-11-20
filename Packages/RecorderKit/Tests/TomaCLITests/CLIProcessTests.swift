// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import ProjectAPI
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// The `toma` that is built, run as a process (plan 4b, Task A4): its exit codes, its one JSON document on standard
/// output, and what it does to a project. Every `TOMA_*` variable is a temporary folder: nothing of the user's.
@Suite struct CLIProcessTests {
    @Test func versionIs1_0() async throws {
        try await withTemporaryDirectory { dir in
            let run = try await CLIFixtures.toma(["--version"], in: dir)
            #expect(run.status == 0)
            #expect(run.stdout == "1.0\n")
            #expect(run.stderr.isEmpty)
        }
    }

    @MainActor @Test func infoJSONIsTheReport() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let run = try await CLIFixtures.toma(["info", url.path, "--json"], in: dir)
            #expect(run.status == 0, "\(run.stderr)")
            let decoded = try ProjectJSON.decoder().decode(ProjectReport.self, from: Data(run.stdout.utf8))
            let report = try await ProjectRunner.report(url, environment: CLIFixtures.environment(in: dir))
            // A project never edited has a new document each time it is read, whose clips get new ids.
            #expect(Self.withoutClipIDs(decoded) == Self.withoutClipIDs(report))
            #expect(decoded.markers.count == 2)
            // A relative path, from the working directory.
            let relative = try await CLIFixtures.toma(["info", "Fixture.toma", "--json"], in: dir)
            let fromHere = try ProjectJSON.decoder().decode(ProjectReport.self, from: Data(relative.stdout.utf8))
            #expect(Self.withoutClipIDs(fromHere) == Self.withoutClipIDs(report))
            // Once edited, the same document every time.
            #expect(try await CLIFixtures.toma(["edit", url.path, #"{"command":"setTitle","title":"Mine"}"#], in: dir).status == 0)
            let edited = try await CLIFixtures.toma(["info", url.path, "--json"], in: dir)
            let after = try await ProjectRunner.report(url, environment: CLIFixtures.environment(in: dir))
            #expect(try ProjectJSON.decoder().decode(ProjectReport.self, from: Data(edited.stdout.utf8)) == after)
        }
    }

    @MainActor @Test func exitCodes() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            #expect(try await CLIFixtures.toma(["info", url.path], in: dir).status == 0)
            // Not a project.
            let folder = dir.appending(path: "Folder", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let notOne = try await CLIFixtures.toma(["info", folder.path], in: dir)
            #expect(notOne.status == 1)
            #expect(notOne.stderr.hasPrefix("error: notAProject: "))
            #expect(notOne.stdout.isEmpty)
            // A bad option, a missing argument and a command that is not one.
            #expect(try await CLIFixtures.toma(["info", url.path, "--nope"], in: dir).status == 2)
            #expect(try await CLIFixtures.toma(["edit", url.path], in: dir).status == 2)
            let bad = try await CLIFixtures.toma(["edit", url.path, #"{"command":"nope"}"#], in: dir)
            #expect(bad.status == 2)
            #expect(bad.stderr.contains("invalidCommand"))
            #expect(try await CLIFixtures.toma(["edit", url.path, "{not json"], in: dir).status == 2)
            // Out of range.
            #expect(try await CLIFixtures.toma(["edit", url.path, #"{"command":"cut","from":4,"to":3}"#], in: dir).status == 1)
            // Locked.
            let holder = try await Self.holdTheLock(of: url, in: dir)
            #expect(try await CLIFixtures.toma(["undo", url.path], in: dir).status == 3)
            await holder.close()
            // Help is no error.
            let help = try await CLIFixtures.toma(["--help"], in: dir)
            #expect(help.status == 0 && help.stdout.contains("edit"))
        }
    }

    @MainActor @Test func lockedWithoutTheAppExitsThree() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let holder = try await Self.holdTheLock(of: url, in: dir)
            let before = try treeHash(url)
            let run = try await CLIFixtures.toma(["edit", url.path, #"{"command":"setAspect","aspect":"9:16"}"#, "--json"], in: dir)
            #expect(run.status == 3)
            #expect(run.errorCode == "locked")
            let text = try await CLIFixtures.toma(["edit", url.path, #"{"command":"setAspect","aspect":"9:16"}"#], in: dir)
            #expect(text.status == 3 && text.stderr.hasPrefix("error: locked: "))
            #expect(try treeHash(url) == before)
            // Reading is never locked out.
            #expect(try await CLIFixtures.toma(["info", url.path], in: dir).status == 0)
            await holder.close()
            #expect(try await CLIFixtures.toma(["edit", url.path, #"{"command":"setAspect","aspect":"9:16"}"#], in: dir).status == 0)
        }
    }

    @Test func jsonStdoutIsOneDocument() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let runs = [
                try await CLIFixtures.toma(["info", url.path, "--json"], in: dir),
                try await CLIFixtures.toma(["markers", url.path, "--json"], in: dir),
                try await CLIFixtures.toma(["validate", url.path, "--json"], in: dir),
                try await CLIFixtures.toma(["edit", url.path, #"{"command":"addMarker","at":5,"name":"Five"}"#, "--json"], in: dir),
                try await CLIFixtures.toma(["undo", url.path, "--json"], in: dir),
                try await CLIFixtures.toma(["export", url.path, dir.appending(path: "out").path, "--size", "720", "--json"], in: dir),
                // Errors: of the API, of the arguments.
                try await CLIFixtures.toma(["info", dir.path, "--json"], in: dir),
                try await CLIFixtures.toma(["export", url.path, "out.mov", "--json"], in: dir),
                try await CLIFixtures.toma(["transcript", url.path, "--json"], in: dir),
            ]
            for run in runs {
                // Exactly one JSON value, an object.
                #expect((try? run.object()) != nil, "\(run.stdout)")
            }
            #expect(runs[..<6].allSatisfy { $0.status == 0 })
            #expect(runs[6].errorCode == "notAProject" && runs[6].status == 1)
            #expect(runs[7].errorCode == "invalidCommand" && runs[7].status == 2)
            #expect(runs[8].errorCode == "refused" && runs[8].status == 1)
            // The export's progress is on standard error alone.
            let export = runs[5]
            #expect(!export.stdout.contains("progress"))
            let lines = export.stderr.split(separator: "\n")
            #expect(lines.contains("progress: 100 %"))
            #expect(lines.allSatisfy { $0.hasPrefix("progress: ") || $0.hasPrefix("warning: ") })
            #expect(try runs[5].object()["path"] as? String == dir.appending(path: "out.mp4").path)
        }
    }

    @MainActor @Test func editFileAppliesInOrderAndEachUndoes() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let before = try await ProjectRunner.report(url, environment: CLIFixtures.environment(in: dir))
            let commands = #"""
                [{"command":"setTitle","title":"Demo"},
                 {"command":"setAspect","aspect":"9:16"},
                 {"command":"addMarker","at":5,"name":"Five"}]
                """#
            try Data(commands.utf8).write(to: dir.appending(path: "commands.json"))
            let run = try await CLIFixtures.toma(["edit", url.path, "--file", "commands.json"], in: dir)
            #expect(run.status == 0, "\(run.stderr)")
            #expect(run.stdout.split(separator: "\n").map { $0.split(separator: ":").first.map(String.init) ?? "" }
                == ["setTitle", "setAspect", "addMarker"])
            let edited = try await ProjectRunner.report(url, environment: CLIFixtures.environment(in: dir))
            #expect(edited.info?.title == "Demo" && edited.aspect == "9:16" && edited.markers.count == 3)

            var labels: [String] = []
            for _ in 0..<3 {
                let undo = try await CLIFixtures.toma(["undo", url.path, "--json"], in: dir)
                #expect(undo.status == 0, "\(undo.stdout)")
                labels.append(try undo.object()["label"] as? String ?? "")
            }
            #expect(labels == ["marker.add", "aspect", "project.title"])
            let nothing = try await CLIFixtures.toma(["undo", url.path, "--json"], in: dir)
            #expect(nothing.status == 1 && nothing.errorCode == "refused")
            let undone = try await ProjectRunner.report(url, environment: CLIFixtures.environment(in: dir))
            #expect(undone.info?.title ?? "" == "" && undone.aspect == before.aspect && undone.markers == before.markers)
            // And redo.
            let redo = try await CLIFixtures.toma(["redo", url.path], in: dir)
            #expect(redo.status == 0 && redo.stdout.hasPrefix("redo: project.title"))

            // A list that stops at a command that fails: what came before stays, and it says which.
            try Data(#"[{"command":"setTitle","title":"Two"},{"command":"cut","from":4,"to":3}]"#.utf8)
                .write(to: dir.appending(path: "stops.json"))
            let stops = try await CLIFixtures.toma(["edit", url.path, "--file", "stops.json", "--json"], in: dir)
            #expect(stops.status == 1)
            let batch = try ProjectJSON.decoder().decode(BatchResult.self, from: Data(stops.stdout.utf8))
            #expect(batch.results.count == 1 && batch.failedIndex == 1 && batch.error?.code == .outOfRange)
        }
    }

    @MainActor @Test func editReadsStandardInput() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let input = Data(#"[{"command":"addMarker","at":2,"name":"Two"},{"command":"addMarker","at":4,"name":"Four"}]"#.utf8)
            let run = try await CLIFixtures.toma(["edit", url.path, "--file", "-", "--json"], in: dir, input: input)
            #expect(run.status == 0, "\(run.stdout)")
            let batch = try ProjectJSON.decoder().decode(BatchResult.self, from: Data(run.stdout.utf8))
            #expect(batch.results.map(\.label) == ["marker.add", "marker.add"])
            let markers = try await ProjectRunner.markers(url, environment: CLIFixtures.environment(in: dir))
            #expect(markers.markers.map(\.name).filter { !$0.isEmpty } == ["Two", "Four"])
        }
    }

    @MainActor @Test func exportLastsWhatTheDocumentSays() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            #expect(try await CLIFixtures.toma(["edit", url.path, #"{"command":"cut","from":2,"to":4}"#], in: dir).status == 0)
            let report = try await ProjectRunner.report(url, environment: CLIFixtures.environment(in: dir))
            let before = try treeHash(url)
            let run = try await CLIFixtures.toma(["export", url.path, "movie", "--size", "720"], in: dir)
            #expect(run.status == 0, "\(run.stderr)")
            let movie = dir.appending(path: "movie.mp4")
            #expect(run.stdout.hasPrefix(movie.path + " (h264, 1280×720, "))
            let duration = try await AVURLAsset(url: movie).load(.duration).seconds
            #expect(abs(duration - report.duration) <= 1.0 / Double(report.frameRate) + 1e-6, "\(duration) s, \(report.duration) s")
            #expect(abs(report.duration - 8) < 0.2)
            // Exporting never writes into the package.
            #expect(try treeHash(url) == before)
        }
    }

    @Test func exportExtensionMismatchIsUsage() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            for arguments in [
                ["out.mov"], ["out.mp4", "--codec", "prores422"], ["out.mp4", "--gif"], ["out.gif", "--gif", "--codec", "h264"],
                ["out.mp4", "--codec", "vp9"], ["out.mp4", "--quality", "best"],
            ] {
                let run = try await CLIFixtures.toma(["export", url.path] + arguments, in: dir)
                #expect(run.status == 2, "\(arguments)")
            }
            // A size the codec does not take is invalidCommand, also 2; inside a package, refused.
            #expect(try await CLIFixtures.toma(["export", url.path, "out.mp4", "--size", "999"], in: dir).status == 2)
            #expect(try await CLIFixtures.toma(["export", url.path, url.appending(path: "out.mp4").path], in: dir).status == 1)
            let written = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("out") }
            #expect(written.isEmpty)
        }
    }

    private static func withoutClipIDs(_ report: ProjectReport) -> ProjectReport {
        var report = report
        for k in report.sequence.indices { report.sequence[k].id = "" }
        return report
    }

    /// An edit session of the project (the app, as far as `toma` can tell), holding `edit.lock`: a change made through
    /// the API opens it.
    @MainActor private static func holdTheLock(of url: URL, in dir: URL) async throws -> TomaProject {
        let project = try await TomaProject.open(url, mode: .edit, environment: CLIFixtures.environment(in: dir))
        _ = try await project.apply(.setTitle("Held"))
        return project
    }
}
