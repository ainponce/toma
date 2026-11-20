// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import toma

/// The tools of `toma mcp` (plan 4b, Task A5) over a project of 10 s, through an `MCPServer` in this process: their
/// list and schemas, their results and errors, the paths they refuse, the batch, the progress of an export and its
/// cancellation, and the calls on one package one at a time.
@Suite struct MCPToolsTests {
    static let names = [
        "list_projects", "project_info", "get_transcript", "get_markers", "apply_commands", "undo", "redo", "export_video",
    ]
    static let readOnly: Set<String> = ["list_projects", "project_info", "get_transcript", "get_markers"]

    @Test func toolsListHasEveryToolWithAnObjectSchema() async throws {
        try await withTemporaryDirectory { dir in
            let mcp = MCPHarness(in: dir)
            let answer = try await mcp.request("tools/list", id: .integer(1))
            let tools = try #require(answer["result"]?["tools"]?.arrayValue)
            let names = tools.compactMap { $0["name"]?.stringValue }
            // Others are appended after these (5a, 5b, A6), never before.
            #expect(Array(names.prefix(Self.names.count)) == Self.names)
            #expect(Set(names).count == names.count)
            for tool in tools {
                let name = tool["name"]?.stringValue ?? "?"
                #expect(tool["inputSchema"]?["type"] == .string("object"), "\(name)")
                #expect(tool["inputSchema"]?["properties"]?.objectValue != nil, "\(name)")
                #expect(tool["description"]?.stringValue?.isEmpty == false, "\(name)")
            }
            for tool in tools where Self.names.contains(tool["name"]?.stringValue ?? "") {
                let name = tool["name"]?.stringValue ?? ""
                #expect(tool["annotations"]?["readOnlyHint"] == .bool(Self.readOnly.contains(name)), "\(name)")
                if name != "list_projects" {
                    #expect(tool["inputSchema"]?["required"]?.arrayValue?.contains(.string("project")) == true, "\(name)")
                }
            }
            // The commands' schema, without `$ref`, is the items of apply_commands.
            let apply = try #require(tools.first { $0["name"] == .string("apply_commands") })
            var inline = try #require(CommandSchema.inline.objectValue)
            inline["$schema"] = nil
            #expect(apply["inputSchema"]?["properties"]?["commands"]?["items"] == .object(inline))
            #expect(apply["inputSchema"]?["properties"]?["commands"]?["type"] == .string("array"))
            let export = try #require(tools.first { $0["name"] == .string("export_video") })
            #expect(export["inputSchema"]?["properties"]?["codec"]?["enum"]?.arrayValue?.count == ExportRequest.codecs.count)
        }
    }

