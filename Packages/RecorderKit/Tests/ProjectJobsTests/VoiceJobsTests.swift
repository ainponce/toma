// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import Editing
import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
import Transcription
// @testable only for `ProjectJobs.isRunning`, which lets a test wait until a cancelled work has returned, and for
// `VoiceJobs.trackAudio` (`SharedTrackAudio`), the one load of each track every job shares.
@testable import ProjectJobs

// Every test here runs in `make tsan`. None uses the Audio Unit or Speech: the clean voice is the dry sound negated,
// written by a fake isolation, and the words come from a fake engine.

private let base = HostTime(nanoseconds: 7_000_000_000_000)
private let takeID = "take-001"
private let micID = "mic"
private let systemID = "system-audio"
private let micKey = AudioPlan.key(take: takeID, track: micID)
private let systemKey = AudioPlan.key(take: takeID, track: systemID)

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }
private func clean(_ segment: Int) -> AnalysisJobKind { .soundIsolation(take: takeID, track: micID, segment: segment) }
private let micLoudness = AnalysisJobKind.loudness(take: takeID, track: micID)
private let systemLoudness = AnalysisJobKind.loudness(take: takeID, track: systemID)

/// Long enough for a loaded machine under the thread sanitizer: `eventually` returns as soon as it holds.
private let patience = Duration.seconds(60)

/// Where a fake's work waits until the test opens it; a wait whose task is cancelled ends at once with
/// `CancellationError`, as an Audio Unit stops when its task is.
private final class Gate: Sendable {
    private struct State {
        var open = false
        var next = 0
        var arrivals = 0
        var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    func wait() async throws {
        let id = state.withLock { state in
            state.next += 1
            state.arrivals += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let open = state.withLock { state in
                    if !state.open { state.waiting[id] = continuation }
                    return state.open
                }
                if open { return continuation.resume() }
                if Task.isCancelled { end(id) }
            }
        } onCancel: {
            end(id)
        }
    }

    var arrivals: Int { state.withLock { $0.arrivals } }

    /// The waits end, and later ones end at once.
    func open() {
        let waiting = state.withLock { state in
            state.open = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for continuation in waiting { continuation.resume() }
    }

    private func end(_ id: Int) {
        state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(throwing: CancellationError())
    }
}

/// Timeline frames `frames` of `audio`, its channels averaged, read off the cooperative pool.
private func monoFrames(of audio: TrackAudio, _ frames: Range<Int64>) async throws -> [Float] {
    try await offThePool {
        let reader = audio.makeReader()
        var samples: [Float] = []
        reader.read(frames, into: &samples)
        let channels = audio.channels
        guard channels > 1 else { return samples }
        return stride(from: 0, to: samples.count, by: channels).map { i in samples[i..<(i + channels)].reduce(0, +) / Float(channels) }
    }
}

/// Writes `samples` as the cleanup caches hold the clean voice: CAF, Float32 LPCM, mono, 48 kHz.
private func writeCleanFile(_ samples: [Float], to url: URL) throws {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        AVAudioFileTypeKey: kAudioFileCAFType,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
    file.close()
}

/// The samples of the clean file at `url`, all of them (a read can give fewer than it is asked for).
private func readCleanFile(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
    var samples: [Float] = []
    while Int64(samples.count) < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    }
    return samples
}

/// An isolation that writes the dry sound negated as the clean voice, and keeps the segment of each call; with a gate,
/// it waits on it once the file is written.
private final class FakeIsolation: VoiceIsolating {
    let isAvailable: Bool
    private let gate: Gate?
    private let made = Mutex<[String]>([])

    init(isAvailable: Bool = true, gate: Gate? = nil) {
        self.isAvailable = isAvailable
        self.gate = gate
    }

    /// `TrackAudioSpan.segment` of each call, in order.
    var calls: [String] { made.withLock { $0 } }

    func clean(_ audio: TrackAudio, span: TrackAudioSpan, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        made.withLock { $0.append(span.segment) }
        let dry = try await monoFrames(of: audio, span.frames)
        try await offThePool { try writeCleanFile(dry.map { -$0 }, to: url) }
        progress(0.5)
        try await gate?.wait()
        progress(1)
    }
}

