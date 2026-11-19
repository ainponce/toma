// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport

/// `recorder-dev fake-transcript <package>`: puts a made-up transcript in a project (`FakeTranscript`), for screenshots
/// of the voice in the editor without Speech.
struct TranscriptFixture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fake-transcript",
        abstract: "Puts a made-up Spanish transcript in a project, as a transcription would, for screenshots.",
        discussion: """
            Opens the package's last take in an edit session (EditSession.open), performs transcript.create with \
            FakeTranscript.make (the numbers "uno", "dos"… at 2.5 words a second over the segments of its first \
            microphone, in sentences of twelve with a pause of 1.6 s after each and the filler "eh" every twentieth \
            word), which also shows the captions, waits until it is saved and closes the session. With --cleanup, it \
            also sets the noise cleanup of the take's first microphone, and with --normalize turns Normalize Volume on, \
            each in a step of its own, for the voice's jobs in the editor. It exits 1 if the project opens read-only or \
            with a damaged log.
            """
    )

    @Argument(help: "The .toma package.")
    var package: String

    @Option(help: "Words a second.")
    var wordsPerSecond = 2.5

    @Option(help: "Also the noise cleanup of the first microphone: off, gentle or strong.")
    var cleanup: String?

    @Flag(help: "Also turn Normalize Volume on.")
    var normalize = false

    func validate() throws {
        guard wordsPerSecond > 0 else { throw ValidationError("--words-per-second must be positive.") }
        if let cleanup, Self.level(cleanup) == nil { throw ValidationError("--cleanup is off, gentle or strong.") }
    }

    static func level(_ name: String) -> CleanupLevel? {
        ["off": CleanupLevel.off, "gentle": .gentle, "strong": .strong][name]
    }

    func run() async throws {
        let url = URL(fileURLWithPath: package, isDirectory: true)
        let context = EditContext(
            app: AppInfo(name: "recorder-dev", version: "dev"),
            cachesRoot: FileManager.default.temporaryDirectory.appending(path: "recorder-dev-caches", directoryHint: .isDirectory),
            defaultStyle: .toma, now: { Date() },
            makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) })
        let words = try await Self.put(
            in: url, context: context, wordsPerSecond: wordsPerSecond, cleanup: cleanup.flatMap(Self.level), normalize: normalize)
        print("\(words) words")
    }

    /// Opens `url` and performs `transcript.create` with the made-up words, then the cleanup and Normalize asked for; how
    /// many words it has.
    @MainActor
    private static func put(
        in url: URL, context: EditContext, wordsPerSecond: Double, cleanup: CleanupLevel?, normalize: Bool
    ) async throws -> Int {
        let session = try await EditSession.open(url, take: nil, context: context)
        let recovered = session.notices.contains { if case .recovered = $0 { true } else { false } }
        guard session.access == .editable, !recovered else {
            await session.close()
            FileHandle.standardError.write(Data("error: the project opened with access \(session.access), notices \(session.notices)\n".utf8))
            throw ExitCode.failure
        }
        let transcript = FakeTranscript.make(for: session.project.take, wordsPerSecond: wordsPerSecond)
        let words = transcript.takes.reduce(0) { $0 + $1.words.count }
        if let step = TranscriptCommands.create(session.document, transcript) {
            _ = session.perform(step)
        }
        let take = session.project.take
        if let cleanup, let microphone = take.tracks.first(where: { $0.kind == .microphone && !$0.segments.isEmpty }),
           let step = VoiceCommands.setCleanup(session.document, track: AudioPlan.key(take: take.id, track: microphone.id), cleanup) {
            _ = session.perform(step)
        }
        if normalize, let step = VoiceCommands.setNormalize(session.document, true) {
            _ = session.perform(step)
        }
        _ = await session.flushed()
        await session.close()
        return words
    }
}