    @Test func resultHasTextAndStructuredContent() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let mcp = MCPHarness(in: dir)
            let result = try await mcp.call("project_info", ["project": .string(url.path)], id: 1)
            #expect(result["isError"] == .bool(false))
            let structured = try #require(result["structuredContent"])
            #expect(structured["name"] == .string("Fixture"))
            #expect(structured["markers"]?.arrayValue?.count == 2)
            let content = try #require(result["content"]?.arrayValue)
            #expect(content.count == 1)
            #expect(content.first?["type"] == .string("text"))
            let text = try #require(content.first?["text"]?.stringValue)
            #expect(JSONRPC.parse(text) == structured)
            // A relative path is from the working directory, and the markers are the report's.
            let markers = try await mcp.call("get_markers", ["project": .string("Fixture.toma")], id: 2)
            let report = try await ProjectRunner.markers(url, environment: CLIFixtures.environment(in: dir))
            #expect(markers["structuredContent"] == (try JSONValue(encoding: report)))
        }
    }

    @Test func toolErrorIsIsErrorWithTheCode() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let folder = dir.appending(path: "Folder", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let mcp = MCPHarness(in: dir)
            let result = try await mcp.call("project_info", ["project": .string(folder.path)], id: 1)
            // A result, not an error of the protocol.
            #expect(mcp.messages.last?["error"] == nil)
            #expect(result["isError"] == .bool(true))
            #expect(result["structuredContent"]?["error"]?["code"] == .string("notAProject"))
            #expect(result["structuredContent"]?["error"]?["message"]?.stringValue?.isEmpty == false)
            let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
            #expect(JSONRPC.parse(text) == result["structuredContent"])
            // An argument it does not take, one that is missing, or of another type.
            let unknown = try await mcp.call("project_info", ["project": .string(url.path), "verbose": .bool(true)], id: 2)
            #expect(unknown["structuredContent"]?["error"]?["code"] == .string("invalidCommand"))
            #expect(unknown["structuredContent"]?["error"]?["message"]?.stringValue?.contains("verbose") == true)
            let missing = try await mcp.call("get_markers", [:], id: 3)
            #expect(missing["structuredContent"]?["error"]?["code"] == .string("invalidCommand"))
            let wrong = try await mcp.call(
                "export_video", ["project": .string(url.path), "output": .string("a.mp4"), "size": .string("big")], id: 4)
            #expect(wrong["structuredContent"]?["error"]?["code"] == .string("invalidCommand"))
            // A project without a transcript.
            let transcript = try await mcp.call("get_transcript", ["project": .string(url.path)], id: 5)
            #expect(transcript["isError"] == .bool(true))
            #expect(transcript["structuredContent"]?["error"]?["code"] == .string("refused"))
            // Nothing to undo.
            let undo = try await mcp.call("undo", ["project": .string(url.path)], id: 6)
            #expect(undo["structuredContent"]?["error"]?["code"] == .string("refused"))
        }
    }

    @Test func pathsWithDotDotOrLinksAreRefused() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            try FileManager.default.createDirectory(at: dir.appending(path: "Sub"), withIntermediateDirectories: false)
            let link = dir.appending(path: "Link.toma")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            let before = try treeHash(url)
            let mcp = MCPHarness(in: dir)
            func code(_ tool: String, _ arguments: [String: JSONValue], _ id: Int64) async throws -> JSONValue? {
                try await mcp.call(tool, arguments, id: id)["structuredContent"]?["error"]?["code"]
            }
            #expect(try await code("project_info", ["project": .string("Sub/../Fixture.toma")], 1) == .string("notAProject"))
            #expect(try await code("project_info", ["project": .string(dir.path + "/Sub/../Fixture.toma")], 2) == .string("notAProject"))
            #expect(try await code("project_info", ["project": .string(link.path)], 3) == .string("notAProject"))
            #expect(try await code("apply_commands", [
                "project": .string(link.path), "commands": .array([.object(["command": .string("removeMusic")])]),
            ], 4) == .string("notAProject"))
            #expect(try await code("export_video", ["project": .string(url.path), "output": .string("Sub/../out.mp4")], 5) == .string("refused"))
            #expect(try await code("export_video", ["project": .string(url.path), "output": .string("Fixture.toma/out.mp4")], 6) == .string("refused"))
            #expect(try await code("export_video", ["project": .string(url.path), "output": .string("Link.toma/out.mp4")], 7) == .string("refused"))
            #expect(try await code("list_projects", ["folder": .string("Sub/..")], 8) == .string("refused"))
            #expect(try treeHash(url) == before)
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "out.mp4").path))
        }
    }

    @Test func listProjectsLooksInTheLibraryOrAFolder() async throws {
        try await withTemporaryDirectory { dir in
            let library = dir.appending(path: "Projects", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
            let inLibrary = try await CLIFixtures.package(in: library, name: "Mine")
            _ = try await CLIFixtures.package(in: dir)
            let mcp = MCPHarness(in: dir)
            let all = try await mcp.call("list_projects", [:], id: 1)
            #expect(all["structuredContent"]?["folder"] == .string(library.path))
            #expect(all["structuredContent"]?["projects"]?.arrayValue?.compactMap { $0["path"]?.stringValue } == [inLibrary.path])
            let here = try await mcp.call("list_projects", ["folder": .string(".")], id: 2)
            let names = here["structuredContent"]?["projects"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
            #expect(names == ["Fixture", "Mine"])
        }
    }

    @Test func applyCommandsReportsTheBatch() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let mcp = MCPHarness(in: dir)
            let commands: [JSONValue] = [
                .object(["command": .string("setTitle"), "title": .string("Agent")]),
                .object(["command": .string("addMarker"), "at": .number(2), "name": .string("Demo")]),
                .object(["command": .string("cut"), "from": .number(4), "to": .number(3)]),
                .object(["command": .string("setAspect"), "aspect": .string("9:16")]),
            ]
            let result = try await mcp.call("apply_commands", ["project": .string(url.path), "commands": .array(commands)], id: 1)
            #expect(result["isError"] == .bool(true))
            let batch = try #require(result["structuredContent"])
            #expect(batch["results"]?.arrayValue?.compactMap { $0["command"]?.stringValue } == ["setTitle", "addMarker"])
            #expect(batch["results"]?.arrayValue?.last?["created"]?.stringValue?.hasPrefix("m-") == true)
            #expect(batch["failedIndex"] == .integer(2))
            #expect(batch["error"]?["code"] == .string("outOfRange"))
            // What ran stays; what came after the failure did not run.
            let report = try await ProjectRunner.report(url, environment: CLIFixtures.environment(in: dir))
            #expect(report.info?.title == "Agent")
            #expect(report.aspect == "16:9")
            #expect(report.markers.contains { $0.name == "Demo" })
            // A command that is not one: nothing runs.
            let invalid = try await mcp.call("apply_commands", [
                "project": .string(url.path),
                "commands": .array([.object(["command": .string("setTitle"), "title": .string("Other")]), .object(["command": .string("nope")])]),
            ], id: 2)
            #expect(invalid["isError"] == .bool(true))
            #expect(invalid["structuredContent"]?["error"]?["code"] == .string("invalidCommand"))
            #expect(invalid["structuredContent"]?["error"]?["message"]?.stringValue?.contains("command 1") == true)
            #expect(try await ProjectRunner.report(url, environment: CLIFixtures.environment(in: dir)).info?.title == "Agent")
            // A batch that goes through, as JSON text too; then undo and redo.
            let text = try await mcp.call("apply_commands", [
                "project": .string(url.path), "commands": .string(#"[{"command":"setAspect","aspect":"1:1"}]"#),
            ], id: 3)
            #expect(text["isError"] == .bool(false))
            #expect(text["structuredContent"]?["results"]?.arrayValue?.first?["changed"] == .bool(true))
            let undo = try await mcp.call("undo", ["project": .string(url.path)], id: 4)
            #expect(undo["structuredContent"]?["command"] == .string("undo"))
            #expect(try await ProjectRunner.report(url, environment: CLIFixtures.environment(in: dir)).aspect == "16:9")
            let redo = try await mcp.call("redo", ["project": .string(url.path)], id: 5)
            #expect(redo["structuredContent"]?["changed"] == .bool(true))
            #expect(try await ProjectRunner.report(url, environment: CLIFixtures.environment(in: dir)).aspect == "1:1")
        }
    }

    @Test func progressOnlyWithAToken() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let mcp = MCPHarness(in: dir)
            let token = JSONValue.string("export-1")
            let result = try await mcp.call(
                "export_video", ["project": .string(url.path), "output": .string("with.mp4"), "size": .integer(720)], id: 1,
                progressToken: token)
            #expect(result["isError"] == .bool(false), "\(result)")
            #expect(result["structuredContent"]?["path"] == .string(dir.appending(path: "with.mp4").path))
            let progress = mcp.progress(token)
            #expect(progress.count >= 2)
            let values = progress.compactMap { $0.params["progress"]?.numberValue }
            #expect(values.count == progress.count)
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
            #expect(values.allSatisfy { (0...1).contains($0) })
            #expect(progress.allSatisfy { $0.params["total"] == .integer(1) })
            // All of them before the answer.
            let answerIndex = try #require(mcp.messages.firstIndex { $0.isAnswer(to: .integer(1)) })
            #expect(progress.allSatisfy { $0.index < answerIndex })
            // Without a token, none.
            let before = mcp.messages.count
            let quiet = try await mcp.call(
                "export_video", ["project": .string(url.path), "output": .string("without"), "gif": .bool(true), "size": .integer(480)],
                id: 2)
            #expect(quiet["structuredContent"]?["format"] == .string("gif"), "\(quiet)")
            #expect(mcp.messages.count == before + 1)
            #expect(!mcp.messages.contains { $0["method"] == .string("notifications/progress") && $0["params"]?["progressToken"] != token })
        }
    }

    @Test func cancelledStopsTheExport() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let mcp = MCPHarness(in: dir)
            let token = JSONValue.integer(77)
            await mcp.send(MCPHarness.call(
                "export_video", ["project": .string(url.path), "output": .string("cancelled.mp4"), "size": .integer(2160)], id: 9,
                progressToken: token))
            // Once it writes the video, past the preparation.
            let deadline = ContinuousClock.now + .seconds(120)
            while !mcp.progress(token).contains(where: { ($0.params["progress"]?.numberValue ?? 0) >= 0.25 }),
                !mcp.messages.contains(where: { $0.isAnswer(to: .integer(9)) }), ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(5))
            }
            await mcp.send(.object([
                "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                "params": .object(["requestId": .integer(9), "reason": .string("the user changed their mind")]),
            ]))
            while await mcp.server.runningCalls > 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await mcp.server.runningCalls == 0)
            #expect(!mcp.messages.contains { $0.isAnswer(to: .integer(9)) })
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("cancelled") }
            #expect(left.isEmpty, "\(left)")
            let lastProgress = mcp.messages.lastIndex { $0["method"] == .string("notifications/progress") }
            // The server still answers, and sends no progress of the call any more.
            _ = try await mcp.request("ping", id: .integer(10))
            #expect(mcp.messages.lastIndex { $0["method"] == .string("notifications/progress") } == lastProgress)
        }
    }

    @Test func callsOnOneProjectAreOneAtATime() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let mcp = MCPHarness(in: dir)
            func markers(_ times: [Double]) -> JSONValue {
                .array(times.map { .object(["command": .string("addMarker"), "at": .number($0), "name": .string("At \($0)")]) })
            }
            // Three batches at once, one through another path to the same package.
            await mcp.send(MCPHarness.call("apply_commands", ["project": .string(url.path), "commands": markers([1, 2, 4])], id: 1))
            await mcp.send(MCPHarness.call("apply_commands", ["project": .string("Fixture.toma"), "commands": markers([5, 6, 8])], id: 2))
            await mcp.send(MCPHarness.call("apply_commands", ["project": .string("./Fixture.toma/"), "commands": markers([9, 9.5])], id: 3))
            for id in Int64(1)...3 {
                let answer = try await mcp.answer(to: .integer(id))
                #expect(answer["result"]?["isError"] == .bool(false), "\(answer)")
                #expect(answer["result"]?["structuredContent"]?["error"] == nil, "\(answer)")
            }
            let report = try await ProjectRunner.markers(url, environment: CLIFixtures.environment(in: dir))
            #expect(report.markers.count == 2 + 8)
        }
    }

    @Test func callsOnOnePackageNeverOverlap() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let other = try await CLIFixtures.package(in: dir, name: "Other")
            let meter = OverlapMeter()
            let mcp = MCPHarness(in: dir, tools: MCPToolCatalog.all + [ProbeTool(meter: meter, hold: .milliseconds(150))])
            let paths = [url.path, "Fixture.toma", "./Fixture.toma", other.path, "Other.toma"]
            for (k, path) in paths.enumerated() {
                await mcp.send(MCPHarness.call("probe", ["project": .string(path)], id: Int64(k)))
            }
            for k in paths.indices { _ = try await mcp.answer(to: .integer(Int64(k))) }
            #expect(meter.most(of: "Fixture.toma") == 1)
            #expect(meter.most(of: "Other.toma") == 1)
            #expect(meter.entries(of: "Fixture.toma") == 3)
            // Two packages, at once.
            #expect(meter.mostAtOnce >= 2)
        }
    }

    @Test func callsOnOnePackageGoInTheOrderTheyCame() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let meter = OverlapMeter()
            let mcp = MCPHarness(in: dir, tools: MCPToolCatalog.all + [ProbeTool(meter: meter, hold: .milliseconds(20))])
            // The first takes longest to get to the package, the second least.
            for (k, before) in [150, 0, 60, 10].enumerated() {
                await mcp.send(MCPHarness.call(
                    "probe", ["project": .string(url.path), "label": .string("\(k)"), "before": .integer(Int64(before))],
                    id: Int64(k)))
            }
            for k in 0..<4 { _ = try await mcp.answer(to: .integer(Int64(k))) }
            #expect(meter.order == ["0", "1", "2", "3"])
        }
    }

    @Test func aTicketWaitsForTheOnesBeforeIt() async throws {
        try await withTemporaryDirectory { dir in
            let locks = PackageLocks()
            let key = PackageKey(dir)
            let first = locks.reserve(key), second = locks.reserve(key), third = locks.reserve(key)
            let other = locks.reserve(PackageKey(dir.deletingLastPathComponent()))
            // Another package's line is its own.
            try await locks.wait(other)
            let order = LineSink()
            let waiting = Task {
                try await locks.wait(third)
                order.append(Data("third".utf8))
                locks.release(third)
            }
            let cancelled = Task { try await locks.wait(second) }
            try await Task.sleep(for: .milliseconds(50))
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            try await Task.sleep(for: .milliseconds(50))
            // The third waits for the first, still in the line.
            #expect(order.chunks.isEmpty)
            try await locks.wait(first)
            locks.release(first)
            try await waiting.value
            #expect(order.chunks == [Data("third".utf8)])
            // Released twice, or after it left: nothing changes.
            locks.release(first)
            locks.release(second)
            let last = locks.reserve(key)
            try await locks.wait(last)
            locks.release(last)
            locks.release(other)
        }
    }

    @Test func anExportAfterAnEditExportsTheEdit() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let mcp = MCPHarness(in: dir)
            // Sent one after the other, without waiting for the first answer.
            await mcp.send(MCPHarness.call("apply_commands", [
                "project": .string(url.path),
                "commands": .array([.object(["command": .string("cut"), "from": .number(2), "to": .number(4)])]),
            ], id: 1))
            await mcp.send(MCPHarness.call(
                "export_video",
                ["project": .string(url.path), "output": .string("after.gif"), "gif": .bool(true), "size": .integer(480),
                 "fps": .integer(10)], id: 2))
            let edit = try await mcp.answer(to: .integer(1))
            let export = try await mcp.answer(to: .integer(2))
            #expect(edit["result"]?["isError"] == .bool(false))
            #expect(export["result"]?["structuredContent"]?["duration"]?.numberValue.map { abs($0 - 8) < 0.01 } == true, "\(export)")
            #expect(mcp.messages.firstIndex { $0.isAnswer(to: .integer(1)) }! < mcp.messages.firstIndex { $0.isAnswer(to: .integer(2)) }!)
        }
    }

    @Test func aCallCancelledWhileItWaitsNeverRuns() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let meter = OverlapMeter()
            let mcp = MCPHarness(in: dir, tools: MCPToolCatalog.all + [ProbeTool(meter: meter, hold: .milliseconds(1500))])
            // The first holds the package; the two others wait for it.
            await mcp.send(MCPHarness.call("probe", ["project": .string(url.path)], id: 1))
            while meter.entries(of: "Fixture.toma") == 0 { try await Task.sleep(for: .milliseconds(5)) }
            await mcp.send(MCPHarness.call("probe", ["project": .string(url.path)], id: 2))
            await mcp.send(MCPHarness.call("probe", ["project": .string(url.path)], id: 3))
            try await Task.sleep(for: .milliseconds(100))
            await mcp.send(.object([
                "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                "params": .object(["requestId": .integer(2)]),
            ]))
            // It stops waiting at once, while the first still holds the package.
            let deadline = ContinuousClock.now + .seconds(1)
            while await mcp.server.runningCalls > 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(await mcp.server.runningCalls == 2)
            #expect(meter.entries(of: "Fixture.toma") == 1)
            _ = try await mcp.answer(to: .integer(1))
            _ = try await mcp.answer(to: .integer(3))
            #expect(meter.entries(of: "Fixture.toma") == 2)
            #expect(!mcp.messages.contains { $0.isAnswer(to: .integer(2)) })
            #expect(await mcp.server.runningCalls == 0)
        }
    }
}

