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
// @testable for the library of test themes (`MusicLibrary.init(root:themes:score:synthesize:scratch:)`), what it counts,
// and `MusicAnalysis`'s own test seams: the decoding and the voice it calls, and who waits for a piece of work.
@testable import ProjectJobs

// Every test here runs in `make tsan` (`ProjectJobsTests` and `MusicAnalysisTests` in its filter). The themes are a short
// score (a loop of 1 s, no reverb), so a synthesis takes a moment even in a debug build under the thread sanitizer.

private let base = HostTime(nanoseconds: 9_000_000_000_000)
private let takeID = "take-001"
private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// A loop of one bar of 2/4 at 120 BPM (1 s): a pad and a pluck.
private let testTheme = MusicScore(
    id: "calm", tempo: 120, beatsPerBar: 2, bars: 1, seed: 11,
    parts: [
        ScorePart(instrument: .pad(.soft), notes: [ScoreNote(beat: 0, beats: 2, pitch: 60, velocity: 0.6)], gain: 0.5),
        ScorePart(instrument: .pluck(.harp), notes: [ScoreNote(beat: 0.5, beats: 0.5, pitch: 72, velocity: 0.7)], gain: 0.5),
    ],
    reverb: .none, delay: nil, masterGain: 0.8, isPlaceholder: false)
private let calm = MusicThemes.source("calm")

/// Long enough for a loaded machine under the thread sanitizer: `eventually` returns as soon as it holds.
private let patience = Duration.seconds(60)

/// Where a piece of work waits until the test opens it, or until its task is cancelled; it says when one arrived.
private final class Gate: Sendable {
    private let state = Mutex((open: false, arrivals: 0))

    var arrivals: Int { state.withLock { $0.arrivals } }
    func open() { state.withLock { $0.open = true } }

    /// An async wait: `CancellationError` once its task is cancelled.
    func wait() async throws {
        state.withLock { $0.arrivals += 1 }
        while !state.withLock({ $0.open }) { try await Task.sleep(for: .milliseconds(2)) }
    }

    /// A synthesis of the library that waits (blocking its queue) until the gate opens, then renders; `nil` once it is
    /// told to stop.
    func synthesize(_ score: MusicScore, _ isCancelled: () -> Bool) -> [Float]? {
        state.withLock { $0.arrivals += 1 }
        while !state.withLock({ $0.open }) {
            if isCancelled() { return nil }
            usleep(1_000)
        }
        return MusicSynth.render(score, until: isCancelled)
    }
}

/// How many times the decoding and the voice search were called, and with what.
private final class Calls: Sendable {
    private let state = Mutex((decodes: [String](), voices: [String]()))
    var decodes: [String] { state.withLock { $0.decodes } }
    var voices: [String] { state.withLock { $0.voices } }
    func decoded(_ url: URL) { state.withLock { $0.decodes.append(url.lastPathComponent) } }
    func searched(_ key: String) { state.withLock { $0.voices.append(key) } }
}

/// Every name under `folder`, hidden ones included, as paths relative to it; none if it is not there.
private func tree(_ folder: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else { return [] }
    return (enumerator.allObjects as? [String] ?? []).sorted()
}

/// `seconds` of a 440 Hz sine at `url`: AAC in an `.m4a` (44.1 kHz, mono), 16-bit PCM otherwise.
private func writeSound(at url: URL, seconds: Double, sampleRate: Double = 44_100) throws {
    var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]
    if url.pathExtension == "m4a" {
        settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
    } else {
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = false
    }
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = Int((seconds * sampleRate).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples = try #require(buffer.floatChannelData?[0])
    for n in 0..<frames { samples[n] = 0.25 * Float(sin(2 * Double.pi * 440 * Double(n) / sampleRate)) }
    try file.write(from: buffer)
}

/// A project, its caches, a music library of the test theme `calm`, and the analysis of its music made from them, with
/// the decoding and the voice search counted (and, with gates, held).
private struct Fixture {
    let project: LoadedProject
    let caches: ProjectCaches
    let libraryRoot: URL
    let library: MusicLibrary
    let calls = Calls()

