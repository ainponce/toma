// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import Recording

/// The project of phase 3 of golden 4 (phases 4 and 5 design §4.2): a package of two takes whose document
/// (`documentVersion` 4, as phase 3 writes `edit.json`) uses what phase 3 brought, and golden 4's cases, golden 3's
/// (`GoldenDocuments`) and this one after them.
///
/// Its document (`makeDocument(for:)`) has, in output order: a title card over the blurred frame (1 s), take 1's first
/// 2 s, a frozen frame (0.8 s), take 1 from 2 to 3.5 s, take 2 from 0.5 to 2 s heard 0.3 s before it is seen (a J cut),
/// an imported clip (1 s of `MediaFixtures.clip`, its sound at −3 dB) and take 2 from 2 to 2.8 s; 8.6 s in all. Over
/// it: a lower third over the output, an arrow drawn in and a step popping in over take 1, a Dim block on take 1 and a
/// loupe that follows the cursor on take 2; the microphone of take 1 at −6 dB for a second; the theme
/// `library:music-1/calm` over the whole output, ducked (the default ducking) where a microphone has a voice; and two
/// markers, one recorded (named) and one added. Its frames are drawn at 640 × 360 at `golden4Case.times`, each where
/// one of these layers shows.
///
/// The takes are written by `TakeBuilder` with the hardware encoder alone (`GoldenProjects.goldenFramesEncoder`), the
/// same way on every run, as a package of format version 3 that the second take raises to 5, as the recorder does. The
/// imported clip is written by `MediaFixtures.clip` in ProRes 422 Proxy, whose frames are the same bytes on every run
/// (the H.264 and HEVC of `AVAssetWriter` are not), and placed in `assets/` under a fixed name of the editor's form
/// (`asset`): the editor names an asset by its bytes, but a movie's header holds the time it was written, so its bytes
/// change on every run and the recorded document must name the same file on every run. Like `GoldenDocuments`, its
/// document is built by hand, without the commands of `Editing`, so it is the same with later code; it is used only
/// when recording, a comparison reads the recorded file. Changing it, or `golden4Cases`, changes golden 4: never do it
/// once it is recorded.
public enum GoldenPhase3Project {
    /// The name of the case, and of its package, `phase3Project.toma`.
    public static let name = "phase3Project"

    /// The case of golden 4 after golden 3's: a document of version 4 in a package of version 5, mixed, drawn at 360 px
    /// on the shorter side at the title card (0.5 s), its fade into take 1 (0.85 s), the annotations coming in (1.35 s)
    /// and shown with the stretch at −6 dB heard (2.2 s), the frozen frame (3.4 s), the Dim block (4.8 s), the loupe
    /// (6.3 s) and the imported clip (7.3 s).
    public static let golden4Case = GoldenDocuments.Case(
        name: name, times: [0.5, 0.85, 1.35, 2.2, 3.4, 4.8, 6.3, 7.3], mixes: true, documentVersion: 4, formatVersion: 5,
        shortSide: 360)

    /// The cases of golden 4, in the order of their frames and mix: golden 3's (`GoldenDocuments.golden3Cases`), then
    /// `golden4Case`.
    public static let golden4Cases: [GoldenDocuments.Case] = GoldenDocuments.golden3Cases + [golden4Case]

    /// Where the imported clip is in the package, as the document names it: `assets/` and a fixed name of 32 hex digits
    /// (the first of the SHA-256 of "golden-4 imported clip").
    public static let asset = "assets/f961a5d5f1e9bb46229c50f1ee0ffa2d.mov"

    // MARK: - The cases of golden 4

    /// Writes the package of case `name` of `golden4Cases` into `dir` and returns it: `makeProject(in:)` for this one,
    /// `GoldenDocuments.makeProject(_:in:)` for golden 3's.
    public static func makeProject(_ name: String, in dir: URL) async throws -> LoadedProject {
        name == self.name ? try await makeProject(in: dir) : try await GoldenDocuments.makeProject(name, in: dir)
    }

    /// The document of case `name` of `golden4Cases` for `project` (its `makeProject`): `makeDocument(for:)` for this
    /// one, `GoldenDocuments.makeDocument(_:for:)` for golden 3's.
    public static func makeDocument(_ name: String, for project: LoadedProject) throws -> EditDocument {
        name == self.name ? try makeDocument(for: project) : try GoldenDocuments.makeDocument(name, for: project)
    }

    /// The digests of the video case `name` of `golden4Cases` draws from: `videoDigests(of:)` for this one,
    /// `GoldenProjects.videoDigests(of:)` for golden 3's.
    public static func videoDigests(_ name: String, of project: LoadedProject) async throws -> [String] {
        name == self.name ? try await videoDigests(of: project) : try await GoldenProjects.videoDigests(of: project)
    }

