// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Editing
import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
import Transcription
@testable import ProjectAPI

/// `transcribe` (plan 4b decision 23): what the app's "Transcribe" makes, in one step, with an engine of the test's
/// (Speech is never called) and never a model downloaded.
@MainActor @Suite struct APITranscribeTests {
    @Test func transcribeIsOneStep() async throws {
        try await withTemporaryDirectory { dir in
            var environment = APIFixtures.environment(in: dir)
            environment.speech = Words()
            let url = try await APIFixtures.package(in: dir).package.url
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            let result = try await project.apply(.transcribe(language: "es-MX", replace: false))
            #expect(result.changed && result.label == EditLabel.transcriptCreate.rawValue && result.undo == result.label)
            let transcript = try #require(project.document.transcript)
            #expect(transcript.language == "es-MX" && transcript.engine == SpeechLanguages.engineID)
            #expect(transcript.takes.map(\.take) == ["take-001"] && transcript.takes[0].track == "mic")
            #expect(transcript.takes[0].words.map(\.text).prefix(2) == ["palabra", "palabra"])
            // The captions are shown with it, as the app's step does.
            #expect(project.document.captions.show)
            guard case let .do(_, _, label, _, _)? = try APIFixtures.logEntries(url).last else {
                Issue.record("the last line of the log is no step")
                return
            }
            #expect(label == EditLabel.transcriptCreate.rawValue)

            // One undo takes it all back.
            _ = try await project.undo()
            #expect(project.document.transcript == nil)
            await project.close()
        }
    }

    @Test func withoutAnEngineIsNotAvailable() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            #expect(environment.speech == nil)
            // A project of phase 3, which stays as it is until a command changes it.
            let url = try await APIFixtures.version4(in: dir)
            let before = try treeHash(url)
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            let error = await APIFixtures.apiError { _ = try await project.apply(.transcribe(language: "es-MX", replace: false)) }
            #expect(error?.code == .notAvailable)
            #expect(project.document.transcript == nil)
            await project.close()
            #expect(try treeHash(url) == before)

