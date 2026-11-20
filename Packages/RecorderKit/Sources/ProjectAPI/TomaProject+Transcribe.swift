// SPDX-License-Identifier: GPL-3.0-or-later

extension TomaProject {
    /// `transcribe{language?, replace?}` (plan 4b decision 23): the local transcription of the takes the sequence shows,
    /// as the app's "Transcribe" makes it. Not available yet from the API: Task A2 runs it.
    func runTranscription(language: String?, replace: Bool) async throws -> CommandResult {
        throw APIError(.notAvailable, "transcribe is not available from the API yet: transcribe the project in Toma")
    }
}