    /// A take of 4 s of a display, a microphone `mic` of two segments (0.5–2 s, 3–3.5 s), the sound of an iPhone
    /// `device-audio` (1–1.5 s) and system audio (0–4 s); or `project`, if given.
    init(in dir: URL, project: LoadedProject? = nil, synthesize: (@Sendable (MusicScore, () -> Bool) -> [Float]?)? = nil) async throws {
        if let project {
            self.project = project
        } else {
            let builder = try TakeBuilder(in: dir, name: "Music", formatVersion: 4)
            try await builder.addVideoTrack(
                id: "display-1",
                source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 320, height: 180), pixelScale: 1),
                segments: [VideoSegmentSpec(start: base, seconds: 4, framesPerSecond: 10, width: 320, height: 180)])
            try await builder.addAudioTrack(
                id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
                segments: [AudioSegmentSpec(start: at(0.5), seconds: 1.5), AudioSegmentSpec(start: at(3), seconds: 0.5, frequency: 660)])
            try await builder.addAudioTrack(
                id: "device-audio", kind: .deviceAudio, source: TrackSource(name: "Synthetic iPhone", deviceUniqueID: "synthetic-phone"),
                segments: [AudioSegmentSpec(start: at(1), seconds: 0.5, frequency: 330)])
            try await builder.addAudioTrack(
                id: "system-audio", kind: .systemAudio, source: TrackSource(name: "System Audio", excludedBundleIDs: []),
                segments: [AudioSegmentSpec(start: base, seconds: 4, frequency: 220)])
            self.project = try builder.write()
        }
        caches = ProjectCaches(root: dir.appending(path: "Caches", directoryHint: .isDirectory), projectID: self.project.manifest.resolvedProjectID)
        libraryRoot = dir.appending(path: "Music", directoryHint: .isDirectory)
        let score: @Sendable (String) -> MusicScore? = { $0 == "calm" ? testTheme : nil }
        if let synthesize {
            library = MusicLibrary(root: libraryRoot, themes: ["calm"], score: score, synthesize: synthesize)
        } else {
            library = MusicLibrary(root: libraryRoot, themes: ["calm"], score: score)
        }
    }

    /// The analysis, with the decoding and the voice search counted and, with a gate, held (after the decoding wrote
    /// its file; after the voice was found).
    func analysis(gate: Gate? = nil, themeMade: @escaping @Sendable (String) -> Void = { _ in }) -> MusicAnalysis {
        let calls = calls
        return MusicAnalysis(
            project: project, caches: caches, library: library,
            decode: { source, destination, progress in
                calls.decoded(source)
                try await ImportedAudio.decode(source, to: destination, progress: progress)
                try await gate?.wait()
            },
            findVoice: { project, track in
                calls.searched(AudioPlan.key(take: project.take.id, track: track.id))
                let voice = try await VoiceActivityFinder.voiced(try await TrackAudio.load(project, track: track.id))
                try await gate?.wait()
                return voice
            },
            themeMade: themeMade)
    }

    /// The legacy document with a piece of music for each of `sources`, one after the other, and the ducking as given.
    func document(_ sources: [String], ducking: Bool = true) -> EditDocument {
        var document = EditDocument.legacy(for: project)
        document.music = MusicPlan(
            items: sources.enumerated().map { k, source in
                MusicItem(
                    id: String(format: "mu-%08x", k + 1), source: source, start: Int64(k) * 1_000_000_000,
                    end: Int64(k + 1) * 1_000_000_000)
            },
            ducking: Ducking(enabled: ducking))
        return document
    }

    /// A sound of `seconds` (AAC, 44.1 kHz, mono) in the package's `assets/` as `<name>.m4a`, and its source.
    func addAsset(_ name: String, seconds: Double = 1.5) throws -> String {
        let assets = project.package.url.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try writeSound(at: assets.appending(path: "\(name).m4a"), seconds: seconds)
        return "assets/\(name).m4a"
    }

    /// Where the decoding of `source` goes.
    func decoded(_ source: String) -> URL {
        caches.folder(.music).appending(path: "\(URL(filePath: source).lastPathComponent)-importedAudio-1.caf")
    }

    /// Where the voice of `track` of `take` goes.
    func voiceFile(take: String = takeID, track: String) -> URL {
        caches.folder(.ducking).appending(path: "\(take)/\(track)-ducking-1.json")
    }

    /// The names of each segment of `track` of `take`, as the voice's file lists them.
    func segmentNames(take: String = takeID, track: String) throws -> [String] {
        let focused = try #require(project.focused(on: take))
        return try #require(focused.take.track(track)).segments.compactMap { SegmentIdentity.of($0, in: project.package)?.name }
    }
}

private let assetA = "0123456789abcdef0123456789abcdef"
private let assetB = "fedcba9876543210fedcba9876543210"

/// The voice's file, as written.
private struct VoiceFile: Decodable {
    var algorithm: String
    var segments: [String]
    var spans: [[UInt64]]
}