/// A tool of the tests: holds the package it is given (`MCPContext.serialized`) for `hold`, and tells `meter`.
private struct ProbeTool: MCPTool {
    let name = "probe"
    let description = "Holds a package for a while."
    let meter: OverlapMeter
    let hold: Duration
    var inputSchema: JSONValue { MCPSchema.object(["project": MCPSchema.project], required: ["project"]) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let arguments = try MCPArguments(arguments, tool: name, keys: ["project", "label", "before"])
        let url = try context.packageURL(try arguments.string("project"))
        let label = try arguments.optionalString("label")
        // Work of its own before it gets to the package.
        if let before = try arguments.optionalInt("before") { try? await Task.sleep(for: .milliseconds(before)) }
        let name = url.lastPathComponent, meter = meter, hold = hold
        return try await context.serialized(url) {
            meter.enter(name, label: label)
            defer { meter.leave(name) }
            try? await Task.sleep(for: hold)
            return MCPToolResult(structured: .object([:]), isError: false)
        }
    }
}

/// How many calls held each package at once, at most, and in all.
private final class OverlapMeter: Sendable {
    private struct Count {
        var now = 0
        var most = 0
        var entries = 0
    }

    private let state = Mutex<(packages: [String: Count], now: Int, most: Int, order: [String])>(([:], 0, 0, []))

    func enter(_ package: String, label: String? = nil) {
        state.withLock { state in
            if let label { state.order.append(label) }
            var count = state.packages[package] ?? Count()
            count.now += 1
            count.entries += 1
            count.most = max(count.most, count.now)
            state.packages[package] = count
            state.now += 1
            state.most = max(state.most, state.now)
        }
    }

    func leave(_ package: String) {
        state.withLock { state in
            state.packages[package]?.now -= 1
            state.now -= 1
        }
    }

    func most(of package: String) -> Int { state.withLock { $0.packages[package]?.most ?? 0 } }
    func entries(of package: String) -> Int { state.withLock { $0.packages[package]?.entries ?? 0 } }
    var mostAtOnce: Int { state.withLock { $0.most } }
    /// The labels of the calls, in the order they got their package.
    var order: [String] { state.withLock { $0.order } }
}
