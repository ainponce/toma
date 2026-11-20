// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreVideo
import Editing
import Export
import Foundation
import ImageAnalysis
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
import Transcription
@testable import ProjectJobs

// Every test here runs in `make tsan`. None uses the Audio Unit, Speech or Vision: the clean voice is silence written by
// a fake isolation, the person and the face come from fake ones, and the music library's theme is a short test score.

private let base = HostTime(nanoseconds: 13_000_000_000_000)
private let calm = MusicThemes.source("calm")
/// Long enough for a loaded machine under the thread sanitizer: `eventually` returns as soon as it holds.
private let patience = Duration.seconds(60)

/// A loop of one bar of 2/4 at 120 BPM (1 s): a pad.
private let testTheme = MusicScore(
    id: "calm", tempo: 120, beatsPerBar: 2, bars: 1, seed: 7,
    parts: [ScorePart(instrument: .pad(.soft), notes: [ScoreNote(beat: 0, beats: 2, pitch: 60, velocity: 0.6)], gain: 0.5)],
    reverb: .none, delay: nil, masterGain: 0.8, isPlaceholder: false)

/// What ran, in order: `camera`, `voice` or `music` for each call of the fakes.
private final class Log: Sendable {
    private let entries = Mutex<[String]>([])

    var all: [String] { entries.withLock { $0 } }
    func add(_ entry: String) { entries.withLock { $0.append(entry) } }

    /// Where `entry` first is; `Int.max` if it never ran.
    func first(_ entry: String) -> Int { all.firstIndex(of: entry) ?? .max }
}

/// A project of 2 s of a display, a camera (0–1 s) and a microphone (0.2–1.8 s), its caches and a music library of the
/// test theme `calm`, and the document that needs all of it: the camera's background blurred and the face followed,
/// the microphone cleaned and the sound normalized, and `calm` under the voice from 0 to 1 s.
private struct Fixture {
    let project: LoadedProject
    let caches: ProjectCaches
    let library: MusicLibrary
    let document: EditDocument
    let log = Log()

    init(in dir: URL, synthesize: (@Sendable (MusicScore, () -> Bool) -> [Float]?)? = nil) async throws {
        let builder = try TakeBuilder(in: dir, name: "Prepared")
        try await builder.addVideoTrack(
            id: "display-1",
            source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 320, height: 180), pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 2, framesPerSecond: 10, width: 320, height: 180)])
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: TrackSource(name: "Camera"),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10, width: 320, height: 180)])
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
            segments: [AudioSegmentSpec(start: base.adding(seconds: 0.2), seconds: 1.6)])
        project = try builder.write()
        caches = ProjectCaches(root: dir.appending(path: "Caches", directoryHint: .isDirectory), projectID: project.manifest.resolvedProjectID)
        let log = log
        let render = synthesize ?? { MusicSynth.render($0, until: $1) }
        library = MusicLibrary(
            root: dir.appending(path: "Music", directoryHint: .isDirectory), themes: ["calm"],
            score: { $0 == "calm" ? testTheme : nil },
            synthesize: { score, stop in
                log.add("music")
                return render(score, stop)
            })
        var document = EditDocument.legacy(for: project)
        document.camera.show = true
        document.camera.background = .blurred
        document.camera.framing = CameraFraming(mode: .face, center: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.4)
        document.audio.tracks[AudioPlan.key(take: project.take.id, track: "mic")] = TrackGain(gain: 1, muted: false, cleanup: 0.6)
        document.audio.normalize = true
        document.music = MusicPlan(
            items: [MusicItem(id: "mu-00000001", source: calm, start: 0, end: 1_000_000_000)], ducking: Ducking(enabled: true))
        self.document = document
    }

    /// Workers of their own, whose fakes write to the log; the music's imported sounds decoded by `decode` if given.
    func workers(decode: MusicAnalysis.Decode? = nil) -> ExportWorkers {
        let music: MusicAnalysis
        if let decode {
            music = MusicAnalysis(
                project: project, caches: caches, library: library, decode: decode,
                findVoice: { try await VoiceActivityFinder.voiced(try await TrackAudio.load($0, track: $1.id)) })
        } else {
            music = MusicAnalysis(project: project, caches: caches, library: library)
        }
        return ExportWorkers(
            jobs: ProjectJobs(),
            voice: SequenceVoiceJobs(project: project, caches: caches, engine: nil, isolator: SilentIsolation(log: log)),
            music: music, segmenter: LeftHalf(log: log), detector: OneFace(log: log))
    }

    /// A sound in the package's `assets/` (a 1 s sine, AAC in an `.m4a`), and its source.
    func addAsset() throws -> String {
        let assets = project.package.url.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let name = "0123456789abcdef0123456789abcdef.m4a"
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: assets.appending(path: name), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = 44_100
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try #require(buffer.floatChannelData?[0])
        for n in 0..<frames { samples[n] = 0.25 * Float(sin(2 * Double.pi * 440 * Double(n) / 44_100)) }
        try file.write(from: buffer)
        return "assets/\(name)"
    }
}