/// An engine that hears one word in each span, from 0.1 s to 0.5 s into it.
private struct FakeEngine: SpeechEngine {
    func transcribe(_ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechRun] {
        progress(1)
        return audio.spans.enumerated().map { i, span in
            let start = Double(span.frames.lowerBound) / TrackAudio.sampleRate
            return SpeechRun(text: " palabra\(i)", start: start + 0.1, end: start + 0.5)
        }
    }
}

/// An engine of a language whose model is not on this Mac.
private struct NotInstalledEngine: SpeechEngine {
    func transcribe(_ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechRun] {
        throw TranscriptionError.modelNotInstalled(language)
    }
}

/// A take of the display, 5 s from `base`, with a microphone of two segments (0.5–2 s, 3–4.5 s) and system audio of
/// one (1–3 s), and the project's cache folder next to its package.
private struct VoiceFixture {
    let project: LoadedProject
    let caches: ProjectCaches

    init(in dir: URL, audio: Bool = true) async throws {
        let builder = try TakeBuilder(in: dir, name: "voice")
        try await builder.addVideoTrack(
            id: "display-1",
            source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 320, height: 180), pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 5, framesPerSecond: 10, width: 320, height: 180)])
        if audio {
            try await builder.addAudioTrack(
                id: micID, source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
                segments: [AudioSegmentSpec(start: at(0.5), seconds: 1.5), AudioSegmentSpec(start: at(3), seconds: 1.5, frequency: 660)])
            try await builder.addAudioTrack(
                id: systemID, kind: .systemAudio, source: TrackSource(name: "System Audio", excludedBundleIDs: []),
                segments: [AudioSegmentSpec(start: at(1), seconds: 2, frequency: 220)])
        }
        project = try builder.write()
        caches = ProjectCaches(root: dir.appending(path: "Caches", directoryHint: .isDirectory), projectID: project.manifest.resolvedProjectID)
    }

    var micSegments: [SegmentRecord] { project.take.track(micID)?.segments ?? [] }

    func voiceJobs(_ isolation: FakeIsolation = FakeIsolation(), engine: (any SpeechEngine)? = FakeEngine(), caches: ProjectCaches? = nil)
        -> VoiceJobs
    {
        VoiceJobs(project: project, caches: caches ?? self.caches, engine: engine, isolator: isolation)
    }

    /// The legacy document with the microphone at gain 1 and `cleanup`, and Normalize as given.
    func document(cleanup: Double = 0, normalize: Bool = false) -> EditDocument {
        var document = EditDocument.legacy(for: project)
        document.audio.tracks[micKey] = TrackGain(gain: 1, muted: false, cleanup: cleanup)
        document.audio.normalize = normalize
        return document
    }

    /// The clean file of the microphone's segment `index`.
    func cleanFile(_ index: Int) throws -> URL {
        let segment = try #require(micSegments.first { $0.index == index })
        let identity = try #require(SegmentIdentity.of(segment, in: project.package))
        return try #require(caches.analysisFile(.clean, take: takeID, track: micID, segment: identity, algorithm: "soundIsolation-2", extension: "caf"))
    }

    /// The loudness file of the microphone's segment `index`.
    func loudnessFile(_ index: Int) throws -> URL {
        let segment = try #require(micSegments.first { $0.index == index })
        let identity = try #require(SegmentIdentity.of(segment, in: project.package))
        return try #require(caches.analysisFile(.loudness, take: takeID, track: micID, segment: identity, algorithm: "loudness-1", extension: "json"))
    }
}

