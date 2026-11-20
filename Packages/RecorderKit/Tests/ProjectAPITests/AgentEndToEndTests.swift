// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing

/// `make agent-e2e`, phase 4's "done" (fases 4 y 5 design §6.5; plan 4b decision 22, Task A6): an agent edits and exports
/// a project without the app. The binaries the Makefile built (`TOMA_BIN_DIR`) make a synthetic take (`recorder-dev
/// synth-record`) and are talked to as an MCP client talks to `toma mcp`, over its standard input and output; then the MP4
/// lasts what the document says and has its chapters, and the FCPXML is valid. Only with `TOMA_AGENT_E2E=1`: `make test`
/// skips it. Every `TOMA_*` folder is a temporary one.
@Suite struct AgentEndToEndTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["TOMA_AGENT_E2E"] == "1"

    @Test(.enabled(if: enabled), .timeLimit(.minutes(10))) func agentEditsAndExportsWithoutTheApp() async throws {
        let bin = try #require(Self.environment["TOMA_BIN_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }, "TOMA_BIN_DIR")
        try await withTemporaryDirectory { dir in
            // 1. The project: 6 s, marked at 1 s and 4 s.
            let synth = try await run(bin.appending(path: "recorder-dev"), ["synth-record", dir.path, "--duration", "6", "--markers", "1,4"])
            #expect(synth.status == 0, "\(synth.stderr)")
            let package = URL(fileURLWithPath: try #require(synth.stdout.split(separator: "\n").first.map(String.init)), isDirectory: true)
            #expect(package.pathExtension == "toma")
            let recorded = try files(in: package)

            // 2. The agent's session.
            let mcp = try MCPClient(bin.appending(path: "toma"), in: dir)
            defer { mcp.kill() }
            let initialized = try await mcp.call("initialize", [
                "protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "agent-e2e", "version": "1"],
            ])
            #expect((initialized["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
            try mcp.notify("notifications/initialized")
            let tools = try #require(((try await mcp.call("tools/list"))["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            let names = tools.compactMap { $0["name"] as? String }
            for name in ["project_info", "apply_commands", "get_markers", "export_video", "export_fcpxml"] {
                #expect(names.contains(name), "\(name)")
            }

            let before = try await mcp.tool("project_info", ["project": package.path])
            let recordedSeconds = try #require(before["duration"] as? Double)
            #expect(abs(recordedSeconds - 6) < 0.5)
            // The synthetic take clicks every second, so its automatic zoom fills the output: off first, for a zoom of the
            // agent's own.
            let commands: [[String: Any]] = [
                ["command": "cut", "from": 2, "to": 2.5],
                ["command": "setAutoZoom", "enabled": false],
                ["command": "addZoom", "from": 3, "to": 5, "depth": 2],
                ["command": "addMarker", "at": 4.5, "name": "Demo"],
                ["command": "addTitleCard", "at": "start", "title": "Intro"],
                ["command": "setTitle", "title": "Prueba de agente"],
            ]
            let applied = try await mcp.tool("apply_commands", ["project": package.path, "commands": commands])
            let results = try #require(applied["results"] as? [[String: Any]])
            #expect(results.count == commands.count)
            #expect(applied["error"] == nil, "\(applied)")
            #expect(results.allSatisfy { $0["changed"] as? Bool == true && $0["via"] as? String == "project" })

            let info = try await mcp.tool("project_info", ["project": package.path])
            #expect((info["info"] as? [String: Any])?["title"] as? String == "Prueba de agente")
            let duration = try #require(info["duration"] as? Double)
            #expect(abs(duration - recordedSeconds) > 0.4, "the cut and the card change what the output lasts")
            let markers = try await mcp.tool("get_markers", ["project": package.path])
            let visible = try #require(markers["markers"] as? [[String: Any]])
            let chapters = try #require(markers["chapters"] as? [[String: Any]])
            #expect(visible.contains { $0["name"] as? String == "Demo" })
            #expect(chapters.contains { $0["title"] as? String == "Demo" })

            let videoResult = try await mcp.tool(
                "export_video", ["project": package.path, "output": dir.appending(path: "agent.mp4").path, "size": 720],
                progressToken: "export")
            let fcpxmlResult = try await mcp.tool(
                "export_fcpxml", ["project": package.path, "output": dir.appending(path: "editor.mp4").path, "size": 720])
            #expect(mcp.progress(token: "export") > 0)
            try mcp.closeInput()
            #expect(await mcp.exitStatus() == 0, "\(mcp.standardError)")

            // 3. The MP4: what the document lasts, ± a frame, and its chapters.
            let video = URL(fileURLWithPath: try #require(videoResult["path"] as? String))
            let fps = try #require(videoResult["framesPerSecond"] as? Int)
            let asset = AVURLAsset(url: video)
            let seconds = try await asset.load(.duration).seconds
            #expect(abs(seconds - duration) <= 1.0 / Double(fps) + 1e-6, "\(seconds) s, the document \(duration) s")
            // Without a transcript, the chapters' language is undetermined: read in the locale the file has them in.
            let locale = try #require(try await asset.load(.availableChapterLocales).first, "a chapter track")
            let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])
            #expect(groups.count == chapters.count)
            var titles: [String] = []
            for group in groups {
                let item = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
                titles.append((try await item?.load(.stringValue)) ?? "")
            }
            #expect(titles == chapters.compactMap { $0["title"] as? String })

            // The FCPXML: valid, version 1.11, one clip, a chapter marker for every marker the output shows, every time on
            // a frame of the video.
            let fcpxml = URL(fileURLWithPath: try #require(fcpxmlResult["fcpxml"] as? String))
            let metadata = URL(fileURLWithPath: try #require(fcpxmlResult["metadata"] as? String))
            #expect(FileManager.default.fileExists(atPath: metadata.path))
            let xml = try XMLDocument(contentsOf: fcpxml)
            #expect(xml.rootElement()?.name == "fcpxml")
            #expect(xml.rootElement()?.attribute(forName: "version")?.stringValue == "1.11")
            #expect(try xml.nodes(forXPath: "//asset-clip").count == 1)
            let chapterMarkers = try xml.nodes(forXPath: "//chapter-marker").compactMap { $0 as? XMLElement }
            #expect(chapterMarkers.count == visible.count)
            #expect(chapterMarkers.contains { $0.attribute(forName: "value")?.stringValue == "Demo" })
            let editorFPS = try #require(fcpxmlResult["framesPerSecond"] as? Int)
            let timed = try xml.nodes(forXPath: "//@start | //@duration | //@offset | //@frameDuration").compactMap(\.stringValue)
            #expect(!timed.isEmpty)
            for time in timed {
                #expect(isOnAFrame(time, fps: editorFPS), "\(time)")
            }
            let clip = try #require(try xml.nodes(forXPath: "//asset-clip").first as? XMLElement)
            let clipFrames = try #require(clip.attribute(forName: "duration")?.stringValue.flatMap { frames($0, fps: editorFPS) })
            #expect(abs(Double(clipFrames) / Double(editorFPS) - duration) <= 1.0 / Double(editorFPS) + 1e-6)

            // The package has nothing new but the edit's own files.
            let added = try files(in: package).subtracting(recorded)
            let allowed = added.filter { path in
                ["edit.json", "edit-log.jsonl", "edit.lock"].contains(path) || path == "assets" || path.hasPrefix("assets/")
            }
            #expect(added == allowed, "\(added.subtracting(allowed).sorted())")
            #expect(added.contains("edit-log.jsonl"))
        }
    }
}

// MARK: - Helpers

/// `n/fps s` or `0s`, with `n` whole: on a frame of a video of `fps`.
private func isOnAFrame(_ time: String, fps: Int) -> Bool {
    frames(time, fps: fps) != nil
}

/// The frames of `time` (`0s`, or `n/fps s`, the frame's own `1/fps s` too).
private func frames(_ time: String, fps: Int) -> Int? {
    if time == "0s" { return 0 }
    guard time.hasSuffix("s") else { return nil }
    let parts = time.dropLast().split(separator: "/")
    guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), d == fps, n >= 0 else { return nil }
    return n
}