/// Every name under `folder`, as paths relative to it; none if it is not there.
private func tree(_ folder: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else { return [] }
    return (enumerator.allObjects as? [String] ?? []).sorted()
}

@Suite struct ExportPreparationTests {
    /// `prepared` is the camera's stage, then the voice's, then the music's, each on what the one before gave: the same
    /// inputs as calling them by hand in that order, and its fakes ran in that order.
    @Test func preparedIsTheThreeStagesInOrder() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let workers = fixture.workers()
            let prepared = try await ExportPreparation.prepared(
                project: fixture.project, document: fixture.document, caches: fixture.caches, needs: .video, workers: workers
            ) { _ in }
            let log = fixture.log
            #expect(log.first("camera") < log.first("voice") && log.first("voice") < log.first("music"), "\(log.all)")
            #expect(!prepared.cleanupSkipped && prepared.remakeMusic != nil)
            #expect(prepared.analysis.personMasks.count == 1 && prepared.analysis.faceTracks.count == 1)
            #expect(Set(prepared.analysis.cleanVoice.keys) == ["take-001/mic"] && prepared.analysis.loudness["take-001/mic"] != nil)
            #expect(Set(prepared.analysis.musicFiles.keys) == [calm] && prepared.analysis.voiceActivity["take-001/mic"] != nil)

