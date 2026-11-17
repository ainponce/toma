// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import Recording

/// The documents of the golden files of milestone 1c (plan 1c decision 2): edit documents of milestone 1b
/// (`documentVersion` 1), with cuts, speed, a zoom with motion blur, the cursor's spring, ripples and click sounds, a
/// wallpaper with the macOS window frame, camera changes, a 9:16 bubble and two screens, whose frames
/// (`golden1cFramesMatch`) and mix (`golden1cMixMatches`) were recorded from the commit that closes 1b on `main`, so that
/// every change of 1c can show that such a document still draws and sounds the same, byte for byte, once migrated.
///
/// Each case's take is written by `TakeBuilder` (`makeProject`), the same way on every run, with its video by the
/// hardware encoder alone (`GoldenProjects.goldenFramesEncoder`), as a package of format version 3. Its document is
/// recorded with the golden files (`documents/<case>.json`, as 1b writes `edit.json`): `makeDocument`, which builds it
/// from `EditDocument.legacy(for:)` by changing its fields as 1b's editor would have (this target does not see the
/// commands of `Editing`, and so it compiles the same with 1c's code), is used only when recording; a comparison reads the
/// recorded file. Its frames are drawn at `outputSize(of:)` at its `times`, all shorter than its output.
/// Changing a case, or the order of `cases`, changes the golden files: never do it once they are recorded.
public enum GoldenDocuments {
    public struct Case: Sendable {
        public var name: String
        /// Output times its frames are drawn at, in order.
        public var times: [Double]
        /// Whether its mix is in the golden mix.
        public var mixes: Bool
    }

    /// In the order of their frames in the golden file, and of their mix in the golden mix.
    public static let cases: [Case] = [
        Case(name: "cutsAndSpeed", times: [0.5, 1.2, 2.0], mixes: true),
        Case(name: "zoomWithBlur", times: [0.6, 1.0, 2.6], mixes: true),
        Case(name: "backgroundsAndFrame", times: [0.5, 1.5], mixes: false),
        Case(name: "cameraChanges", times: [0.9, 1.25, 2.0, 2.4], mixes: false),
        Case(name: "portraitBubble", times: [0.5, 1.5], mixes: false),
        Case(name: "twoScreens", times: [1.4, 1.6, 2.5], mixes: true),
    ]

    /// Writes the take of case `name` into `dir` and returns it: for `cameraChanges`, `GoldenProjects`'
    /// `cameraWithStyleChanges` (the package `cameraWithStyleChanges.toma`); for the others, the package `<name>.toma`.
    /// Every package is of format version 3, and its video is written by the hardware encoder alone
    /// (`GoldenProjects.goldenFramesEncoder`), so the frames drawn from it are the golden ones.
    /// - Throws: `TestSupportError.missing` for a name that is not a case, or what writing the take throws.
    public static func makeProject(_ name: String, in dir: URL) async throws -> LoadedProject {
        func builder() throws -> TakeBuilder {
            let builder = try TakeBuilder(in: dir, name: name, formatVersion: 3)
            builder.videoEncoder = GoldenProjects.goldenFramesEncoder
            return builder
        }
        switch name {
        case "cutsAndSpeed", "backgroundsAndFrame", "portraitBubble": return try await fourSecondTake(try builder(), clicks: [])
        case "zoomWithBlur": return try await fourSecondTake(try builder(), clicks: [0.7, 1.9])
        case "cameraChanges":
            return try await GoldenProjects.make(
                "cameraWithStyleChanges", in: dir, formatVersion: 3, videoEncoder: GoldenProjects.goldenFramesEncoder)
        case "twoScreens": return try await twoScreens(try builder())
        default: throw TestSupportError.missing("golden 1c case \(name)")
        }
    }