/// Every file and folder under `folder`, by its path from it.
private func files(in folder: URL) throws -> Set<String> {
    let base = folder.resolvingSymlinksInPath().path + "/"
    guard let walker = FileManager.default.enumerator(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: nil) else {
        return []
    }
    var found: Set<String> = []
    for case let url as URL in walker {
        let path = url.resolvingSymlinksInPath().path
        found.insert(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path)
    }
    return found
}

private struct Run {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs `executable` with `arguments` to its end, its output in files (so no pipe fills up).
private func run(_ executable: URL, _ arguments: [String]) async throws -> Run {
    let folder = FileManager.default.temporaryDirectory.appending(path: "agent-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let out = folder.appending(path: "stdout"), err = folder.appending(path: "stderr")
    FileManager.default.createFile(atPath: out.path, contents: nil)
    FileManager.default.createFile(atPath: err.path, contents: nil)
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = try FileHandle(forWritingTo: out)
    process.standardError = try FileHandle(forWritingTo: err)
    process.standardInput = FileHandle.nullDevice
    let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
    return Run(
        status: status, stdout: String(decoding: try Data(contentsOf: out), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: err), as: UTF8.self))
}

/// `toma mcp` as a client talks to it: a JSON-RPC message per line on its standard input, its lines read from its
/// standard output, its standard error in a file. Its `TOMA_*` folders are in `dir`.
private final class MCPClient: Sendable {
    private let process: Process
    private let input: FileHandle
    private let errors: URL
    private let output = Output()
    private let nextID = Mutex(0)
    private let ended = Ended()