/// Runs every job `voice` says `document` needs, in order, through `jobs`; what they were.
@discardableResult
private func runNeeded(_ voice: VoiceJobs, _ document: EditDocument, on jobs: ProjectJobs) async throws -> [AnalysisJobKind] {
    let kinds = voice.needed(for: document)
    for kind in kinds { _ = try await jobs.result(of: kind, work: try #require(voice.work(for: kind))) }
    return kinds
}

/// `"<bytes>-<modification ns>"` of `url`, by `lstat`: what a loudness measure names its clean file by.
private func fileIdentity(_ url: URL) throws -> String {
    var info = stat()
    let status = lstat(url.path, &info)
    try #require(status == 0)
    return "\(info.st_size)-\(Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))"
}

private func readMeasure(_ url: URL) throws -> SegmentLoudness {
    try ProjectJSON.decoder().decode(SegmentLoudness.self, from: try Data(contentsOf: url))
}

/// A legacy document needs nothing; a cleanup needs each segment of the microphone cleaned, Normalize each audio
/// track measured; once they are written, nothing; without the isolation, no cleaning.
@Test func neededJobsFollowTheDocument() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let voice = fixture.voiceJobs()
        let legacy = EditDocument.legacy(for: fixture.project)
        #expect(voice.needed(for: legacy) == [])
        #expect(voice.needed(for: fixture.document(cleanup: 0.6)) == [clean(1), clean(2)])
        #expect(voice.needed(for: fixture.document(normalize: true)) == [micLoudness, systemLoudness])
        let both = fixture.document(cleanup: 0.6, normalize: true)
        #expect(voice.needed(for: both) == [clean(1), clean(2), micLoudness, systemLoudness])

        // One pass in that order is enough: the loudness is measured after the cleaning, with it. Every job of a track
        // reads where it is heard from one load of it.
        try await runNeeded(voice, both, on: ProjectJobs())
        #expect(voice.needed(for: both) == [])
        #expect(voice.trackAudio.loads == 2)
        #expect(voice.needed(for: fixture.document(cleanup: 1)) == [])
        #expect(voice.needed(for: legacy) == [])

        let unavailable = fixture.voiceJobs(
            FakeIsolation(isAvailable: false), caches: ProjectCaches(root: dir.appending(path: "Other"), projectID: "other"))
        #expect(unavailable.needed(for: fixture.document(cleanup: 0.6)) == [])
        #expect(unavailable.needed(for: both) == [micLoudness, systemLoudness])
    }
}

/// A cleanup job writes the segment's clean voice to its cache once, exactly the frames it is heard over; asked
/// again, it finds it.
@Test func cleanupJobWritesTheCacheOnce() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let isolation = FakeIsolation()
        let voice = fixture.voiceJobs(isolation)
        let jobs = ProjectJobs()
        let expected = try fixture.cleanFile(1)
        #expect(expected.path.hasSuffix("/clean/take-001/mic/\(expected.lastPathComponent)"))
        #expect(expected.lastPathComponent.hasPrefix("seg-0001-") && expected.lastPathComponent.hasSuffix("-soundIsolation-2.caf"))

        let output = try await jobs.result(of: clean(1), work: try #require(voice.work(for: clean(1))))
        guard case .cached(let url) = output else { Issue.record("\(output)"); return }
        #expect(url.path == expected.path)
        #expect(voice.needed(for: fixture.document(cleanup: 0.6)) == [clean(2)])

        let audio = try await TrackAudio.load(fixture.project, track: micID)
        let span = try #require(audio.spans.first)
        let dry = try await monoFrames(of: audio, span.frames)
        let written = try readCleanFile(expected)
        #expect(written.count == span.frames.count && written == dry.map { -$0 })

        let again = try await jobs.result(of: clean(1), work: try #require(voice.work(for: clean(1))))
        guard case .cached(let second) = again else { Issue.record("\(again)"); return }
        #expect(second.path == expected.path)
        #expect(isolation.calls == [span.segment])
        // Only the hidden temporary's name changes: nothing is left of it.
        let names = try FileManager.default.contentsOfDirectory(atPath: expected.deletingLastPathComponent().path)
        #expect(names == [expected.lastPathComponent])
    }
}