            // Reading only, it is refused before anything: a transcription is an edit.
            let reading = try await TomaProject.open(url, mode: .read, environment: environment)
            #expect(await APIFixtures.apiError { _ = try await reading.apply(.transcribe(language: nil, replace: false)) }?.code == .refused)
            await reading.close()
        }
    }

    @Test func aModelNotInstalledIsNotAvailable() async throws {
        try await withTemporaryDirectory { dir in
            var environment = APIFixtures.environment(in: dir)
            environment.speech = NoModel()
            let url = try await APIFixtures.version4(in: dir)
            let before = try treeHash(url)
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            let error = await APIFixtures.apiError { _ = try await project.apply(.transcribe(language: "fr-FR", replace: false)) }
            #expect(error?.code == .notAvailable && error?.message.contains("fr-FR") == true)
            #expect(project.document.transcript == nil)
            await project.close()
            #expect(try treeHash(url) == before)
        }
    }

    @Test func losingCorrectionsNeedsReplace() async throws {
        try await withTemporaryDirectory { dir in
            var environment = APIFixtures.environment(in: dir)
            environment.speech = Words()
            // A transcript in es-MX where a caption was started by hand at the fourth word.
            let url = try await APIFixtures.transcribed(in: dir, environment: environment)
            let session = try await EditSession.open(url, take: nil, context: environment.editContext)
            let corrected = try #require(TranscriptCommands.toggleBreak(session.document, TranscriptWordRef(take: 0, word: 3)))
            #expect(session.perform(corrected) == .applied)
            _ = await session.flushed()
            await session.close()

            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            let before = project.document.transcript
            // Without a language, the transcript's: every take has its words in es-MX, so each is heard again.
            let error = await APIFixtures.apiError { _ = try await project.apply(.transcribe(language: nil, replace: false)) }
            #expect(error?.code == .refused && error?.message.contains("1 corrected word") == true, "\(String(describing: error))")
            #expect(project.document.transcript == before)

            let result = try await project.apply(.transcribe(language: nil, replace: true))
            #expect(result.changed && result.label == EditLabel.transcriptCreate.rawValue)
            let words = try #require(project.document.transcript?.takes.first?.words)
            #expect(words.allSatisfy { $0.text == "palabra" && !$0.breakBefore })
            await project.close()
        }
    }

    @Test func aSecondTakeIsMerged() async throws {
        try await withTemporaryDirectory { dir in
            var environment = APIFixtures.environment(in: dir)
            environment.speech = Words()
            // Both takes in the sequence, the transcript of the first one alone (corrected by hand at its first word).
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            var first = FakeTranscript.make(for: try #require(project.takes.first { $0.id == "take-001" }))
            first.takes[0].words[0].text = "Corregido"
            document.transcript = first
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(document), to: project.package.editURL)

            let opened = try await TomaProject.open(project.package.url, mode: .edit, environment: environment)
            let result = try await opened.apply(.transcribe(language: "es-MX", replace: false))
            #expect(result.changed && result.label == EditLabel.transcriptCreate.rawValue)
            let transcript = try #require(opened.document.transcript)
            #expect(transcript.takes.map(\.take) == ["take-001", "take-002"])
            // The first take's words as they were, corrections included; the second's, heard.
            #expect(transcript.takes[0] == first.takes[0])
            #expect(!transcript.takes[1].words.isEmpty && transcript.takes[1].words.allSatisfy { $0.text == "palabra" })
            await opened.close()
        }
    }

    /// The app opens the project while the API transcribes it (the session, and `edit.lock`, open only once there is a
    /// transcript): the transcription is `locked`, and nothing of it reaches the log.
    @Test func theAppTakingTheProjectMeanwhileIsLocked() async throws {
        try await withTemporaryDirectory { dir in
            let gate = Gate()
            var environment = APIFixtures.environment(in: dir)
            environment.speech = Held(gate: gate)
            let url = try await APIFixtures.version4(in: dir)
            let entries = try APIFixtures.logEntries(url).count
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            let transcribing = Task { try await project.apply(.transcribe(language: "es-MX", replace: false)) }
            #expect(await eventually(timeout: .seconds(60)) { gate.arrived })
            let app = try await EditSession.open(url, take: nil, context: environment.editContext)
            #expect(app.access == .editable)
            gate.open()
            let error = await APIFixtures.apiError { _ = try await transcribing.value }
            #expect(error?.code == .locked, "\(String(describing: error))")
            #expect(project.document.transcript == nil)
            await app.close()
            await project.close()
            #expect(try APIFixtures.logEntries(url).count == entries)
        }
    }

    /// The app corrects the transcript and closes while the API transcribes: the step is made of the document the session
    /// opens on, so the correction it would lose is `refused` without `replace`.
    @Test func aCorrectionMadeMeanwhileNeedsReplace() async throws {
        try await withTemporaryDirectory { dir in
            let gate = Gate()
            var environment = APIFixtures.environment(in: dir)
            environment.speech = Held(gate: gate)
            let url = try await APIFixtures.transcribed(in: dir, environment: environment)
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            let transcribing = Task { try await project.apply(.transcribe(language: nil, replace: false)) }
            #expect(await eventually(timeout: .seconds(60)) { gate.arrived })
            let app = try await EditSession.open(url, take: nil, context: environment.editContext)
            let corrected = try #require(TranscriptCommands.toggleBreak(app.document, TranscriptWordRef(take: 0, word: 3)))
            #expect(app.perform(corrected) == .applied)
            _ = await app.flushed()
            await app.close()
            gate.open()
            let error = await APIFixtures.apiError { _ = try await transcribing.value }
            #expect(error?.code == .refused && error?.message.contains("1 corrected word") == true, "\(String(describing: error))")
            #expect(project.document.transcript?.takes.first?.words[3].breakBefore == true)
            await project.close()
        }
    }
}

// MARK: - Engines

/// An engine that hears "palabra" every half second of each span, from 0.15 s into it: never where `FakeTranscript` has a
/// word (0.3 s into a segment, then every 0.4 s), so no word of it stands for a corrected one there.
private struct Words: SpeechEngine {
    func transcribe(_ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechRun] {
        progress(1)
        return audio.spans.flatMap { span -> [SpeechRun] in
            let start = Double(span.frames.lowerBound) / TrackAudio.sampleRate
            let end = Double(span.frames.upperBound) / TrackAudio.sampleRate
            return stride(from: start + 0.15, to: end - 0.4, by: 0.5).map { SpeechRun(text: " palabra", start: $0, end: $0 + 0.3) }
        }
    }
}

/// An engine without the model of any language on this Mac.
private struct NoModel: SpeechEngine {
    func transcribe(_ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechRun] {
        throw TranscriptionError.modelNotInstalled(language)
    }
}

/// Where `Held` waits until the test opens it, and says when the engine got there.
private final class Gate: Sendable {
    private let state = Mutex((arrived: false, open: false))

    var arrived: Bool { state.withLock { $0.arrived } }
    func open() { state.withLock { $0.open = true } }

    func wait() async throws {
        state.withLock { $0.arrived = true }
        while !state.withLock({ $0.open }) { try await Task.sleep(for: .milliseconds(5)) }
    }
}

/// `Words`, once `gate` opens.
private struct Held: SpeechEngine {
    let gate: Gate

    func transcribe(_ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechRun] {
        try await gate.wait()
        return try await Words().transcribe(audio, language: language, progress: progress)
    }
}
