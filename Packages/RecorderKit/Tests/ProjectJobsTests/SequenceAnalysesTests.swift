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
// a fake isolation, the words come from a fake engine and the person from a fake segmenter.

private let base = HostTime(nanoseconds: 11_000_000_000_000)

private func clean(_ take: String, _ segment: Int = 1) -> AnalysisJobKind {
    .soundIsolation(take: take, track: "mic", segment: segment)
}
private func loudness(_ take: String, _ track: String = "mic") -> AnalysisJobKind { .loudness(take: take, track: track) }
private func mask(_ take: String, _ segment: Int) -> AnalysisJobKind { .personMask(take: take, track: "camera", segment: segment) }
private func face(_ take: String, _ segment: Int) -> AnalysisJobKind { .faceTrack(take: take, track: "camera", segment: segment) }

@Suite struct SequenceAnalysesTests {
    /// With one take, the jobs of the sequence are those of `VoiceJobs` of the project's take: the same kinds in the same
    /// order, a work for each and none for the others, the same transcription, and the same caches read once they ran.
    @Test func oneTakeAsksWhatVoiceJobsAsks() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await oneTake(in: dir)
            let caches = projectCaches(in: dir, project)
            let isolation = SilentIsolation()
            let sequence = SequenceVoiceJobs(project: project, caches: caches, engine: OneWord(), isolator: isolation)
            let voice = VoiceJobs(project: project, caches: caches, engine: OneWord(), isolator: isolation)
            var document = EditDocument.legacy(for: project)
            #expect(sequence.needed(for: document) == voice.needed(for: document))
            #expect(sequence.applied(to: .none, document: document) == voice.applied(to: .none, document: document))