/// A cache macOS emptied is asked for again, and so is a clean file of another length than its segment's span: by
/// this queue's `needed`, and by a new one's export.
@Test func missingCacheIsNeededAgain() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let isolation = FakeIsolation()
        let voice = fixture.voiceJobs(isolation)
        let jobs = ProjectJobs()
        let document = fixture.document(cleanup: 0.6)
        try await runNeeded(voice, document, on: jobs)
        #expect(voice.needed(for: document) == [])

        try FileManager.default.removeItem(at: fixture.caches.directory)
        #expect(voice.needed(for: document) == [clean(1), clean(2)])
        try await runNeeded(voice, document, on: jobs)
        #expect(voice.needed(for: document) == [] && isolation.calls.count == 4)

        let second = try fixture.cleanFile(2)
        let samples = try readCleanFile(second)
        try writeCleanFile(Array(samples.dropLast(480)), to: second)
        #expect(voice.needed(for: document) == [clean(2)])
        #expect(voice.applied(to: .none, document: document).cleanVoice.isEmpty)

        // The editor opened again: its export finds it as well, and waits for it.
        let fresh = fixture.voiceJobs(isolation)
        let prepared = try await fresh.prepareExport(document, onto: .none, jobs: ProjectJobs()) { _ in }
        #expect(isolation.calls.count == 5)
        #expect(try readCleanFile(second) == samples)
        #expect(prepared.inputs.cleanVoice[micKey]?.files.count == 2 && !prepared.cleanupSkipped)
    }
}

/// A loudness measure whose clean file is not the one there now is measured again.
@Test func loudnessIsMeasuredAgainWhenTheCleanFileChanged() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let voice = fixture.voiceJobs()
        let jobs = ProjectJobs()
        let document = fixture.document(cleanup: 0.6, normalize: true)
        try await runNeeded(voice, document, on: jobs)
        #expect(voice.needed(for: document) == [])

        let json = try fixture.loudnessFile(1)
        var measure = try readMeasure(json)
        #expect(measure.algorithm == "loudness-1" && measure.channels == 1)
        #expect(measure.clean == (try fileIdentity(try fixture.cleanFile(1))))
        #expect(measure.wet?.count == measure.dry.count && measure.cross?.count == measure.dry.count && !measure.dry.isEmpty)
        measure.clean = "1-2"
        #expect(ProjectCaches.writeAnalysis(try ProjectJSON.encoder().encode(measure), to: json))
        #expect(voice.needed(for: document) == [micLoudness])
        // Without a cleanup, what it measured of the dry sound is enough.
        #expect(voice.needed(for: fixture.document(normalize: true)) == [])
        try await runNeeded(voice, document, on: jobs)
        #expect(voice.needed(for: document) == [])
        #expect(try readMeasure(json).clean == (try fileIdentity(try fixture.cleanFile(1))))

        // The clean file written again (another date) asks for it as well.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: try fixture.cleanFile(2).path)
        #expect(voice.needed(for: document) == [micLoudness])
        #expect(voice.applied(to: .none, document: document).loudness[micKey]?.wet == nil)
    }
}

/// What the mix reads is only what is whole: a track's clean voice once every segment has it, its loudness once every
/// segment is measured (with the clean voice's blocks only when they are of the files mixed).
@Test func appliedListsOnlyCompleteTracks() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let voice = fixture.voiceJobs()
        let jobs = ProjectJobs()
        let document = fixture.document(cleanup: 0.6, normalize: true)
        var stale = AnalysisInputs()
        stale.cleanVoice["take-009/mic"] = CleanVoice(files: [:])
        stale.loudness["take-009/mic"] = TrackLoudness(channels: 1, dry: [1], wet: nil, cross: nil)

        _ = try await jobs.result(of: clean(1), work: try #require(voice.work(for: clean(1))))
        var applied = voice.applied(to: stale, document: document)
        #expect(applied.cleanVoice.isEmpty && applied.loudness.isEmpty)

        _ = try await jobs.result(of: clean(2), work: try #require(voice.work(for: clean(2))))
        applied = voice.applied(to: stale, document: document)
        let files = try #require(applied.cleanVoice[micKey]).files
        let segments = fixture.micSegments
        #expect(files.mapValues(\.path) == [segments[0].file: try fixture.cleanFile(1).path, segments[1].file: try fixture.cleanFile(2).path])
        #expect(applied.cleanVoice.count == 1 && applied.loudness.isEmpty)
        #expect(voice.applied(to: stale, document: fixture.document(normalize: true)).cleanVoice.isEmpty)

        _ = try await jobs.result(of: micLoudness, work: try #require(voice.work(for: micLoudness)))
        applied = voice.applied(to: stale, document: document)
        let mic = try #require(applied.loudness[micKey])
        let first = try readMeasure(try fixture.loudnessFile(1)), second = try readMeasure(try fixture.loudnessFile(2))
        #expect(mic == TrackLoudness(
            channels: 1, dry: first.dry + second.dry, wet: (first.wet ?? []) + (second.wet ?? []),
            cross: (first.cross ?? []) + (second.cross ?? [])))
        #expect(applied.loudness[systemKey] == nil)
        // Mixed dry, the track has the dry sound's blocks only; without Normalize, none.
        #expect(voice.applied(to: .none, document: fixture.document(normalize: true)).loudness[micKey]?.wet == nil)
        #expect(voice.applied(to: .none, document: fixture.document(cleanup: 0.6)).loudness.isEmpty)

        _ = try await jobs.result(of: systemLoudness, work: try #require(voice.work(for: systemLoudness)))
        applied = voice.applied(to: stale, document: document)
        #expect(applied.loudness.count == 2 && applied.loudness[systemKey]?.wet == nil)
    }
}