@Suite struct MusicAnalysisTests {
    /// A theme of the library is its file in the library; `needsVoice` is a piece of music with the ducking on.
    @Test func libraryThemesComeFromTheLibrary() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let analysis = fixture.analysis()
            let document = fixture.document([calm, MusicThemes.source("nope"), "library:music-2/calm"], ducking: false)
            let prepared = try await analysis.prepare(document) { _ in }
            #expect(prepared.musicFiles == [calm: fixture.library.url(for: "calm")])
            #expect(fixture.library.cachedFile(for: "calm") == fixture.library.url(for: "calm"))
            #expect(prepared.voiceActivity == [:])

            #expect(analysis.needsVoice(fixture.document([calm])))
            #expect(!analysis.needsVoice(fixture.document([calm], ducking: false)))
            #expect(!analysis.needsVoice(fixture.document([])))
        }
    }

    /// An `.m4a` of 44.1 kHz mono in `assets/` is decoded once into the project's cache, as our CAF of 48 kHz stereo;
    /// the next `prepare` finds it.
    @Test func importedAudioIsDecodedOnce() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let source = try fixture.addAsset(assetA, seconds: 1.5)
            let analysis = fixture.analysis()
            let document = fixture.document([source, source], ducking: false)
            let progress = Mutex<[Double]>([])
            let prepared = try await analysis.prepare(document) { fraction in progress.withLock { $0.append(fraction) } }
            let url = fixture.decoded(source)
            #expect(prepared.musicFiles == [source: url])
            #expect(url.lastPathComponent == "\(assetA).m4a-importedAudio-1.caf")
            let file = try MusicFile(contentsOf: url)
            #expect(abs(file.frames - 72_000) <= 1, "\(file.frames) frames")
            let read = try AVAudioFile(forReading: url)
            #expect(read.fileFormat.sampleRate == 48_000 && read.fileFormat.channelCount == 2 && read.length == Int64(file.frames))
            #expect(fixture.calls.decodes == ["\(assetA).m4a"])
            let fractions = progress.withLock { $0 }
            #expect(fractions.last == 1 && fractions == fractions.sorted())
            #expect(tree(fixture.caches.folder(.music)) == [url.lastPathComponent])

            let again = try await analysis.prepare(document) { _ in }
            #expect(again.musicFiles == prepared.musicFiles)
            #expect(fixture.calls.decodes.count == 1)
            // Another analysis of the project finds it too.
            #expect(try await fixture.analysis().prepare(document) { _ in }.musicFiles == prepared.musicFiles)
            #expect(fixture.calls.decodes.count == 1)
        }
    }

    /// With two takes, the voice of each one's microphone is found once and written to its own file; asked again, no
    /// audio is read.
    @Test func voiceIsFoundOncePerTakeAndTrack() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let fixture = try await Fixture(in: dir, project: project)
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2), ("take-001", 2, 4)])
            document.music = fixture.document([calm]).music
            let analysis = fixture.analysis()
            let prepared = try await analysis.prepare(document) { _ in }
            #expect(Set(prepared.voiceActivity.keys) == ["take-001/mic", "take-002/mic"])
            #expect(fixture.calls.voices.sorted() == ["take-001/mic", "take-002/mic"])
            #expect(tree(fixture.caches.folder(.ducking)) == [
                "take-001", "take-001/mic-ducking-1.json", "take-002", "take-002/mic-ducking-1.json",
            ])
            for take in ["take-001", "take-002"] {
                let written = try JSONDecoder().decode(VoiceFile.self, from: Data(contentsOf: fixture.voiceFile(take: take, track: "mic")))
                #expect(written.algorithm == "ducking-1")
                #expect(written.segments == (try fixture.segmentNames(take: take, track: "mic")))
                let voice = try #require(prepared.voiceActivity["\(take)/mic"])
                #expect(written.spans == voice.spans.map { [$0.lowerBound.nanoseconds, $0.upperBound.nanoseconds] })
                // The sine is heard the whole take.
                let take = try #require(project.focused(on: take)).take
                let segment = try #require(take.track("mic")?.segments.first)
                #expect(voice.spans.count == 1)
                #expect(abs(voice.spans[0].lowerBound.seconds(since: segment.startHostTime)) < 0.06)
            }

            let again = try await analysis.prepare(document) { _ in }
            #expect(again.voiceActivity == prepared.voiceActivity)
            #expect(fixture.calls.voices.count == 2)
            #expect(await analysis.cached(for: document).voiceActivity == prepared.voiceActivity)
        }
    }

    /// The voice of a microphone and of an iPhone's sound, never of the system audio; a segment written again (another
    /// date) is looked at again, the other track's voice is not.
    @Test func aRewrittenSegmentIsFoundAgain() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let analysis = fixture.analysis()
            let document = fixture.document([calm])
            let first = try await analysis.prepare(document) { _ in }
            #expect(Set(first.voiceActivity.keys) == ["\(takeID)/mic", "\(takeID)/device-audio"])
            let mic = try #require(first.voiceActivity["\(takeID)/mic"])
            #expect(mic.spans.count == 2)
            #expect(fixture.calls.voices.count == 2)

            let segment = try #require(fixture.project.take.track("mic")?.segments.first)
            let before = try fixture.segmentNames(track: "mic")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.5)], ofItemAtPath: fixture.project.package.fileURL(segment.file).path)
            let after = try fixture.segmentNames(track: "mic")
            #expect(before != after)
            #expect(await analysis.cached(for: document).voiceActivity.keys.sorted() == ["\(takeID)/device-audio"])

            let second = try await analysis.prepare(document) { _ in }
            #expect(fixture.calls.voices.sorted() == ["\(takeID)/device-audio", "\(takeID)/mic", "\(takeID)/mic"])
            #expect(second.voiceActivity == first.voiceActivity)
            let written = try JSONDecoder().decode(VoiceFile.self, from: Data(contentsOf: fixture.voiceFile(track: "mic")))
            #expect(written.segments == after)
        }
    }

    /// Without music, or with the ducking off, no voice is looked for and nothing is written for it.
    @Test func withoutMusicOrDuckingNoVoiceIsFound() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let analysis = fixture.analysis()
            let none = try await analysis.prepare(fixture.document([])) { _ in }
            #expect(none.musicFiles == [:] && none.voiceActivity == [:])
            let off = try await analysis.prepare(fixture.document([calm], ducking: false)) { _ in }
            #expect(off.musicFiles.keys.sorted() == [calm])
            #expect(off.voiceActivity == [:])
            #expect(fixture.calls.voices == [])
            #expect(tree(fixture.caches.directory) == [])
        }
    }

    /// `cached` makes nothing: before `prepare` it finds nothing (and writes nothing); after, what `prepare` gave.
    @Test func cachedReadsWhatIsThereWithoutMaking() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let source = try fixture.addAsset(assetA)
            let analysis = fixture.analysis()
            let document = fixture.document([calm, source])
            let before = await analysis.cached(for: document)
            #expect(before.musicFiles == [:] && before.voiceActivity == [:])
            #expect(tree(fixture.caches.directory) == [] && tree(fixture.libraryRoot) == [])
            #expect(fixture.calls.decodes == [] && fixture.calls.voices == [])

            let prepared = try await analysis.prepare(document) { _ in }
            #expect(prepared.musicFiles.keys.sorted() == [source, calm].sorted())
            #expect(prepared.voiceActivity.keys.sorted() == ["\(takeID)/device-audio", "\(takeID)/mic"])
            let after = await analysis.cached(for: document)
            #expect(after.musicFiles == prepared.musicFiles && after.voiceActivity == prepared.voiceActivity)
            // Another analysis of the project reads the same from the disk.
            let other = await fixture.analysis().cached(for: document)
            #expect(other.musicFiles == prepared.musicFiles && other.voiceActivity == prepared.voiceActivity)
        }
    }

    /// A link in `assets/` (never followed) and a file there that is no audio are left out; the theme is there, and
    /// nothing is written for them.
    @Test func anUnreadableAssetLeavesTheOthers() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let outside = dir.appending(path: "outside.m4a")
            try writeSound(at: outside, seconds: 0.5)
            let assets = fixture.project.package.url.appending(path: "assets", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: assets.appending(path: "\(assetA).m4a"), withDestinationURL: outside)
            try Data(repeating: 7, count: 2_048).write(to: assets.appending(path: "\(assetB).m4a"))
            let link = "assets/\(assetA).m4a", garbage = "assets/\(assetB).m4a"

            let analysis = fixture.analysis()
            let prepared = try await analysis.prepare(fixture.document([link, calm, garbage], ducking: false)) { _ in }
            #expect(prepared.musicFiles == [calm: fixture.library.url(for: "calm")])
            #expect(fixture.calls.decodes == ["\(assetB).m4a"])
            #expect(tree(fixture.caches.folder(.music)) == [])
        }
    }

    /// A theme the library's cache lost (macOS emptied it) is not in `cached`; `prepare` makes it again, and waits.
    @Test func exportWaitsForAThemeTheCacheLost() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let analysis = fixture.analysis()
            let document = fixture.document([calm], ducking: false)
            let url = try #require(try await analysis.prepare(document) { _ in }.musicFiles[calm])
            try FileManager.default.removeItem(at: fixture.libraryRoot)
            #expect(await analysis.cached(for: document).musicFiles == [:])
            #expect(try await analysis.prepare(document) { _ in }.musicFiles == [calm: url])
            #expect(fixture.library.cachedFile(for: "calm") == url)
            #expect(await fixture.library.syntheses == 2)
        }
    }

    /// A theme lost between the library's making it and `prepare` checking it (macOS emptying the cache right then) is
    /// asked for again, once: `prepare` gives it there.
    @Test func aThemeLostRightAfterItIsMadeIsAskedForAgain() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let lost = Mutex(false)
            let library = fixture.library
            let analysis = fixture.analysis(themeMade: { id in
                let first = lost.withLock { lost in
                    defer { lost = true }
                    return !lost
                }
                if first { unlink(library.url(for: id).path) }
            })
            let prepared = try await analysis.prepare(fixture.document([calm], ducking: false)) { _ in }
            #expect(prepared.musicFiles == [calm: library.url(for: "calm")])
            #expect(library.cachedFile(for: "calm") != nil)
            #expect(await library.syntheses == 2)
        }
    }

    /// Two callers of the same document share one decoding and one search of each voice; one of them cancelled leaves
    /// the other its result.
    @Test func callersShareOnePieceOfWork() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let source = try fixture.addAsset(assetA)
            let gate = Gate()
            let analysis = fixture.analysis(gate: gate)
            let document = fixture.document([source])
            let first = Task { try await analysis.prepare(document) { _ in } }
            let second = Task { try await analysis.prepare(document) { _ in } }
            let third = Task { try await analysis.prepare(document) { _ in } }
            let decodedFile = fixture.decoded(source), micFile = fixture.voiceFile(track: "mic")
            #expect(await eventually(timeout: patience) {
                let decoding = await analysis.waiters(for: decodedFile), voice = await analysis.waiters(for: micFile)
                return decoding == 3 && voice == 3
            })
            third.cancel()
            await #expect(throws: CancellationError.self) { try await third.value }
            #expect(await analysis.waiters(for: decodedFile) == 2)
            gate.open()
            let a = try await first.value, b = try await second.value
            #expect(a.musicFiles == [source: decodedFile] && b.musicFiles == a.musicFiles)
            #expect(a.voiceActivity.keys.sorted() == ["\(takeID)/device-audio", "\(takeID)/mic"] && b.voiceActivity == a.voiceActivity)
            #expect(fixture.calls.decodes.count == 1)
            #expect(fixture.calls.voices.count == 2)
            #expect(await analysis.waiters(for: decodedFile) == 0)
        }
    }

    /// Cancelled partway (a theme being made, an asset decoded, a voice found), `prepare` throws `CancellationError`
    /// and leaves no file: no theme, no CAF, no JSON, no temporary.
    @Test func cancellingLeavesNoFile() async throws {
        try await withTemporaryDirectory { dir in
            let gate = Gate()
            let fixture = try await Fixture(in: dir, synthesize: { gate.synthesize($0, $1) })
            let source = try fixture.addAsset(assetA)
            let analysis = fixture.analysis(gate: gate)
            let document = fixture.document([calm, source])
            let task = Task { try await analysis.prepare(document) { _ in } }
            // The theme, the decoding (its file written, not committed) and both voices, each held.
            #expect(await eventually(timeout: patience) { gate.arrivals == 4 })
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await eventually(timeout: patience) { await fixture.library.inFlight == 0 })
            #expect(tree(fixture.caches.folder(.music)) == [])
            #expect(tree(fixture.caches.folder(.ducking)).allSatisfy { !$0.hasSuffix(".json") && !$0.contains(".tmp") })
            #expect(tree(fixture.libraryRoot).allSatisfy { !$0.hasSuffix(".caf") })
            #expect(await analysis.cached(for: document).musicFiles == [:])
            #expect(await analysis.cached(for: document).voiceActivity == [:])
        }
    }

    /// The goal of "Preparing…" for a theme of the library (plan 3c decision 16, under 3 s): each of the six themes made
    /// from an empty cache, on the library's own queue (`.utility`), as the list and the export ask for it; and a dense
    /// stand-in for a composed theme (`denseTheme`), while the six are still placeholders.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func preparingAThemeIsUnderThreeSeconds() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let clock = ContinuousClock()
            var lines: [String] = []
            func measure(_ id: String, _ library: MusicLibrary, placeholder: Bool) async throws {
                let analysis = MusicAnalysis(project: fixture.project, caches: fixture.caches, library: library)
                let document = fixture.document([MusicThemes.source(id)], ducking: false)
                let start = clock.now
                let prepared = try await analysis.prepare(document) { _ in }
                let elapsed = clock.now - start
                #expect(prepared.musicFiles[MusicThemes.source(id)] != nil)
                lines.append("\(id)\(placeholder ? " (placeholder)" : ""): \(elapsed)")
                // The goal is the app's Release build: unoptimized, the engine is tens of times slower (docs/performance.md).
                #if !DEBUG
                #expect(elapsed < .seconds(3), "\(id): \(elapsed)")
                #endif
            }
            let library = MusicLibrary(root: dir.appending(path: "Bench", directoryHint: .isDirectory))
            for id in MusicThemes.ids {
                try await measure(id, library, placeholder: MusicThemes.score(id)?.isPlaceholder == true)
            }
            let dense = MusicLibrary(
                root: dir.appending(path: "Dense", directoryHint: .isDirectory), themes: ["calm"],
                score: { $0 == "calm" ? denseTheme : nil })
            try await measure("calm", dense, placeholder: false)
            lines[lines.count - 1] = "dense stand-in: " + lines[lines.count - 1].dropFirst("calm: ".count)
            print("MusicAnalysis bench, a theme from an empty cache:\n" + lines.joined(separator: "\n"))
        }
    }
}