            document.audio.tracks[AudioPlan.key(take: "take-001", track: "mic")] = TrackGain(gain: 1, muted: false, cleanup: 0.6)
            document.audio.normalize = true
            let kinds = voice.needed(for: document)
            #expect(kinds == [clean("take-001", 1), clean("take-001", 2), loudness("take-001"), loudness("take-001", "system-audio")])
            #expect(sequence.needed(for: document) == kinds)
            #expect(sequence.jobs(ofTake: "take-001") === sequence.jobs(ofTake: "take-001"))
            #expect(sequence.jobs(ofTake: "take-002") == nil)
            for kind in kinds { #expect(sequence.work(for: kind) != nil) }
            for kind in [clean("take-002"), loudness("take-002"), .transcription(take: "take-001", track: "mic"),
                         mask("take-001", 1), .sensitiveScan(take: "take-001")] {
                #expect(sequence.work(for: kind) == nil && voice.work(for: kind) == nil)
            }
            let transcription = try #require(voice.transcription(language: "es-MX")).0
            #expect(sequence.transcriptions(language: "es-MX", document: document).map(\.0) == [transcription])

            let jobs = ProjectJobs()
            for kind in kinds { _ = try await jobs.result(of: kind, work: try #require(sequence.work(for: kind))) }
            #expect(sequence.needed(for: document) == [] && voice.needed(for: document) == [])
            var inputs = AnalysisInputs()
            inputs.personMasks = [CameraSegment(take: "take-001", track: "camera", segment: 1): dir]
            let applied = sequence.applied(to: inputs, document: document)
            #expect(applied == voice.applied(to: inputs, document: document))
            #expect(Set(applied.cleanVoice.keys) == ["take-001/mic"] && applied.loudness.count == 2)
            #expect(applied.personMasks == inputs.personMasks)
        }
    }

    /// A take new in the sequence puts its jobs in the queue, after those of the take before it: its microphone, without
    /// a gain of its own, is cleaned by the cleanup of the same track in the other take (a track's gain holds by its id),
    /// and its words have a transcription of their own.
    @Test func aNewTakeQueuesItsJobs() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let isolation = SilentIsolation()
            let sequence = SequenceVoiceJobs(project: project, caches: projectCaches(in: dir, project), engine: OneWord(), isolator: isolation)
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)])
            // A project of `take-001` alone, as phase 2 left it.
            document.audio.tracks = ["take-001/mic": TrackGain(gain: 1, muted: false, cleanup: 0.6)]
            #expect(sequence.needed(for: document) == [clean("take-001")])
            #expect(sequence.transcriptions(language: "es-MX", document: document).map(\.0)
                == [.transcription(take: "take-001", track: "mic")])

            document.sequence += MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)]).sequence.suffix(1)
            let kinds = sequence.needed(for: document)
            #expect(kinds == [clean("take-001"), clean("take-002")])
            #expect(sequence.transcriptions(language: "es-MX", document: document).map(\.0)
                == [.transcription(take: "take-001", track: "mic"), .transcription(take: "take-002", track: "mic")])

            // What the editor does with them: each in the queue, in that order.
            let jobs = ProjectJobs()
            for kind in kinds { await jobs.enqueue(kind, work: try #require(sequence.work(for: kind))) }
            for kind in kinds { _ = try await jobs.result(of: kind, work: try #require(sequence.work(for: kind))) }
            #expect(isolation.calls.map { $0.hasPrefix("takes/take-001/") } == [true, false])
            #expect(isolation.calls.last?.hasPrefix("takes/take-002/") == true)
            #expect(sequence.needed(for: document) == [])
            #expect(Set(sequence.applied(to: .none, document: document).cleanVoice.keys) == ["take-001/mic", "take-002/mic"])

            // Taken out of the sequence again, it asks for nothing and its clean voice is not read.
            document.sequence.removeLast()
            #expect(Set(sequence.applied(to: .none, document: document).cleanVoice.keys) == ["take-001/mic"])
        }
    }

    /// The camera's masks and faces of every take the sequence shows: asked for take by take, each take's filled without
    /// emptying the others', and the progress weighs the segments of each.
    @Test func fillKeepsEveryTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await twoTakesWithACamera(in: dir)
            let caches = projectCaches(in: dir, project)
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 1), ("take-002", 0, 1)])
            document.camera.background = .blurred
            document.camera.framing = CameraFraming(mode: .face, center: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.4)
            let takes = SequenceAnalyses.takes(shownBy: document, in: project)
            #expect(takes.map(\.id) == ["take-001", "take-002"])
            #expect(CameraAnalysis.neededJobs(document: document, takes: takes, package: project.package)
                == [face("take-001", 1), mask("take-001", 1), face("take-002", 1), face("take-002", 2), mask("take-002", 1),
                    mask("take-002", 2)])

            // A mask of each take in the caches, and a face of the second.
            var written: [CameraSegment: URL] = [:]
            for (take, index) in [("take-001", 1), ("take-002", 2)] {
                let url = try cacheFile(.masks, take: take, segment: index, of: project, caches: caches)
                #expect(ProjectCaches.writeAnalysis(Data("a movie".utf8), to: url))
                written[CameraSegment(take: take, track: "camera", segment: index)] = url
            }
            let face = CameraFaceTrack(
                algorithm: "faceTrack-1", frameSize: [320, 180],
                samples: [CameraFaceSample(t: base, face: NormalizedRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3))])
            let faceURL = try cacheFile(.faces, take: "take-002", segment: 1, of: project, caches: caches)
            #expect(ProjectCaches.writeAnalysis(try ProjectJSON.encoder().encode(face), to: faceURL))

            var inputs = AnalysisInputs()
            inputs.cleanVoice = ["take-001/mic": CleanVoice(files: ["seg-0001": dir.appending(path: "clean.caf")])]
            CameraAnalysis.fill(&inputs, document: document, takes: takes, package: project.package, caches: caches)
            #expect(inputs.personMasks == written)
            #expect(inputs.faceTracks == [CameraSegment(take: "take-002", track: "camera", segment: 1): face])
            #expect(inputs.cleanVoice.count == 1)

            // One take is what `fill` of that take reads.
            var one = AnalysisInputs(), alone = AnalysisInputs()
            CameraAnalysis.fill(&one, document: document, takes: [takes[1]], package: project.package, caches: caches)
            CameraAnalysis.fill(&alone, document: document, take: takes[1], package: project.package, caches: caches)
            #expect(one == alone && one.personMasks.count == 1)

            // Each job weighs the length of its segment in its own take: 1 s, 0.5 s and 0.5 s.
            let kinds = [mask("take-001", 1), mask("take-002", 1), mask("take-002", 2)]
            let states: [AnalysisJobKind: JobState] = [mask("take-001", 1): .done, mask("take-002", 1): .running(progress: 0.5)]
            #expect(abs(try #require(CameraAnalysis.progress(states, of: kinds, takes: takes)) - 0.625) < 1e-9)
            #expect(CameraAnalysis.progress(states, of: Array(kinds.prefix(1)), takes: takes)
                == CameraAnalysis.progress(states, of: Array(kinds.prefix(1)), take: takes[0]))
        }
    }

    /// The export waits for the jobs of every take the sequence shows (the voice's and the camera's) and has what they
    /// made, with its progress going up to 1.
    @Test func exportWaitsForEveryTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let caches = projectCaches(in: dir, project)
            let isolation = SilentIsolation()
            let sequence = SequenceVoiceJobs(project: project, caches: caches, engine: OneWord(), isolator: isolation)
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            document.audio.tracks["take-002/mic"]?.cleanup = 0.6
            document.audio.normalize = true
            #expect(sequence.needed(for: document) == [clean("take-001"), loudness("take-001"), clean("take-002"), loudness("take-002")])

            let reported = Mutex<[Double]>([])
            var inputs = AnalysisInputs()
            inputs.personMasks = [CameraSegment(take: "take-001", track: "camera", segment: 1): dir]
            let (prepared, skipped) = try await sequence.prepareExport(document, onto: inputs, jobs: ProjectJobs()) { fraction in
                reported.withLock { $0.append(fraction) }
            }
            #expect(!skipped)
            #expect(isolation.calls.count == 2)
            #expect(Set(prepared.cleanVoice.keys) == ["take-001/mic", "take-002/mic"])
            #expect(Set(prepared.loudness.keys) == ["take-001/mic", "take-002/mic"])
            #expect(prepared.personMasks == inputs.personMasks)
            #expect(prepared == sequence.applied(to: inputs, document: document))
            let fractions = reported.withLock { $0 }
            #expect(fractions.last == 1 && fractions == fractions.sorted() && fractions.contains { $0 > 0 && $0 <= 0.5 })

            // The camera's, of both takes.
            let withCamera = try await twoTakesWithACamera(in: dir.appending(path: "camera", directoryHint: .isDirectory))
            var cameraDocument = MultiTakeFixtures.sequence(of: withCamera, [("take-001", 0, 1), ("take-002", 0, 1)])
            cameraDocument.camera.background = .blurred
            var camera = AnalysisInputs()
            let segmenter = LeftHalf()
            try await CameraAnalysis.prepareForExport(
                &camera, document: cameraDocument, project: withCamera, caches: projectCaches(in: dir, withCamera), jobs: ProjectJobs(),
                segmenter: segmenter)
            #expect(Set(camera.personMasks.keys) == [
                CameraSegment(take: "take-001", track: "camera", segment: 1), CameraSegment(take: "take-002", track: "camera", segment: 1),
                CameraSegment(take: "take-002", track: "camera", segment: 2),
            ])
            #expect(segmenter.calls == 60)
        }
    }

    /// The search of sensitive data looks at each take the sequence shows, each focused on its own: one job per take.
    @Test func theSearchLooksAtEveryTakeShown() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let legacy = EditDocument.legacy(for: project)
            #expect(SensitiveScanJob.projects(of: project, shownBy: legacy).map(\.take.id) == ["take-002"])
            let both = MultiTakeFixtures.sequence(of: project, [("take-002", 0, 1), ("take-001", 0, 1), ("take-002", 2, 3)])
            let projects = SensitiveScanJob.projects(of: project, shownBy: both)
            #expect(projects.map(\.take.id) == ["take-002", "take-001"])
            #expect(projects[1].events == project.events(ofTake: "take-001") && !projects[1].events.isEmpty)
            var empty = legacy
            empty.sequence = []
            #expect(SensitiveScanJob.projects(of: project, shownBy: empty).isEmpty)
            #expect(SequenceAnalyses.takes(shownBy: empty, in: project).map(\.id) == ["take-002"])
        }
    }
}