/// The transcription job of a take gives the words of its first microphone; without an engine (macOS 15) or the
/// language's model, it is unavailable; a take with no audio has none.
@Test func transcriptionJobGivesTheTranscript() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let jobs = ProjectJobs()
        let (kind, work) = try #require(fixture.voiceJobs().transcription(language: "es-MX"))
        #expect(kind == .transcription(take: takeID, track: micID))
        let output = try await jobs.result(of: kind, work: work)
        guard case .transcript(let transcript) = output else { Issue.record("\(output)"); return }
        #expect(transcript.language == "es-MX" && transcript.engine == "speechTranscriber-1")
        let words = try #require(transcript.takes.first)
        #expect(transcript.takes.count == 1 && words.take == takeID && words.track == micID)
        #expect(words.words.map(\.text) == ["palabra0", "palabra1"])
        let starts = fixture.micSegments.map(\.startHostTime)
        for (word, start) in zip(words.words, starts) { #expect(abs(word.start.seconds(since: start) - 0.1) < 0.001) }
        #expect(await jobs.state(of: kind) == .done)

        let (none, nothing) = try #require(fixture.voiceJobs(engine: nil).transcription(language: "es-MX"))
        await #expect(throws: JobError(.needsMacOS26, unavailable: true)) { try await jobs.result(of: none, work: nothing) }
        #expect(await jobs.state(of: none) == .unavailable(.needsMacOS26))

        let (missing, notInstalled) = try #require(fixture.voiceJobs(engine: NotInstalledEngine()).transcription(language: "es-MX"))
        await #expect(throws: JobError(.modelNotInstalled(locale: "es-MX"), unavailable: true)) {
            try await jobs.result(of: missing, work: notInstalled)
        }

        let silentDir = dir.appending(path: "silent", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: silentDir, withIntermediateDirectories: true)
        let silent = try await VoiceFixture(in: silentDir, audio: false)
        #expect(silent.voiceJobs().transcription(language: "es-MX")?.0 == nil)
    }
}