    /// The lines of its standard output, as they come.
    private final class Output: Sendable {
        private let state = Mutex<(buffer: Data, lines: [Data])>((Data(), []))

        var lines: [Data] { state.withLock { $0.lines } }

        func append(_ data: Data) {
            state.withLock { state in
                state.buffer.append(data)
                while let end = state.buffer.firstIndex(of: 0x0A) {
                    state.lines.append(Data(state.buffer[state.buffer.startIndex..<end]))
                    state.buffer = Data(state.buffer[(end + 1)...])
                }
            }
        }
    }

    /// Its exit status, once it ended.
    private final class Ended: Sendable {
        private let status = Mutex<Int32?>(nil)
        var value: Int32? { status.withLock { $0 } }
        func set(_ value: Int32) { status.withLock { $0 = value } }
    }

    init(_ toma: URL, in dir: URL) throws {
        let process = Process()
        process.executableURL = toma
        process.arguments = ["mcp"]
        process.currentDirectoryURL = dir
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TOMA_CACHES_ROOT": dir.appending(path: "Caches").path, "TOMA_MUSIC_ROOT": dir.appending(path: "Music").path,
            "TOMA_STYLES": dir.appending(path: "Styles").path, "TOMA_PROJECTS_FOLDER": dir.appending(path: "Projects").path,
            "TOMA_CONTROL_SOCKET": dir.appending(path: "control.sock").path,
        ]) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        errors = dir.appending(path: "mcp-stderr")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = try FileHandle(forWritingTo: errors)
        input = stdin.fileHandleForWriting
        self.process = process
        let output = output, ended = ended
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            output.append(data)
        }
        process.terminationHandler = { process in ended.set(process.terminationStatus) }
        try process.run()
    }

    var standardError: String { (try? String(contentsOf: errors, encoding: .utf8)) ?? "" }

    func notify(_ method: String) throws {
        try send(["jsonrpc": "2.0", "method": method])
    }

    /// The answer to a request of `method`.
    func call(_ method: String, _ params: [String: Any]? = nil) async throws -> [String: Any] {
        let id = nextID.withLock { id in
            id += 1
            return id
        }
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        let deadline = ContinuousClock.now + .seconds(300)
        while ContinuousClock.now < deadline {
            if let answer = messages.first(where: { ($0["id"] as? Int) == id }) { return answer }
            if ended.value != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestSupportError.missing("an answer to \(method) (\(id)); stderr: \(standardError)")
    }

    /// The `structuredContent` of a call of `tool` that is no error.
    func tool(_ tool: String, _ arguments: [String: Any], progressToken: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["name": tool, "arguments": arguments]
        if let progressToken { params["_meta"] = ["progressToken": progressToken] }
        let answer = try await call("tools/call", params)
        let result = try #require(answer["result"] as? [String: Any], "\(answer)")
        #expect(result["isError"] as? Bool == false, "\(tool): \(result)")
        return try #require(result["structuredContent"] as? [String: Any], "\(result)")
    }

    /// How many `notifications/progress` of `token` came.
    func progress(token: String) -> Int {
        messages.filter { message in
            message["method"] as? String == "notifications/progress"
                && (message["params"] as? [String: Any])?["progressToken"] as? String == token
        }.count
    }

    /// Every message of its standard output; a line that is not a JSON object is an issue.
    var messages: [[String: Any]] {
        output.lines.compactMap { line in
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                Issue.record("a line that is not JSON-RPC on standard output: \(String(decoding: line, as: UTF8.self))")
                return nil
            }
            return message
        }
    }

    func closeInput() throws {
        try input.close()
    }

    /// Its exit status, once it ends (within 60 s).
    func exitStatus() async -> Int32? {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if let status = ended.value { return status }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    func kill() {
        if process.isRunning { process.terminate() }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }
}