    // MARK: - The project

    /// Writes `phase3Project.toma` into `dir` and returns it as `LoadedProject.load` reads it without a take: focused
    /// on the last one, `take-002`.
    ///
    /// - `take-001`: 4 s of the display `display-1` (16:9, 640 × 360, `SampleFactory`'s pattern), a 4:3 camera (its
    ///   colours inverted) with the default style, the microphone `mic` (440 Hz at 1/4 of full scale), the cursor
    ///   moving over the display the whole time, and a marker pressed at 1.2 s.
    /// - `take-002`, recorded 60 s later: 3 s of `display-1` checkered (every other square of 40 px inverted, so the
    ///   loupe's lens shows its magnification), `mic` at 660 Hz, stereo system audio `system-audio` (880 Hz at 0.1 of
    ///   full scale, so the mix is stereo, and the music and the clip are heard in stereo) and the cursor moving over
    ///   the display.
    /// - The imported clip at `asset`: 2 s of 640 × 360 at 30 fps in ProRes 422 Proxy (`MediaFixtures.clip`, pattern 41)
    ///   with a stereo sine of 330 Hz.
    /// - Throws: what writing the takes or the clip throws.
    public static func makeProject(in dir: URL) async throws -> LoadedProject {
        let first = try TakeBuilder(in: dir, name: name, formatVersion: 3)
        first.videoEncoder = GoldenProjects.goldenFramesEncoder
        first.cameraStyle = .default
        try await record(into: first, start: base, seconds: 4, frequency: 440, checkered: false, camera: true, systemAudio: false)
        try first.addEvents([InputEvent(t: base.adding(seconds: 1.2), kind: .marker)])
        _ = try first.write()
        let second = try TakeBuilder(appendingTo: first.package, take: secondTake)
        second.videoEncoder = GoldenProjects.goldenFramesEncoder
        try await record(
            into: second, start: base.adding(seconds: 60), seconds: 3, frequency: 660, checkered: true, camera: false,
            systemAudio: true)
        _ = try second.write()

        let clip = try await offThePool {
            try MediaFixtures.clip(in: dir, seconds: 2, size: [640, 360], pattern: 41, tone: 330, codec: .proRes422Proxy)
        }
        let assets = first.package.url.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: clip, to: first.package.url.appending(path: asset, directoryHint: .notDirectory))
        return try LoadedProject.load(first.package.url)
    }

    /// The document of `project` (`makeProject(in:)`), of `EditDocument.currentVersion`, as the editor of phase 3 would
    /// have left it (see the type): `EditDocument.legacy(for:)` of its last take, the screen and the camera of each
    /// take its own legacy document's (`MultiTakeFixtures.sequence(of:_:)`), with ids of its own fixed (`c-`, `a-`,
    /// `z-`, `g-`, `mu-` and `m-`, then 8 hex) so it is the same on every run. Source times count from each take's
    /// legacy clip.
    /// - Throws: `TestSupportError.failed` for a project that is not this one.
    public static func makeDocument(for project: LoadedProject) throws -> EditDocument {
        guard let take1 = project.focused(on: firstTake), let take2 = project.focused(on: secondTake), project.takes.count == 2,
            take1.take.tracks.contains(where: { $0.kind == .camera }), take1.events.contains(where: { $0.kind == .marker }),
            take2.take.tracks.contains(where: { $0.kind == .systemAudio }), project.package.mediaAsset(asset, as: .video) != nil
        else {
            throw TestSupportError.failed(
                "\(name): two takes, the first with a camera and a marker, the second with system audio, and the imported clip")
        }
        var doc = MultiTakeFixtures.sequence(of: project, [(firstTake, 0, 4), (secondTake, 0, 3)])
        let start1 = try unwrap(EditDocument.legacy(for: take1).sequence.first?.start, "\(name): take 1's legacy clip")
        let start2 = try unwrap(EditDocument.legacy(for: take2).sequence.first?.start, "\(name): take 2's legacy clip")
        func s1(_ t: Double) -> HostTime { start1.adding(seconds: t) }
        func s2(_ t: Double) -> HostTime { start2.adding(seconds: t) }
        func clip(_ n: Int, _ take: String, _ from: HostTime, _ to: HostTime, content: ClipContent? = nil, audioShift: Int64 = 0) -> Clip {
            Clip(id: id("c-", n), take: take, start: from, end: to, speed: 1, content: content, audioShift: audioShift)
        }
        let second: Int64 = 1_000_000_000

        // The sequence: a card at take 1's start, its first 2 s, a frozen frame at 2 s, take 1 to 3.5 s, take 2 from
        // 0.5 s heard 0.3 s sooner (a J cut), the imported clip's [0.5, 1.5) s at −3 dB at take 2's 2 s, and take 2 to
        // 2.8 s.
        let card = TitleCard(title: "Toma", subtitle: "Phase 3", style: .centered, background: .blurredFrame)
        doc.sequence = [
            clip(1, firstTake, s1(0), s1(0), content: .card(card, duration: second)),
            clip(2, firstTake, s1(0), s1(2)),
            clip(3, firstTake, s1(2), s1(2), content: .freeze(duration: 800_000_000)),
            clip(4, firstTake, s1(2), s1(3.5)),
            clip(5, secondTake, s2(0.5), s2(2), audioShift: -300_000_000),
            clip(6, secondTake, s2(2), s2(2), content: .media(MediaClip(asset: asset, start: second / 2, end: 3 * second / 2, volume: -3))),
            clip(7, secondTake, s2(2), s2(2.8)),
        ]
        let duration = TimeMap(sequence: doc.sequence).duration
        guard duration == 8_600_000_000 else { throw TestSupportError.failed("\(name): \(duration) ns of output, not 8.6 s") }

        // A lower third over the output over [1.2, 2.8) s; over take 1's [0.3, 1.9) s (the output's [1.3, 2.9) s), an
        // arrow drawn in toward the middle of the screen and the first step, popping in, where it points.
        let content = AnnotationAnchor.content(take: firstTake, start: s1(0.3), end: s1(1.9))
        let from = NormalizedPoint(x: 0.7, y: 0.25), to = NormalizedPoint(x: 0.52, y: 0.42)
        doc.annotations = AnnotationPlan(items: [
            Annotation(
                id: id("a-", 1), anchor: .output(start: 1_200_000_000, end: 2_800_000_000), layer: 0,
                kind: .text(TextAnnotation(string: "Toma, phase 3", preset: .lowerThird, size: 0.06)),
                rect: NormalizedRect(x: 0.06, y: 0.78, width: 0.5, height: 0.072)),
            Annotation(
                id: id("a-", 2), anchor: content, layer: 0, kind: .arrow(ArrowAnnotation(from: from, to: to, head: .filled)),
                rect: NormalizedRect(x: to.x, y: from.y, width: from.x - to.x, height: to.y - from.y), enter: .draw),
            Annotation(
                id: id("a-", 3), anchor: content, layer: 1, kind: .step(StepAnnotation()),
                rect: NormalizedRect(x: 0.46, y: 0.44, width: 0.07 * 9 / 16, height: 0.07), enter: .pop),
        ])

        // Dim over take 1's [2.3, 3.4) s (the output's [4.1, 5.2) s) at a fixed point; a rounded loupe of 0.2 that
        // follows the cursor over take 2's [0.7, 1.9) s (the output's [5.5, 6.7) s).
        doc.zoom.regions = [
            ZoomRegion(
                id: id("z-", 1), take: firstTake, start: s1(2.3), end: s1(3.4), origin: .user, depth: 2,
                focus: .fixed(x: 0.35, y: 0.4), instant: false, mode: .dim),
            ZoomRegion(
                id: id("z-", 2), take: secondTake, start: s2(0.7), end: s2(1.9), origin: .user, depth: 2, focus: .follow,
                instant: false, mode: .loupe, loupe: LoupeStyle(radius: 0.2, shape: .roundedRect)),
        ]

        // Take 1's microphone at −6 dB over its [0.5, 1.5) s (the output's [1.5, 2.5) s).
        let micKey = AudioPlan.key(take: firstTake, track: microphoneTrack)
        var gain = doc.audio.tracks[micKey] ?? TrackGain(gain: 1, muted: false)
        gain.ranges = [GainRange(id: id("g-", 1), take: firstTake, start: s1(0.5), end: s1(1.5), gain: -6)]
        doc.audio.tracks[micKey] = gain

        // The calm theme over the whole output as the Music track adds it (−14 dB, a fade in of 1 s and out of 2 s,
        // looping), with the default ducking.
        doc.music = MusicPlan(
            items: [MusicItem(
                id: id("mu-", 1), source: "library:music-1/calm", start: 0, end: duration, offset: 0, gain: -14,
                fadeIn: second, fadeOut: 2 * second, loop: true)],
            ducking: .default)

        // The marker take 1 recorded at 1.2 s, named, and one added on take 2 at 1 s.
        doc.markers = MarkerPlan(items: [
            Marker(id: id("m-", 1), take: firstTake, t: s1(1.2), name: "Intro", origin: .recorded),
            Marker(id: id("m-", 2), take: secondTake, t: s2(1), name: "Demo", origin: .added),
        ])
        let problems = DocumentRules.problems(in: doc)
        guard problems.isEmpty else { throw TestSupportError.failed("\(name): the document breaks \(problems)") }
        return doc
    }

    /// One line per video file of `project` (`makeProject(in:)`) its frames are drawn from, with the
    /// `encodedVideoDigest(of:)` of its file: `<take> <track> <segment> <digest>` for every video segment of each take,
    /// in the manifest's order, then `<asset> <digest>` for the imported clip. What golden 4 compares with the digests
    /// recorded next to its files, to tell a change of the video (the encoder) from a change of the render.
    public static func videoDigests(of project: LoadedProject) async throws -> [String] {
        var lines: [String] = []
        for take in project.takes {
            for track in take.tracks where [.display, .window, .camera].contains(track.kind) {
                for segment in track.segments {
                    let file = project.package.fileURL(segment.file)
                    lines.append("\(take.id) \(track.id) \(segment.index) \(try await encodedVideoDigest(of: file))")
                }
            }
        }
        let clip = try unwrap(project.package.mediaAsset(asset, as: .video), "\(name): the imported clip \(asset)")
        lines.append("\(asset) \(try await encodedVideoDigest(of: clip))")
        return lines
    }

    // MARK: - The takes

    private static let firstTake = "take-001"
    private static let secondTake = "take-002"
    /// `GoldenDocuments`' time of the takes' start, well after boot.
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static let screen = Rect(x: 0, y: 0, width: 640, height: 360)
    private static let microphoneTrack = "mic"

    /// `prefix` and `number` in 8 lowercase hex digits.
    private static func id(_ prefix: String, _ number: Int) -> String {
        prefix + String(format: "%08x", number)
    }

    /// Adds to `builder` `seconds` of `display-1` (`checkered` or not), of a 4:3 `camera` (its colours inverted) when
    /// `camera`, of `mic` (the sine at `frequency`), of stereo `system-audio` (880 Hz at 0.1) when `systemAudio` and of
    /// the cursor from `start`, with the display's geometry as the coordinator logs it just before the first segment.
    private static func record(
        into builder: TakeBuilder, start: HostTime, seconds: Double, frequency: Double, checkered: Bool, camera: Bool,
        systemAudio: Bool
    ) async throws {
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display 1", displayID: 1, globalFrame: screen, pixelScale: 1),
            segments: [VideoSegmentSpec(
                start: start, seconds: seconds, width: Int(screen.width), height: Int(screen.height),
                transform: checkered ? invertingCheckers : nil)])
        if camera {
            try await builder.addVideoTrack(
                id: "camera", kind: .camera, source: TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera"),
                segments: [VideoSegmentSpec(start: start, seconds: seconds, width: 640, height: 480, transform: invertingColors)])
        }
        try await builder.addAudioTrack(
            id: microphoneTrack, source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
            segments: [AudioSegmentSpec(start: start, seconds: seconds, frequency: frequency)])
        if systemAudio {
            try await builder.addAudioTrack(
                id: "system-audio", kind: .systemAudio, source: TrackSource(name: "Synthetic System Audio", excludedBundleIDs: []),
                segments: [AudioSegmentSpec(start: start, seconds: seconds, channels: 2, frequency: 880, amplitude: 0.1)])
        }
        try builder.addEvents([
            InputEvent(t: start.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: screen, scale: 1))
        ])
        try builder.addEvents((0..<Int(seconds * 120)).map { i in
            let f = Double(i) / (seconds * 120)
            return InputEvent(
                t: start.adding(seconds: Double(i) / 120),
                kind: .cursor(x: screen.x + screen.width * (0.2 + 0.6 * f), y: screen.y + screen.height * (0.3 + 0.4 * f)))
        })
    }

    /// `sample` with the red, green and blue of every pixel inverted (a `VideoSegmentSpec.transform`).
    @Sendable private static func invertingColors(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
        inverting(sample) { _, _ in true }
    }

    /// `sample` with the red, green and blue of every other square of 40 × 40 px inverted, from the top left (a
    /// `VideoSegmentSpec.transform`).
    @Sendable private static func invertingCheckers(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
        inverting(sample) { x, y in (x / 40 + y / 40) % 2 == 1 }
    }

    /// `sample` with the red, green and blue of each pixel `(x, y)` for which `where` holds inverted, alpha kept.
    private static func inverting(_ sample: CMSampleBuffer, where inverts: (Int, Int) -> Bool) -> CMSampleBuffer {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { preconditionFailure("GoldenPhase3Project: no image") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let pixels = CVPixelBufferGetBaseAddress(pixelBuffer) else { preconditionFailure("GoldenPhase3Project: no pixels") }
        let width = CVPixelBufferGetWidth(pixelBuffer), bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
            let row = pixels.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width where inverts(x, y) { row[x] ^= 0x00FF_FFFF }  // BGRA bytes: B, G and R, not A
        }
        return sample
    }
}