// MARK: - Fixtures

private func projectCaches(in dir: URL, _ project: LoadedProject) -> ProjectCaches {
    ProjectCaches(root: dir.appending(path: "Caches", directoryHint: .isDirectory), projectID: project.manifest.resolvedProjectID)
}

/// A take of the display, 5 s from `base`, with a microphone of two segments (0.5–2 s, 3–4.5 s) and system audio of one
/// (1–3 s).
private func oneTake(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "voice")
    try await builder.addVideoTrack(
        id: "display-1",
        source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 320, height: 180), pixelScale: 1),
        segments: [VideoSegmentSpec(start: base, seconds: 5, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addAudioTrack(
        id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
        segments: [
            AudioSegmentSpec(start: base.adding(seconds: 0.5), seconds: 1.5),
            AudioSegmentSpec(start: base.adding(seconds: 3), seconds: 1.5, frequency: 660),
        ])
    try await builder.addAudioTrack(
        id: "system-audio", kind: .systemAudio, source: TrackSource(name: "System Audio", excludedBundleIDs: []),
        segments: [AudioSegmentSpec(start: base.adding(seconds: 1), seconds: 2, frequency: 220)])
    return try builder.write()
}

/// Two takes of the display with a camera: `take-001` of 2 s whose camera has one segment of 1 s, and `take-002` of 2 s,
/// recorded 60 s later, whose camera has two of 0.5 s; read as `LoadedProject.load` reads the package, on `take-002`.
private func twoTakesWithACamera(in dir: URL) async throws -> LoadedProject {
    let screen = Rect(x: 0, y: 0, width: 320, height: 180)
    func record(_ builder: TakeBuilder, start: HostTime, camera: [(Double, Double)]) async throws {
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: screen, pixelScale: 1),
            segments: [VideoSegmentSpec(start: start, seconds: 2, framesPerSecond: 10, width: 320, height: 180)])
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: TrackSource(name: "Camera"),
            segments: camera.map { VideoSegmentSpec(start: start.adding(seconds: $0.0), seconds: $0.1, width: 320, height: 180) })
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let first = try TakeBuilder(in: dir, name: "Camera")
    try await record(first, start: base, camera: [(0, 1)])
    _ = try first.write()
    let second = try TakeBuilder(appendingTo: first.package, take: "take-002")
    try await record(second, start: base.adding(seconds: 60), camera: [(0, 0.5), (1, 0.5)])
    _ = try second.write()
    return try LoadedProject.load(first.package.url)
}