    /// The document of case `name` for `project` (its `makeProject`): `EditDocument.legacy(for:)` with the fields of the
    /// case changed as 1b's editor would have changed them, ids of its own fixed (`c-`, `z-`, `k-` and `p-`, then 8 hex)
    /// so it is the same on every run. Its times are output times of the legacy document, which shows the take from its
    /// timeline start at 1×.
    /// - Throws: `TestSupportError.missing` for a name that is not a case, `TestSupportError.failed` for a project that is
    ///   not the case's.
    public static func makeDocument(_ name: String, for project: LoadedProject) throws -> EditDocument {
        var doc = EditDocument.legacy(for: project)
        guard doc.sequence.count == 1, let clip = doc.sequence.first, clip.speed == 1 else {
            throw TestSupportError.failed("the legacy document of \(name) is not one clip at 1×: \(doc.sequence)")
        }
        let take = project.take.id
        /// The source instant the legacy document shows at output second `t`.
        func source(_ t: Double) -> HostTime { clip.start.adding(seconds: t) }
        let hasCamera = project.take.tracks.contains { $0.kind == .camera }
        switch name {
        case "cutsAndSpeed":
            // Split at 1.0 s (the second piece a new clip), delete [1.0, 1.5) s (its start, so the new clip starts at
            // 1.5 s) and play the second clip at 2×: [0, 1) s at 1× and [1.5, 4) s at 2×, 2.25 s of output.
            guard hasCamera, clip.end > source(1.5) else { throw TestSupportError.failed("\(name): a take of 4 s with a camera") }
            var first = clip, second = clip
            first.end = source(1.0)
            second.id = "c-00000002"
            second.start = source(1.5)
            second.speed = 2
            doc.sequence = [first, second]
        case "zoomWithBlur":
            // A zoom of the user's at 2× over [0.5, 2.5) s at a fixed point, the centre of the screen (what 1b's "Fixed
            // Point" gives), moving with the spring; motion blur of the zoom and of the cursor at 0.5; the cursor with the
            // Medium spring of the Cursor tab, ripples and the soft click sound.
            doc.zoom.regions = [ZoomRegion(
                id: "z-00000001", take: take, start: source(0.5), end: source(2.5), origin: .user, depth: 2,
                focus: .fixed(x: 0.5, y: 0.5), instant: false)]
            doc.zoom.motionBlur = 0.5
            doc.cursor.motionBlur = 0.5
            doc.cursor.smoothing = .spring(SpringSpec(damping: 1.0, response: 0.16))
            doc.cursor.clickEffect = "ripple-1"
            doc.cursor.clickSound = "soft-1"
        case "backgroundsAndFrame":
            doc.style.background = .wallpaper("aurora-1")
            doc.style.padding = 0.08
            doc.style.cornerRadius = 0.012
            doc.style.shadow = 0.6
            doc.style.frame = .macWindow(appearance: .dark, title: "Toma", buttons: true)
        case "cameraChanges":
            // The two changes the take recorded, at 1 and 1.1 s, and one of the user's at 2.0 s, after them: a large
            // rounded square at the top left.
            guard doc.camera.changes.count == 2, doc.camera.changes.allSatisfy({ $0.t < source(2.0) }) else {
                throw TestSupportError.failed("\(name): the take's two camera changes before 2 s, not \(doc.camera.changes)")
            }
            doc.camera.changes.append(CameraChange(
                id: "k-00000003", take: take, t: source(2.0),
                style: CameraStyle(shape: .roundedSquare, size: 0.33, anchor: .topLeading), origin: .user))
        case "portraitBubble":
            guard hasCamera else { throw TestSupportError.failed("\(name): a take with a camera") }
            doc.aspect = .portrait
            doc.camera.initial[take] = CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .bottomTrailing)
        case "twoScreens":
            // The second screen shown from 1.5 s to the end (1b's "Show Screen" over that range), the screen's rect going
            // from one to the other with the spring.
            guard doc.screens.initial[take] == displayTrack, project.take.tracks.contains(where: { $0.id == secondDisplayTrack })
            else { throw TestSupportError.failed("\(name): two displays, the first shown first, not \(doc.screens)") }
            doc.screens.changes = [ScreenChange(id: "p-00000001", take: take, t: source(1.5), track: secondDisplayTrack, origin: .user)]
            doc.style.geometryTransition = .spring
        default:
            throw TestSupportError.missing("golden 1c case \(name)")
        }
        return doc
    }

    /// The output the frames of `document` are drawn at: its aspect with a short side of 720 px.
    public static func outputSize(of document: EditDocument) -> SIMD2<Int> {
        StageLayout.outputSize(aspect: document.aspect, shortSide: 720)
    }

    // MARK: - The takes

    /// A take of 4 s of the display, the microphone, the cursor moving over the display the whole time and a 4:3
    /// camera (its colours inverted, so it never looks like the screen) with the default style, the medium circle at the
    /// bottom right; with a left click at each of `clicks` (seconds from the take's start), where the cursor is then.
    private static func fourSecondTake(_ builder: TakeBuilder, clicks: [Double]) async throws -> LoadedProject {
        builder.cameraStyle = .default
        try await builder.addVideoTrack(
            id: displayTrack, source: displaySource(1, globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 4)])
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera"),
            segments: [VideoSegmentSpec(start: base, seconds: 4, width: 640, height: 480, transform: invertingColors)])
        try await builder.addAudioTrack(id: "mic", source: microphone, segments: [AudioSegmentSpec(start: base, seconds: 4)])
        try builder.addEvents([startGeometry(1, screenFrame)])
        try builder.addEvents(cursorEvents(from: base, seconds: 4, across: screenFrame))
        try builder.addEvents(clicks.flatMap { t -> [InputEvent] in
            let at = cursorPosition(at: t, seconds: 4, across: screenFrame)
            return [
                InputEvent(t: base.adding(seconds: t), kind: .mouseDown(.left, x: at.x, y: at.y)),
                InputEvent(t: base.adding(seconds: t + 0.08), kind: .mouseUp(.left, x: at.x, y: at.y)),
            ]
        })
        return try builder.write()
    }

    /// A take of 3 s of two displays side by side, the first 16:9 and the second 4:3 at its right (its colours
    /// inverted), and the microphone, with the cursor moving over the first for 1.5 s and over the second after: the
    /// first is shown first (`ScreenChoice`).
    private static func twoScreens(_ builder: TakeBuilder) async throws -> LoadedProject {
        let second = Rect(x: 640, y: 0, width: 800, height: 600)
        try await builder.addVideoTrack(
            id: displayTrack, source: displaySource(1, globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addVideoTrack(
            id: secondDisplayTrack, source: displaySource(2, globalFrame: second),
            segments: [VideoSegmentSpec(start: base, seconds: 3, width: 800, height: 600, transform: invertingColors)])
        try await builder.addAudioTrack(id: "mic", source: microphone, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        try builder.addEvents([startGeometry(1, screenFrame), startGeometry(2, second)])
        try builder.addEvents(cursorEvents(from: base, seconds: 1.5, across: screenFrame))
        try builder.addEvents(cursorEvents(from: base.adding(seconds: 1.5), seconds: 1.5, across: second))
        return try builder.write()
    }

    // MARK: - Shared values

    /// An arbitrary host time well after boot: where every case's segments start (`GoldenProjects`' too).
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static let displayTrack = "display-1"
    private static let secondDisplayTrack = "display-2"
    private static let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
    private static let microphone = TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic")

    private static func displaySource(_ displayID: UInt32, globalFrame: Rect) -> TrackSource {
        TrackSource(name: "Synthetic Display \(displayID)", displayID: displayID, globalFrame: globalFrame, pixelScale: 1)
    }

    /// The `displayGeometry` of display `displayID` that the coordinator logs as the take starts, just before its first
    /// segment.
    private static func startGeometry(_ displayID: UInt32, _ frame: Rect) -> InputEvent {
        InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: displayID, frame: frame, scale: 1))
    }

    /// `sample` with the red, green and blue of every pixel inverted (a `VideoSegmentSpec.transform`): the frame of the
    /// same number on another track, which has `SampleFactory`'s colours, never looks like it.
    @Sendable private static func invertingColors(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { preconditionFailure("GoldenDocuments: no image") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let pixels = CVPixelBufferGetBaseAddress(pixelBuffer) else { preconditionFailure("GoldenDocuments: no pixels") }
        let width = CVPixelBufferGetWidth(pixelBuffer), bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
            let row = pixels.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width { row[x] ^= 0x00FF_FFFF }  // BGRA bytes: B, G and R, not A
        }
        return sample
    }

    /// Where the cursor of `cursorEvents(from:seconds:across:)` is `t` seconds after its start.
    private static func cursorPosition(at t: Double, seconds: Double, across frame: Rect) -> SIMD2<Double> {
        let f = t / seconds
        return SIMD2(frame.x + frame.width * (0.2 + 0.6 * f), frame.y + frame.height * (0.3 + 0.4 * f))
    }

    /// Cursor samples every 1/120 s for `seconds` from `start`, moving across `frame` (as `GoldenProjects`' do).
    private static func cursorEvents(from start: HostTime, seconds: Double, across frame: Rect) -> [InputEvent] {
        (0..<Int(seconds * 120)).map { i in
            let at = cursorPosition(at: Double(i) / 120, seconds: seconds, across: frame)
            return InputEvent(t: start.adding(seconds: Double(i) / 120), kind: .cursor(x: at.x, y: at.y))
        }
    }
}