/// The export waits for what its document needs, each job once, with its progress rising to 1; with everything there,
/// nothing runs. The loudness it waits for is that of the clean voice, measured after the cleaning.
@Test func prepareExportWaitsAndReportsProgress() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let isolation = FakeIsolation()
        let voice = fixture.voiceJobs(isolation)
        let jobs = ProjectJobs()
        let values = Mutex<[Double]>([])
        func prepare(_ document: EditDocument) async throws -> (inputs: AnalysisInputs, cleanupSkipped: Bool) {
            values.withLock { $0 = [] }
            let prepared = try await voice.prepareExport(document, onto: .none, jobs: jobs) { value in values.withLock { $0.append(value) } }
            let reported = values.withLock { $0 }
            #expect(reported.last == 1 && zip(reported, reported.dropFirst()).allSatisfy { $0 <= $1 } && reported.allSatisfy { (0...1).contains($0) })
            return prepared
        }

        // Normalize alone: the dry sound of each track is measured.
        let normalized = try await prepare(fixture.document(normalize: true))
        #expect(isolation.calls.isEmpty && !normalized.cleanupSkipped)
        #expect(normalized.inputs.loudness.count == 2 && normalized.inputs.loudness[micKey]?.wet == nil && normalized.inputs.cleanVoice.isEmpty)

        // Then the cleanup: two segments cleaned once each, and the microphone measured again with them.
        let document = fixture.document(cleanup: 0.6, normalize: true)
        #expect(voice.needed(for: document) == [clean(1), clean(2)])
        let prepared = try await prepare(document)
        #expect(isolation.calls == fixture.micSegments.map(\.file) && !prepared.cleanupSkipped)
        #expect(prepared.inputs.cleanVoice[micKey]?.files.count == 2)
        #expect(prepared.inputs.loudness[micKey]?.wet != nil && prepared.inputs.loudness[systemKey] != nil)
        #expect(prepared.inputs == voice.applied(to: .none, document: document))
        #expect(await jobs.state(of: clean(1)) == .done)
        #expect(await jobs.state(of: micLoudness) == .done)

        // Everything there: nothing runs, the progress goes straight to 1.
        let again = try await prepare(document)
        #expect(isolation.calls.count == 2 && again.inputs == prepared.inputs)
        #expect(values.withLock { $0 } == [1])
    }
}

/// Without the system's voice isolation, the export of a cleaned track goes dry and says so; without a cleanup, it says
/// nothing.
@Test func noIsolationExportsDryAndSaysSo() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let isolation = FakeIsolation(isAvailable: false)
        let voice = fixture.voiceJobs(isolation)
        let jobs = ProjectJobs()
        let cleaned = try await voice.prepareExport(fixture.document(cleanup: 0.6), onto: .none, jobs: jobs) { _ in }
        #expect(cleaned.cleanupSkipped && cleaned.inputs.cleanVoice.isEmpty && isolation.calls.isEmpty)

        let normalized = try await voice.prepareExport(fixture.document(cleanup: 0.6, normalize: true), onto: .none, jobs: jobs) { _ in }
        #expect(normalized.cleanupSkipped && normalized.inputs.cleanVoice.isEmpty)
        #expect(normalized.inputs.loudness[micKey]?.wet == nil && normalized.inputs.loudness[micKey] != nil)

        let legacy = try await voice.prepareExport(.legacy(for: fixture.project), onto: .none, jobs: jobs) { _ in }
        #expect(!legacy.cleanupSkipped && legacy.inputs == .none)
        // The work of a cleanup that is asked for anyway says why it cannot.
        await #expect(throws: JobError(.notOnThisMac, unavailable: true)) {
            try await jobs.result(of: clean(1), work: try #require(voice.work(for: clean(1))))
        }
    }
}

/// A cleanup cancelled while it writes leaves neither its cache file nor its temporary.
@Test func aCancelledJobLeavesNoCacheFile() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let gate = Gate()
        let voice = fixture.voiceJobs(FakeIsolation(gate: gate))
        let jobs = ProjectJobs()
        let folder = try fixture.cleanFile(1).deletingLastPathComponent()
        await jobs.enqueue(clean(1), work: try #require(voice.work(for: clean(1))))
        #expect(await eventually(timeout: patience) { gate.arrivals == 1 })
        // Written whole in its hidden temporary, never at its name yet.
        let writing = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(writing.count == 1 && writing.allSatisfy { $0.hasPrefix(".") && $0.hasSuffix(".tmp.caf") })

        await jobs.cancel(clean(1))
        #expect(await eventually(timeout: patience) { await !jobs.isRunning })
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [])
        #expect(await jobs.state(of: clean(1)) == nil)
        #expect(voice.needed(for: fixture.document(cleanup: 0.6)) == [clean(1), clean(2)])
    }
}

