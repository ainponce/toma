// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import CoreMedia
import Foundation
import Observation
import Transcription
import os

/// Follow the Voice (phase 3 design §8.4; plan 3d, decisions 13 to 15): while a take records with the teleprompter's
/// "Follow the Voice" on, its microphone is heard live (`MeteredSource.listen` into a `LiveMicrophoneFeed`, which copies
/// each block and returns, so the take never waits) by the system's live engine (`LiveSpeech`: dictation when its model
/// is on the Mac, else the transcription's), and what it says moves `place` (`TeleprompterFollow.Place`: final results
/// confirmed, volatile ones on trial, never back) from the word the take began at. A new take (`takeSerial`, a restart's
/// too) starts again; while the take is paused nothing is heard, and nothing moves (the final result of what was said
/// just before the pause is confirmed, and shows once the take goes on).
///
/// It never asks for a permission nor downloads a model (`LiveSpeech.availability` only asks what is installed). When it
/// cannot follow, `note` says why and the teleprompter goes up at its speed: macOS 15, the language's model missing, a
/// take without a microphone, or the engine failing (for a permission or anything else) for the rest of the take. Nothing
/// of it goes into the package or the video.
@MainActor @Observable
final class TeleprompterVoice {
    /// Where the speaker is in the script: what the teleprompter shows while it follows.
    private(set) var place = TeleprompterFollow.Place(script: ScriptWords(""), from: 0)
    /// Why Follow the Voice, on, does not follow; `nil` while it follows, or is off.
    private(set) var note: TeleprompterFollow.Note?

    /// The take, as the teleprompter sees it.
    struct Take: Equatable {
        var followsVoice: Bool
        /// A take records (paused or not).
        var isRecording: Bool
        /// The user or the system paused it.
        var isPaused: Bool
        /// `RecordingController.takeSerial`.
        var serial: Int
        /// `RecordingController.recordsMicrophone`.
        var recordsMicrophone: Bool
    }

    @ObservationIgnored private let recording: RecordingController
    @ObservationIgnored private var take: Take?
    /// What the Mac has to follow with: `nil` until it is known.
    @ObservationIgnored private var availability: LiveSpeechAvailability?
    @ObservationIgnored private var asking: Task<Void, Never>?
    @ObservationIgnored private var session: Session?
    /// The number of the next session: what each one's results are told by.
    @ObservationIgnored private var nextSession = 0
    /// The engine failed during the take of `serial`: that take goes on at the teleprompter's speed.
    @ObservationIgnored private var failure: (serial: Int, note: TeleprompterFollow.Note)?
    #if DEBUG
    /// A showcase set `place` and `note`: nothing changes them.
    @ObservationIgnored private var isShowcase = false
    #endif

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Teleprompter")

    /// The microphone of one take, heard (from the take's start, or from when it could be followed again).
    private final class Session {
        /// What its results are told by: a session ended and another begun for the same take are not mixed up.
        let id: Int
        let serial: Int
        let source: MeteredSource
        let feed: LiveMicrophoneFeed
        var task: Task<Void, Never>?
        /// The source gives its blocks to the feed (not while the take is paused).
        private(set) var isListening = false

        init(id: Int, serial: Int, source: MeteredSource, feed: LiveMicrophoneFeed) {
            self.id = id
            self.serial = serial
            self.source = source
            self.feed = feed
        }

        /// Listens to the source or stops: the listener only copies each block into the feed and returns.
        func listen(_ on: Bool) {
            guard on != isListening else { return }
            isListening = on
            guard on else {
                source.listen(nil)
                return
            }
            let feed = feed
            source.listen { @Sendable sample in feed.append(sample) }
        }

        /// Stops listening; the engine gets what is left of the feed, and stops.
        func end() {
            listen(false)
            feed.finish()
            task?.cancel()
        }
    }

    init(recording: RecordingController) {
        self.recording = recording
    }

    /// Follows `script` from `word` again: a new take, the script edited, or Follow the Voice turned on.
    func restart(script: ScriptWords, at word: Int) {
        #if DEBUG
        if isShowcase { return }
        #endif
        place = TeleprompterFollow.Place(script: script, from: word)
    }

    /// The take and the switch as they are now: listens, stops or says why it cannot.
    func update(_ take: Take) {
        #if DEBUG
        if isShowcase { return }
        #endif
        let before = self.take
        self.take = take
        // Turned on, or a new take: what the Mac has is asked again (a language downloaded in the meantime), and a take
        // that failed before is tried again.
        if take.followsVoice, before?.followsVoice != true || before?.serial != take.serial { refreshAvailability() }
        apply()
    }

