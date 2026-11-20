// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import LocalAI
import ProjectAPI
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import toma

/// `toma ai` and `suggest_chapters` (plan 5b, Task I4) over a project of 10 s, with a fake model: what they propose, the
/// `notAvailable` they answer with when the model or the transcript is missing, and that they never edit the project.
@Suite struct AICommandTests {
    /// A model that is available (or not) and writes `answer`.
    private struct Model: TextModel {
        var available: AIAvailability = .available
        var answer = "Cómo instalar el paquete"
        let contextSize = 4096
        func availability(language: String) -> AIAvailability { available }
        func tokenCount(_ text: String) async -> Int { text.split(whereSeparator: \.isWhitespace).count * 2 + 2 }
        func chapters(instructions: String, prompt: String) async throws -> [ProposedChapter] { [] }
        func text(_ kind: InfoKind, instructions: String, prompt: String, variation: Int) async throws -> String { answer }
    }

    /// The project with a made-up transcript, as `recorder-dev fake-transcript` puts one.
    @MainActor private static func transcribed(in dir: URL) async throws -> URL {
        let url = try await CLIFixtures.package(in: dir)
        let context = EditContext(
            app: AppInfo(name: "test", version: "dev"), cachesRoot: dir.appending(path: "Caches"), defaultStyle: .toma,
            now: { Date() }, makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) })
        let session = try await EditSession.open(url, take: nil, context: context)
        let transcript = FakeTranscript.make(for: session.project.take)
        if let step = TranscriptCommands.create(session.document, transcript) { _ = session.perform(step) }
        _ = await session.flushed()
        await session.close()
        return url
    }

    private func tree(_ url: URL) throws -> [String: Int] {
        var sizes: [String: Int] = [:]
        for case let file as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)! {
            sizes[file.path] = (try? Data(contentsOf: file).hashValue) ?? 0
        }
        return sizes
    }

    @Test @MainActor func aTitleComesWithItsSetTitleCommandAndEditsNothing() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await Self.transcribed(in: dir)
            let before = try tree(url)
            let report = try await AISuggestionRun.info(
                .title, project: url, transcribe: false, environment: CLIFixtures.environment(in: dir), model: Model()
            ) { _ in }
            #expect(report.kind == "title")
            #expect(report.text == "Cómo instalar el paquete")
            #expect(report.command == .object(["command": .string("setTitle"), "title": .string("Cómo instalar el paquete")]))
            #expect(try tree(url) == before)
        }
    }

    @Test @MainActor func aMissingModelIsNotAvailableWithItsReason() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await Self.transcribed(in: dir)
            let environment = CLIFixtures.environment(in: dir)
            let reasons: [(AIUnavailableReason, String)] = [
                (.appleIntelligenceNotEnabled, "Apple Intelligence is not turned on"), (.needsMacOS26, "requires macOS 26"),
                (.unsupportedLanguage("es-MX"), "es-MX"),
            ]
            for (reason, text) in reasons {
                let model = Model(available: .unavailable(reason: reason))
                await #expect(throws: APIError.self) {
                    try await AISuggestionRun.chapters(project: url, transcribe: false, environment: environment, model: model) { _ in }
                }
                do {
                    _ = try await AISuggestionRun.info(
                        .summary, project: url, transcribe: false, environment: environment, model: model
                    ) { _ in }
                    Issue.record("it answered")
                } catch let error as APIError {
                    #expect(error.code == .notAvailable)
                    #expect(error.message.contains(text), "\(error.message)")
                }
            }
        }
    }

    @Test @MainActor func aShortVideoHasNoChaptersAndAProjectWithoutTranscriptSaysHowToMakeOne() async throws {
        try await withTemporaryDirectory { dir in
            let environment = CLIFixtures.environment(in: dir)
            let transcribed = try await Self.transcribed(in: dir)
            do {
                _ = try await AISuggestionRun.chapters(project: transcribed, transcribe: false, environment: environment, model: Model()) { _ in }
                Issue.record("it answered")
            } catch let error as APIError {
                #expect(error.code == .notAvailable)
                #expect(error.message.contains("too short"), "\(error.message)")
            }
            let bare = try await CLIFixtures.package(in: dir, name: "Bare")
            do {
                _ = try await AISuggestionRun.chapters(project: bare, transcribe: false, environment: environment, model: Model()) { _ in }
                Issue.record("it answered")
            } catch let error as APIError {
                #expect(error.code == .notAvailable)
                #expect(error.message.contains("--transcribe") && error.message.contains("toma edit"), "\(error.message)")
            }
        }
    }

    @Test func theProcessRefusesWithoutATranscriptAndListsItsThreeSubcommands() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let help = try await CLIFixtures.toma(["ai", "--help"], in: dir)
            #expect(help.status == 0)
            for name in ["chapters", "title", "summary"] { #expect(help.stdout.contains(name), "\(help.stdout)") }
            for name in ["chapters", "title", "summary"] {
                let run = try await CLIFixtures.toma(["ai", name, url.path, "--json"], in: dir)
                #expect(run.status == 1, "\(name): \(run.stdout) \(run.stderr)")
                #expect(run.errorCode == "notAvailable", "\(name): \(run.stdout)")
            }
            let escaped = try await CLIFixtures.toma(["ai", "chapters", "../x", "--json"], in: dir)
            #expect(escaped.status == 1 && escaped.errorCode == "notAProject")
        }
    }

    @Test func theToolProposesOnlyAndRefusesWhatItCannotRead() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let link = dir.appending(path: "Link.toma")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            let before = try tree(url)
            let mcp = MCPHarness(in: dir)
            let listed = try await mcp.request("tools/list", id: .integer(1))
            let tool = try #require(listed["result"]?["tools"]?.arrayValue?.first { $0["name"] == .string("suggest_chapters") })
            #expect(tool["inputSchema"]?["required"] == .array([.string("project")]))
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(true))
            let none = try await mcp.call("suggest_chapters", ["project": .string(url.path)], id: 2)
            #expect(none["isError"] == .bool(true))
            #expect(none["structuredContent"]?["error"]?["code"] == .string("notAvailable"))
            #expect(none["structuredContent"]?["error"]?["message"]?.stringValue?.contains("apply_commands") == true)
            for (id, path) in [(Int64(3), "Sub/../Fixture.toma"), (4, link.path)] {
                let refused = try await mcp.call("suggest_chapters", ["project": .string(path)], id: id)
                #expect(refused["isError"] == .bool(true))
                #expect(refused["structuredContent"]?["error"]?["code"] == .string("notAProject"))
            }
            let extra = try await mcp.call("suggest_chapters", ["project": .string(url.path), "x": .integer(1)], id: 5)
            #expect(extra["structuredContent"]?["error"]?["code"] == .string("invalidCommand"))
            #expect(try tree(url) == before)
        }
    }
}