/// The cache file of `folder` for segment `index` of the camera of `take`.
private func cacheFile(
    _ folder: AnalysisCacheFolder, take: String, segment index: Int, of project: LoadedProject, caches: ProjectCaches
) throws -> URL {
    let record = try #require(project.takes.first { $0.id == take }?.track("camera")?.segments.first { $0.index == index })
    let identity = try #require(SegmentIdentity.of(record, in: project.package))
    return try #require(folder == .masks
        ? CameraAnalysisCaches.maskFile(take: take, track: "camera", identity: identity, caches: caches)
        : CameraAnalysisCaches.faceFile(take: take, track: "camera", identity: identity, caches: caches))
}

/// An isolation that writes silence as the clean voice (exactly the span's frames), and keeps the segment of each call.
private final class SilentIsolation: VoiceIsolating {
    private let made = Mutex<[String]>([])

    var isAvailable: Bool { true }

    /// `TrackAudioSpan.segment` of each call, in order.
    var calls: [String] { made.withLock { $0 } }

    func clean(_ audio: TrackAudio, span: TrackAudioSpan, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        made.withLock { $0.append(span.segment) }
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

/// An engine that hears one word in each span.
private struct OneWord: SpeechEngine {
    func transcribe(_ audio: TrackAudio, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeechRun] {
        progress(1)
        return audio.spans.map { span in
            let start = Double(span.frames.lowerBound) / TrackAudio.sampleRate
            return SpeechRun(text: " palabra", start: start + 0.1, end: start + 0.5)
        }
    }
}

/// A segmenter that finds the person in the left half of every frame, and counts its calls.
private final class LeftHalf: PersonSegmenter {
    private let count = Mutex(0)

    var calls: Int { count.withLock { $0 } }

    var isAvailable: Bool { true }

    func mask(of frame: CVPixelBuffer) throws -> CVPixelBuffer {
        count.withLock { $0 += 1 }
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