    /// Asks again what the Mac has to follow with (the teleprompter came back on the screen): only what is installed.
    func refreshAvailability() {
        #if DEBUG
        if isShowcase { return }
        #endif
        failure = nil
        asking?.cancel()
        let preferred = TranscriptionPreferencesStore().preferences.language
        asking = Task { [weak self] in
            let availability = await LiveSpeech.availability(preferred: preferred)
            guard !Task.isCancelled, let self else { return }
            self.availability = availability
            apply()
        }
    }

    // MARK: - Private

    private func apply() {
        guard let take, take.followsVoice else {
            endSession()
            setNote(nil)
            return
        }
        let note = note(for: take)
        setNote(note)
        guard note == nil, take.isRecording, case .available(let language, let kind)? = availability else {
            // Not recording, or it cannot follow; while what the Mac has is asked, a take that records waits for it.
            if note != nil || !take.isRecording { endSession() }
            return
        }
        if let session, session.serial != take.serial { endSession() }
        if session == nil { startSession(language: language, kind: kind, serial: take.serial) }
        let goesOn = session?.isListening == false && !take.isPaused
        session?.listen(!take.isPaused)
        // What was said before a pause and confirmed during it shows once the take goes on.
        if goesOn { place.showConfirmed() }
    }

    private func note(for take: Take) -> TeleprompterFollow.Note? {
        if let failure, failure.serial == take.serial { return failure.note }
        switch availability {
        case .needsMacOS26?: return .needsMacOS26
        case .modelNotInstalled(let language)?: return .missingLanguage(language)
        case .notOnThisMac?, .noLanguage?: return .failed
        case .available?, nil: break
        }
        if take.isRecording, !take.recordsMicrophone { return .noMicrophone }
        return nil
    }

    private func setNote(_ note: TeleprompterFollow.Note?) {
        if note != self.note { self.note = note }
    }

    /// Hears the microphone of the take `serial` with the engine of `kind` in `language`.
    private func startSession(language: String, kind: LiveSpeechEngineKind, serial: Int) {
        guard let source = recording.microphoneSource else {
            failed(serial: serial, note: .noMicrophone)
            return
        }
        guard let engine = LiveSpeech.engine(kind) else {
            failed(serial: serial, note: .needsMacOS26)
            return
        }
        let id = nextSession
        nextSession += 1
        let session = Session(id: id, serial: serial, source: source, feed: LiveMicrophoneFeed())
        let results = engine.results(of: session.feed.chunks, language: language)
        self.session = session
        session.task = Task { [weak self] in
            do {
                for try await result in results {
                    self?.heard(result, session: id)
                }
                // Ended here (`endSession`), or by itself: the results end only once the feed does, so a take still
                // recording lost its engine.
                guard !Task.isCancelled else { return }
                self?.ended(nil, session: id)
            } catch {
                guard !Task.isCancelled else { return }
                self?.ended(error, session: id)
            }
        }
        Self.logger.info("Following the voice in \(language, privacy: .public) with \(kind.rawValue, privacy: .public)")
    }

    /// A result of session `id`: it moves the place while the take records; while it is paused, nothing moves, but the
    /// final result of what was said just before the pause is confirmed, so what comes after it aligns from there.
    private func heard(_ result: LiveSpeechResult, session id: Int) {
        guard let session, session.id == id else { return }
        if session.isListening {
            place.hear(result.text, isFinal: result.isFinal)
        } else if result.isFinal {
            place.confirm(result.text)
        }
    }

    /// The engine of session `id` stopped by itself, with `error` or none: the take goes on at the teleprompter's speed.
    private func ended(_ error: (any Error)?, session id: Int) {
        guard let session, session.id == id else { return }
        let serial = session.serial
        Self.logger.error("Cannot follow the voice: \(error.map { String(describing: $0) } ?? "the engine stopped", privacy: .public)")
        if case .modelNotInstalled(let language)? = error as? TranscriptionError {
            failed(serial: serial, note: .missingLanguage(language))
        } else {
            failed(serial: serial, note: .failed)
        }
    }

    private func failed(serial: Int, note: TeleprompterFollow.Note) {
        endSession()
        failure = (serial, note)
        apply()
    }

    private func endSession() {
        session?.end()
        session = nil
    }

    #if DEBUG
    /// `TOMA_SHOWCASE_P3_TELEPROMPTER`: following `script` at `word`, or saying `note`; nothing is heard.
    func showcase(script: ScriptWords, word: Int, note: TeleprompterFollow.Note?) {
        place = TeleprompterFollow.Place(script: script, from: word)
        self.note = note
        isShowcase = true
    }
    #endif
}
