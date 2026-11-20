// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import toma

/// The export for an external editor from the command line and the MCP server (plan 4b, Task A6): `toma export --fcpxml`
/// and `export_fcpxml` write the video and, next to it, `<name>.fcpxml` and `<name>.toma-metadata.json`, and say the three
/// paths; files of those names already there are refused unless asked to replace them.
@Suite struct FCPXMLToolTests {
    @Test func cliFCPXMLFlag() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let arguments = ["export", url.path, "demo", "--fcpxml", "--size", "720", "--fps", "30", "--json"]
            let run = try await CLIFixtures.toma(arguments, in: dir)
            #expect(run.status == 0, "\(run.stderr)")
            let result = try run.object()
            let video = dir.appending(path: "demo.mp4").path, fcpxml = dir.appending(path: "demo.fcpxml").path
            let metadata = dir.appending(path: "demo.toma-metadata.json").path
            #expect(result["path"] as? String == video)
            #expect(result["fcpxml"] as? String == fcpxml)
            #expect(result["metadata"] as? String == metadata)
            for path in [video, fcpxml, metadata] { #expect(FileManager.default.fileExists(atPath: path), "\(path)") }
            let xml = try XMLDocument(contentsOf: URL(fileURLWithPath: fcpxml))
            #expect(xml.rootElement()?.attribute(forName: "version")?.stringValue == "1.11")

            // Again: refused, the files as they were; with --replace, replaced.
            let written = try Data(contentsOf: URL(fileURLWithPath: fcpxml))
            let again = try await CLIFixtures.toma(arguments, in: dir)
            #expect(again.status == 1)
            #expect(again.errorCode == "refused")
            #expect(try Data(contentsOf: URL(fileURLWithPath: fcpxml)) == written)
            let replaced = try await CLIFixtures.toma(arguments + ["--replace"], in: dir)
            #expect(replaced.status == 0, "\(replaced.stderr)")

            // Without --json, the three paths, one a line.
            let text = try await CLIFixtures.toma(["export", url.path, "text", "--fcpxml", "--size", "720", "--fps", "30"], in: dir)
            #expect(text.status == 0, "\(text.stderr)")
            let lines = text.stdout.split(separator: "\n").map(String.init)
            #expect(lines.count == 3)
            #expect(lines.first?.hasPrefix(dir.appending(path: "text.mp4").path) == true)
            #expect(Array(lines.dropFirst()) == [dir.appending(path: "text.fcpxml").path, dir.appending(path: "text.toma-metadata.json").path])

            // Usage: with a GIF, or --replace alone.
            for wrong in [["--fcpxml", "--gif"], ["--replace"]] {
                let run = try await CLIFixtures.toma(["export", url.path, "wrong"] + wrong, in: dir)
                #expect(run.status == 2, "\(wrong)")
            }
        }
    }

    @Test func mcpExportFCPXMLGivesTheThreePaths() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let mcp = MCPHarness(in: dir)
            let tools = try #require(try await mcp.request("tools/list", id: .integer(1))["result"]?["tools"]?.arrayValue)
            let tool = try #require(tools.first { $0["name"] == .string("export_fcpxml") })
            #expect(tool["inputSchema"]?["properties"]?["replace"]?["type"] == .string("boolean"))
            #expect(tool["inputSchema"]?["properties"]?["gif"] == nil)
            #expect(tool["inputSchema"]?["properties"]?["background"]?["type"] == .string("boolean"))
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(false))

            let arguments: [String: JSONValue] = [
                "project": .string(url.path), "output": .string("edit"), "size": .integer(720), "fps": .integer(30),
            ]
            let result = try await mcp.call("export_fcpxml", arguments, id: 2)
            #expect(result["isError"] == .bool(false), "\(result)")
            let structured = try #require(result["structuredContent"])
            #expect(structured["path"] == .string(dir.appending(path: "edit.mp4").path))
            #expect(structured["fcpxml"] == .string(dir.appending(path: "edit.fcpxml").path))
            #expect(structured["metadata"] == .string(dir.appending(path: "edit.toma-metadata.json").path))
            for name in ["edit.mp4", "edit.fcpxml", "edit.toma-metadata.json"] {
                #expect(FileManager.default.fileExists(atPath: dir.appending(path: name).path), "\(name)")
            }

            // Again: refused unless replace is true.
            let again = try await mcp.call("export_fcpxml", arguments, id: 3)
            #expect(again["isError"] == .bool(true))
            #expect(again["structuredContent"]?["error"]?["code"] == .string("refused"))
            var replacing = arguments
            replacing["replace"] = .bool(true)
            let replaced = try await mcp.call("export_fcpxml", replacing, id: 4)
            #expect(replaced["isError"] == .bool(false), "\(replaced)")
            // In the background: the job's result has the three paths too.
            var later = arguments
            later["output"] = .string("later")
            later["background"] = .bool(true)
            var status = try #require(try await mcp.call("export_fcpxml", later, id: 7)["structuredContent"])
            let job = try #require(status["jobId"]?.stringValue)
            var k: Int64 = 8
            let deadline = ContinuousClock.now + .seconds(300)
            while status["status"] == .string("running"), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                status = try #require(try await mcp.call("export_status", ["jobId": .string(job)], id: k)["structuredContent"])
                k += 1
            }
            #expect(status["status"] == .string("done"), "\(status)")
            #expect(status["result"]?["fcpxml"] == .string(dir.appending(path: "later.fcpxml").path))
            #expect(status["result"]?["metadata"] == .string(dir.appending(path: "later.toma-metadata.json").path))
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: "later.fcpxml").path))
            // A GIF is not one of its arguments.
            var gif = arguments
            gif["gif"] = .bool(true)
            let wrong = try await mcp.call("export_fcpxml", gif, id: 5)
            #expect(wrong["structuredContent"]?["error"]?["code"] == .string("invalidCommand"))
            // export_video takes no replace.
            var video = arguments
            video["replace"] = .bool(true)
            let noReplace = try await mcp.call("export_video", video, id: 6)
            #expect(noReplace["structuredContent"]?["error"]?["code"] == .string("invalidCommand"))
        }
    }
}