/// A stand-in for a dense composed theme (a theme of 120 s of `Pulso`'s tempo with every part busy): 128 BPM, 64 bars of
/// 4/4; a pad chord each bar, a bass note each beat, a pluck and a lead each eighth, a kick each beat, a snare on 2 and 4,
/// a hat each eighth and a shaker each sixteenth, in a hall with a delay. Only for the bench of "Preparing…".
private let denseTheme: MusicScore = {
    let bars = 64, beats = bars * 4
    let scale: [Double] = [0, 2, 4, 5, 7, 9, 11, 12]
    func every(_ step: Double, beats length: Double, pitch: (Int) -> Double, velocity: Double = 0.7) -> [ScoreNote] {
        stride(from: 0.0, to: Double(beats), by: step).enumerated().map { k, beat in
            ScoreNote(beat: beat, beats: length, pitch: pitch(k), velocity: velocity)
        }
    }
    let chords = (0..<bars).flatMap { bar in
        [48.0, 52, 55].map { ScoreNote(beat: Double(bar * 4), beats: 4, pitch: $0 + scale[bar % 4], velocity: 0.6) }
    }
    return MusicScore(
        id: "calm", tempo: 128, beatsPerBar: 4, bars: bars, seed: 0xD0_5E,
        parts: [
            ScorePart(instrument: .pad(.warm), notes: chords, gain: 0.4, reverbSend: 0.35),
            ScorePart(instrument: .bass(.synth), notes: every(1, beats: 0.9) { 36 + scale[($0 / 4) % 4] }, gain: 0.5, reverbSend: 0),
            ScorePart(instrument: .pluck(.steel), notes: every(0.5, beats: 0.45) { 60 + scale[$0 % 8] }, gain: 0.3, delaySend: 0.3),
            ScorePart(instrument: .lead(.soft), notes: every(0.5, beats: 0.4) { 72 + scale[($0 * 3) % 8] }, gain: 0.2),
            ScorePart(instrument: .kick, notes: every(1, beats: 0.5) { _ in 36 }, gain: 0.6, reverbSend: 0),
            ScorePart(instrument: .snare, notes: every(2, beats: 0.5) { _ in 38 }.map { note in
                var note = note
                note.beat += 1
                return note
            }, gain: 0.4),
            ScorePart(instrument: .hat(open: false), notes: every(0.5, beats: 0.25) { _ in 42 }, gain: 0.25, reverbSend: 0.1),
            ScorePart(instrument: .shaker, notes: every(0.25, beats: 0.2) { _ in 70 }, gain: 0.15, reverbSend: 0.1),
        ],
        reverb: .hall, delay: DelaySettings(), masterGain: 0.5, isPlaceholder: false)
}()