/// Callers asking for a track's audio while it loads share one load; one that is cancelled stops it only when it is
/// the last one waiting, and the next caller loads it again, as it does once a segment is another file.
@Test func aTrackIsLoadedOnceForEveryJob() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let track = try #require(fixture.project.take.track(micID))
        let audio = try await TrackAudio.load(fixture.project, track: micID)
        let gate = Gate()
        let shared = SharedTrackAudio(project: fixture.project) { _, _ in
            try await gate.wait()
            return audio
        }
        let first = Task { try await shared.audio(of: track) }
        #expect(await eventually(timeout: patience) { gate.arrivals == 1 })
        let second = Task { try await shared.audio(of: track) }
        #expect(await eventually(timeout: patience) { shared.waiters(of: track) == 2 })
        // The first one cancelled: the second still waits, so the load goes on, and both get it.
        first.cancel()
        #expect(await eventually(timeout: patience) { shared.waiters(of: track) == 1 })
        gate.open()
        #expect(try await first.value.audio === audio)
        #expect(try await second.value.audio === audio)
        #expect(try await shared.audio(of: track).audio === audio)
        #expect(shared.loads == 1 && gate.arrivals == 1)

        // A segment written again: loaded again.
        let segment = try #require(track.segments.first)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: fixture.project.package.fileURL(segment.file).path)
        _ = try await shared.audio(of: track)
        #expect(shared.loads == 2)

        // The last one waiting cancelled: the load stops with it, and is made again for the next.
        let closed = Gate()
        let other = SharedTrackAudio(project: fixture.project) { _, _ in
            try await closed.wait()
            return audio
        }
        let alone = Task { try await other.audio(of: track) }
        #expect(await eventually(timeout: patience) { closed.arrivals == 1 })
        alone.cancel()
        await #expect(throws: CancellationError.self) { try await alone.value }
        #expect(other.waiters(of: track) == 0)
        let next = Task { try await other.audio(of: track) }
        #expect(await eventually(timeout: patience) { closed.arrivals == 2 })
        closed.open()
        #expect(try await next.value.audio === audio)
        #expect(other.loads == 2)
    }
}

/// Cleaning, measuring and transcribing write nothing in the package.
@Test func cachesNeverWriteInThePackage() async throws {
    try await withTemporaryDirectory { dir in
        let fixture = try await VoiceFixture(in: dir)
        let before = try treeHash(fixture.project.package.url)
        let voice = fixture.voiceJobs()
        let jobs = ProjectJobs()
        let prepared = try await voice.prepareExport(fixture.document(cleanup: 1, normalize: true), onto: .none, jobs: jobs) { _ in }
        #expect(prepared.inputs.cleanVoice.count == 1 && prepared.inputs.loudness.count == 2)
        let (kind, work) = try #require(voice.transcription(language: "es-MX"))
        _ = try await jobs.result(of: kind, work: work)
        #expect(try treeHash(fixture.project.package.url) == before)
        #expect(FileManager.default.fileExists(atPath: fixture.caches.folder(.clean).path))
    }
}

/// Why a work failed, as the queue keeps it.
@Test func jobErrorSaysWhy() {
    #expect(VoiceJobs.jobError(TranscriptionError.needsMacOS26) == JobError(.needsMacOS26, unavailable: true))
    #expect(VoiceJobs.jobError(TranscriptionError.notOnThisMac) == JobError(.notOnThisMac, unavailable: true))
    #expect(VoiceJobs.jobError(TranscriptionError.modelNotInstalled("es-MX")) == JobError(.modelNotInstalled(locale: "es-MX"), unavailable: true))
    #expect(VoiceJobs.jobError(TranscriptionError.engine("no")) == JobError(.failed("no")))
    #expect(VoiceJobs.jobError(SoundIsolationError.unavailable) == JobError(.notOnThisMac, unavailable: true))
    #expect(VoiceJobs.jobError(SoundIsolationError.renderingFailed("status 3")) == JobError(.failed("status 3")))
    #expect(VoiceJobs.jobError(POSIXError(.ENOSPC)) == JobError(.noSpace))
    #expect(VoiceJobs.jobError(CocoaError(.fileWriteOutOfSpace)) == JobError(.noSpace))
    let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
    #expect(VoiceJobs.jobError(wrapped) == JobError(.noSpace))
    #expect(VoiceJobs.jobError(JobError(.sourceUnreadable(file: "takes/take-001/mic/seg-0001.mov"))) == JobError(.sourceUnreadable(file: "takes/take-001/mic/seg-0001.mov")))
    #expect(VoiceJobs.jobError(TranscriptionError.noAudio).problem != .noSpace)
}
