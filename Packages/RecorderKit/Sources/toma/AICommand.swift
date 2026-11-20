// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ArgumentParser
import Foundation
import LocalAI
import ProjectAPI
import ProjectFormat

/// `toma ai chapters|title|summary <package>`: what the on-device model (Apple Intelligence, macOS 26) proposes for a
/// project from its transcript (plan 5b, Task I4). They only propose: the `--json` result carries the commands
/// (`addMarker`, `setTitle`, `setSummary`) for `toma edit --file` to apply once someone has looked at them. Nothing
/// leaves this Mac. Without the model, the result is `notAvailable` with the reason.
struct AICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai",
        abstract: "Propose chapters, a title or a summary with the on-device model. Never edits the project.",
        discussion: """
            Needs macOS 26 with Apple Intelligence turned on, and a transcript (--transcribe makes one). The result \
            says what to apply: with --json, the commands for `toma edit --file`.
            """,
        subcommands: [Chapters.self, Title.self, Summary.self])

    struct Chapters: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "chapters",
            abstract: "Propose chapters from the transcript: one line each, with its time and title.",
            discussion: "With --json, the chapters and the addMarker commands that would add them.")

        @Argument(help: "The .toma package.")
        var package: String

        @Flag(help: "Transcribe the project first if it has no transcript (this edits the project).")
        var transcribe = false

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let report = try await AISuggestionRun.chapters(
                project: try CLI.package(package), transcribe: transcribe, environment: CLI.environment,
                progress: AICommand.progressToStandardError)
            if report.skippedParts > 0 {
                Terminal.error("warning: \(report.skippedParts) part(s) of the transcript could not be read; their chapters are missing")
            }
            output.emit(report, text: \.text)
        }
    }

    struct Title: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "title", abstract: "Propose a title (up to 70 characters) from the transcript.",
            discussion: "With --json, the title and the setTitle command that would set it.")

        @Argument(help: "The .toma package.")
        var package: String

        @Flag(help: "Transcribe the project first if it has no transcript (this edits the project).")
        var transcribe = false

        @Option(help: "0 is the most likely title; 1, 2… give other ones.")
        var variation = 0

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let report = try await AISuggestionRun.info(
                .title, project: try CLI.package(package), transcribe: transcribe, variation: variation,
                environment: CLI.environment, progress: AICommand.progressToStandardError)
            output.emit(report, text: \.text)
        }
    }

    struct Summary: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "summary", abstract: "Propose a summary (2 to 4 sentences) from the transcript.",
            discussion: "With --json, the summary and the setSummary command that would set it.")

        @Argument(help: "The .toma package.")
        var package: String

        @Flag(help: "Transcribe the project first if it has no transcript (this edits the project).")
        var transcribe = false

        @Option(help: "0 is the most likely summary; 1, 2… give other ones.")
        var variation = 0

        @OptionGroup var output: OutputOptions

        func run() async throws {
            let report = try await AISuggestionRun.info(
                .summary, project: try CLI.package(package), transcribe: transcribe, variation: variation,
                environment: CLI.environment, progress: AICommand.progressToStandardError)
            output.emit(report, text: \.text)
        }
    }

    @Sendable static func progressToStandardError(_ progress: AIProgress) {
        Terminal.error("progress: part \(progress.part) of \(progress.parts)")
    }
}

/// What `toma ai` and the MCP tool `suggest_chapters` share: open the project to read, ask the model, report.
@MainActor enum AISuggestionRun {
    /// Chapters for the project at `project`. With `transcribe` and no transcript, it is transcribed first (`transcribe`
    /// command, one undo step), then the project is read again. Throws `APIError`: `notAvailable` for whatever the model
    /// or the transcript lacks, `locked` for a project the app is editing (only `transcribe` needs it).
    static func chapters(
        project: URL, transcribe: Bool, environment: APIEnvironment, model: any TextModel = SystemTextModel(),
        transcriptHint: String = Hint.cli, progress: @escaping @Sendable (AIProgress) -> Void
    ) async throws -> LocalAI.ChapterReport {
        let (document, existing) = try await read(project, transcribe: transcribe, environment: environment)
        do {
            let suggestions = try await ChapterSuggester(model: model).suggest(
                document: document, existing: existing, progress: progress)
            return LocalAI.ChapterReport(suggestions, duration: TimeMap(sequence: document.sequence).duration)
        } catch let error as AIError {
            throw apiError(error, transcriptHint: transcriptHint)
        }
    }

    /// A title or a summary for the project at `project`.
    static func info(
        _ kind: InfoKind, project: URL, transcribe: Bool, variation: Int = 0, environment: APIEnvironment,
        model: any TextModel = SystemTextModel(), transcriptHint: String = Hint.cli,
        progress: @escaping @Sendable (AIProgress) -> Void
    ) async throws -> InfoReport {
        let (document, _) = try await read(project, transcribe: transcribe, environment: environment)
        let suggester = InfoSuggester(model: model)
        do {
            let text =
                kind == .title
                ? try await suggester.title(document: document, variation: variation, progress: progress)
                : try await suggester.summary(document: document, variation: variation, progress: progress)
            return InfoReport(kind: kind, text: text)
        } catch let error as AIError {
            throw apiError(error, transcriptHint: transcriptHint)
        }
    }

    enum Hint {
        static let cli =
            "this project has no transcript; run `toma ai chapters <package> --transcribe` or `toma edit <package> '{\"command\":\"transcribe\"}'`"
        static let mcp =
            "this project has no transcript; run apply_commands with {\"command\": \"transcribe\"} first"
    }

    /// The document on disk and the output time of every marker with a name, opened to read; after a transcription if
    /// `transcribe` and there is no transcript.
    private static func read(
        _ url: URL, transcribe: Bool, environment: APIEnvironment
    ) async throws -> (EditDocument, existing: [Int64]) {
        var opened = try await TomaProject.open(url, mode: .read, environment: environment)
        if transcribe, opened.document.transcript == nil {
            await opened.close()
            let batch = await ProjectRunner.apply(
                [.transcribe(language: nil, replace: false)], to: url, environment: environment)
            if let error = batch.error { throw error }
            opened = try await TomaProject.open(url, mode: .read, environment: environment)
        }
        let document = opened.document
        let existing = await opened.markers.filter { !$0.name.isEmpty }.map(\.output)
        await opened.close()
        return (document, existing)
    }

    /// `error` as the stable `notAvailable` with the reason in English (Task I4).
    static func apiError(_ error: AIError, transcriptHint: String) -> APIError {
        let message: String =
            switch error {
            case .unavailable(.needsMacOS26): "the on-device model requires macOS 26"
            case .unavailable(.deviceNotEligible): "this Mac is not eligible for Apple Intelligence"
            case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is not turned on"
            case .unavailable(.modelNotReady): "Apple Intelligence's model is not ready yet; try again in a while"
            case .unavailable(.unknown): "the on-device model is not available"
            case let .unavailable(.unsupportedLanguage(language)): "the on-device model does not write \(language)"
            case .noTranscript: transcriptHint
            case .noWords: "every word of the transcript is cut, so there is nothing to read"
            case .tooShort: "the video is too short for chapters"
            case .contextTooLong: "the transcript is too long for the on-device model"
            case .refused: "the on-device model declined to write this"
            case .busy: "the on-device model is busy; try again in a moment"
            case let .failed(reason): "the on-device model failed: \(reason)"
            }
        return APIError(.notAvailable, message)
    }
}