            // By hand, with workers of their own (the caches have it all now).
            let other = fixture.workers()
            let camera = try await ExportPreparation.camera(
                .none, project: fixture.project, document: fixture.document, caches: fixture.caches, jobs: other.jobs,
                segmenter: other.segmenter, detector: other.detector) { _ in }
            let voice = try await ExportPreparation.voice(
                camera, document: fixture.document, needs: .video, voice: other.voice, jobs: other.jobs) { _ in }
            let music = try await ExportPreparation.music(voice.analysis, document: fixture.document, needs: .video, music: other.music) { _ in }
            #expect(music.analysis == prepared.analysis)
            #expect(voice.cleanupSkipped == prepared.cleanupSkipped && music.remakeMusic != nil)
            // And the contract's `prepare`, with workers of its own of the isolation and the library given (the camera's
            // caches are there, so Vision is not asked): the same, with the music's remaking.
            let alone = try await ExportPreparation.prepare(
                project: fixture.project, document: fixture.document, caches: fixture.caches, needs: .video,
                isolator: SilentIsolation(log: fixture.log), library: fixture.library) { _ in }
            #expect(alone.analysis == prepared.analysis && alone.remakeMusic != nil && !alone.cleanupSkipped)
        }
    }

    /// A GIF has no sound: nothing of the voice nor of the music is prepared, the clean voice and the loudness stay as
    /// they came, and the music's files and voice are emptied; the camera is prepared all the same.
    @Test func withoutSoundNothingOfTheVoiceOrTheMusic() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            var inputs = AnalysisInputs()
            inputs.cleanVoice = ["take-001/mic": CleanVoice(files: ["seg": dir.appending(path: "clean.caf")])]
            inputs.musicFiles = [calm: dir.appending(path: "calm.caf")]
            inputs.voiceActivity = ["take-001/mic": VoiceActivity(spans: [])]
            let prepared = try await ExportPreparation.prepared(
                project: fixture.project, document: fixture.document, caches: fixture.caches, needs: .gif,
                workers: fixture.workers(), onto: inputs) { _ in }
            #expect(prepared.analysis.cleanVoice == inputs.cleanVoice && prepared.analysis.loudness.isEmpty)
            #expect(prepared.analysis.musicFiles.isEmpty && prepared.analysis.voiceActivity.isEmpty)
            #expect(prepared.remakeMusic == nil && !prepared.cleanupSkipped)
            #expect(prepared.analysis.personMasks.count == 1)
            #expect(!fixture.log.all.contains("voice") && !fixture.log.all.contains("music"))
            #expect(tree(fixture.caches.folder(.clean)).allSatisfy { !$0.hasSuffix(".caf") })
            #expect(tree(fixture.caches.folder(.music)).isEmpty)
        }
    }

    /// The progress goes from 0 to 1 and never down, each stage in its third.
    @Test func progressRisesToOneAcrossTheStages() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            let reported = Mutex<[Double]>([])
            _ = try await ExportPreparation.prepared(
                project: fixture.project, document: fixture.document, caches: fixture.caches, needs: .video,
                workers: fixture.workers()
            ) { fraction in reported.withLock { $0.append(fraction) } }
            let fractions = reported.withLock { $0 }
            #expect(fractions.first == 0 && fractions.last == 1)
            #expect(fractions == fractions.sorted() && Set(fractions).count == fractions.count, "\(fractions)")
            for third in 0..<3 {
                let low = Double(third) / 3, high = Double(third + 1) / 3
                #expect(fractions.contains { $0 > low && $0 < high - 1e-9 }, "the stage \(third) said nothing between")
            }
        }
    }

    /// A stage that fails says which it is: an imported sound whose reading stops partway fails the music's.
    @Test func aFailingStageSaysWhich() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await Fixture(in: dir)
            var document = fixture.document
            document.music.items = [MusicItem(id: "mu-00000001", source: try fixture.addAsset(), start: 0, end: 1_000_000_000)]
            let workers = fixture.workers(decode: { _, destination, _ in
                try Data(repeating: 1, count: 100).write(to: destination)
                throw ImportedAudioError.readingStopped("the file ends early")
            })
            do {
                _ = try await ExportPreparation.prepared(
                    project: fixture.project, document: document, caches: fixture.caches, needs: .video, workers: workers) { _ in }
                Issue.record("the preparation went on")
            } catch let error as ExportPreparationError {
                #expect(error.stage == .music)
                #expect((error.underlying as? JobError).map { if case .failed = $0.problem { true } else { false } } == true)
                #expect(String(describing: error).contains("music"))
            }
            #expect(tree(fixture.caches.folder(.music)).isEmpty)
        }
    }

    /// Cancelled partway (the music's theme being made), the preparation throws `CancellationError`, not a stage's
    /// error, and leaves no file of what it was making.
    @Test func cancellationStopsAndLeavesNoCache() async throws {
        try await withTemporaryDirectory { dir in
            let held = Mutex(false)
            let fixture = try await Fixture(in: dir, synthesize: { score, stop in
                held.withLock { $0 = true }
                while !stop() { usleep(1_000) }
                return nil
            })
            let workers = fixture.workers()
            let (project, document, caches) = (fixture.project, fixture.document, fixture.caches)
            let task = Task {
                try await ExportPreparation.prepared(project: project, document: document, caches: caches, needs: .video, workers: workers) { _ in }
            }
            #expect(await eventually(timeout: patience) { held.withLock { $0 } })
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(await eventually(timeout: patience) { await fixture.library.inFlight == 0 })
            #expect(tree(dir.appending(path: "Music")).allSatisfy { !$0.hasSuffix(".caf") })
            #expect(tree(caches.folder(.ducking)).allSatisfy { !$0.contains(".tmp") })
        }
    }
}

// MARK: - Fakes

/// An isolation that writes silence as the clean voice (exactly the span's frames), and logs `voice`.
private final class SilentIsolation: VoiceIsolating {
    let log: Log

    init(log: Log) {
        self.log = log
    }

    var isAvailable: Bool { true }

    func clean(_ audio: TrackAudio, span: TrackAudioSpan, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        log.add("voice")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVAudioFileTypeKey: kAudioFileCAFType,
        ]
        let frames = AVAudioFrameCount(span.frames.count)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)))
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: 0, count: Int(frames))
        try file.write(from: buffer)
        file.close()
        progress(1)
    }
}

/// A segmenter that finds the person in the left half of every frame, and logs `camera`.
private final class LeftHalf: PersonSegmenter {
    let log: Log

    init(log: Log) {
        self.log = log
    }

    func mask(of frame: CVPixelBuffer) throws -> CVPixelBuffer {
        log.add("camera")
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_OneComponent8, nil, &made) == kCVReturnSuccess,
              let buffer = made
        else { throw TestSupportError.failed("no mask buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<36 {
            for x in 0..<64 { pixels[y * row + x] = x < 32 ? 255 : 0 }
        }
        return buffer
    }
}

/// A detector that finds one face in the middle of every frame, and logs `camera`.
private final class OneFace: FaceDetector {
    let log: Log

    init(log: Log) {
        self.log = log
    }

    func faces(in frame: CVPixelBuffer) throws -> [ProjectFormat.NormalizedRect] {
        log.add("camera")
        return [NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)]
    }
}
