// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat
import ProjectJobs
import Transcription

extension TomaProject {
    /// `transcribe{language?, replace?}` (plan 4b decision 23): the local transcription of the takes the sequence shows,
    /// as the app's "Transcribe" makes it, in one step (`transcript.create`).
    ///
    /// - The language is `language`, or the transcript's, or the one the app picks when none was chosen
    ///   (`SpeechLanguages.defaultLanguage()`).
    /// - It hears what "Transcribe" hears (`SequenceTranscription.takes(toTranscribe:)`): each take of the sequence whose
    ///   words the transcript lacks in that language, or each of them again once none lacks its own; one job after the
    ///   other, in the sequence's order, on a queue of its own (`SequenceVoiceJobs.transcriptions`).
    /// - Their words go into the document as the app puts them: `TranscriptCommands.create` when the transcript has no
    ///   take but those heard, `mergeTakes` otherwise (the other takes' words, corrected or not, stay).
    /// - Corrections of the takes heard that it would lose (`TranscriptCommands.lostCorrections`) are `refused` with how
    ///   many, unless `replace`.
    /// - Without an engine (before macOS 26), on a Mac that cannot transcribe, or without the model of the language on
    ///   this Mac, `notAvailable`: the API never downloads a model (only the app's "Download" does).
    func runTranscription(language: String?, replace: Bool) async throws -> CommandResult {
        let session = try editableSession()
        guard let engine = environment.speech else {
            throw APIError(.notAvailable, "transcribing needs macOS 26: there is no speech engine on this Mac")
        }
        let project = session.project, document = session.document
        let chosen: String
        if let language, !language.isEmpty {
            chosen = language
        } else if let language = document.transcript?.language, !language.isEmpty {
            chosen = Locale(identifier: language).identifier(.bcp47)
        } else if let language = await SpeechLanguages.defaultLanguage() {
            chosen = language
        } else {
            throw APIError(.notAvailable, "this Mac transcribes no language")
        }
        let shown = SequenceAnalyses.takes(shownBy: document, in: project)
        let wanted = SequenceTranscription.takes(toTranscribe: document, shown: shown, language: chosen)
        guard !wanted.isEmpty else {
            throw APIError(.refused, "no take of the sequence has a microphone, system audio or device audio that recorded anything")
        }
        let caches = ProjectCaches(root: environment.cachesRoot, projectID: project.manifest.resolvedProjectID)
        let voice = SequenceVoiceJobs(project: project, caches: caches, engine: engine, isolator: environment.isolator)
        let transcript = try await Self.transcribe(wanted, language: chosen, document: document, voice: voice)

        // The document as it is now.
        let current = try editableSession().document
        let heard = Set(transcript.takes.map(\.take))
        let lost = current.transcript.map { TranscriptCommands.lostCorrections($0, transcript, inTakes: heard) } ?? 0
        if lost > 0, !replace {
            throw APIError(
                .refused,
                "transcribing again replaces \(lost) corrected word\(lost == 1 ? "" : "s"): give \"replace\": true to replace them")
        }
        let whole = current.transcript.map { $0.takes.allSatisfy { heard.contains($0.take) } } ?? true
        guard let step = whole ? TranscriptCommands.create(current, transcript) : TranscriptCommands.mergeTakes(current, transcript)
        else { return result("transcribe", changed: false, label: nil, created: nil) }
        return try await perform(step, command: "transcribe", created: nil, in: session)
    }

    /// The words of each take of `wanted` heard in `language`, one job after the other on a queue of their own, put
    /// together in the order of the sequence.
    @concurrent private nonisolated static func transcribe(
        _ wanted: [String], language: String, document: EditDocument, voice: SequenceVoiceJobs
    ) async throws -> Transcript {
        let jobs = voice.transcriptions(language: language, document: document).filter { kind, _ in
            if case let .transcription(take, _) = kind { wanted.contains(take) } else { false }
        }
        let queue = ProjectJobs()
        var takes: [TranscriptTake] = []
        var heard = Transcript(language: language, engine: SpeechLanguages.engineID, takes: [])
        do {
            for (kind, work) in jobs {
                guard case let .transcript(transcript) = try await queue.result(of: kind, work: work) else { continue }
                takes += transcript.takes
                heard.language = transcript.language
                heard.engine = transcript.engine
            }
        } catch {
            await queue.cancelAll()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw transcriptionError(error)
        }
        guard !takes.isEmpty else { throw APIError(.refused, "nothing of the takes was heard") }
        heard.takes = takes
        return heard
    }

    /// What a transcription's job threw, as the API's error.
    private nonisolated static func transcriptionError(_ error: any Error) -> APIError {
        guard let error = error as? JobError else { return APIError(.refused, "the transcription failed: \(error)") }
        switch error.problem {
        case .needsMacOS26:
            return APIError(.notAvailable, "transcribing needs macOS 26")
        case .notOnThisMac:
            return APIError(.notAvailable, "this Mac cannot transcribe")
        case let .modelNotInstalled(locale):
            return APIError(
                .notAvailable, "the model of \(locale) is not on this Mac: download it in Toma (Captions ▸ Transcribe) first")
        case let .sourceUnreadable(file):
            return APIError(.refused, "the transcription failed: \(file) cannot be read")
        case .noSpace:
            return APIError(.refused, "the transcription failed: the disk is full")
        case let .failed(why):
            return APIError(.refused, "the transcription failed: \(why)")
        }
    }
}
