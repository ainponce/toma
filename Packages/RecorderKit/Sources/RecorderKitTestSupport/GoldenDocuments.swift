// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import Recording

/// The documents of the golden files of milestone 1c (plan 1c decision 2) and of phase 2 ("golden 2", phase 2 design §14).
///
/// `cases` are edit documents of milestone 1b (`documentVersion` 1), with cuts, speed, a zoom with motion blur, the
/// cursor's spring, ripples and click sounds, a wallpaper with the macOS window frame, camera changes, a 9:16 bubble and
/// two screens, whose frames (`golden1cFramesMatch`) and mix (`golden1cMixMatches`) were recorded from the commit that
/// closes 1b on `main`, so that every change of 1c can show that such a document still draws and sounds the same, byte
/// for byte, once migrated. `v2Cases` are edit documents of milestone 1c (`documentVersion` 2) with what 1c brought: the
/// camera's layout blocks (Bubble with its own style, Split, Camera only, Camera full screen and Screen only, instant and
/// smooth), the split's side and share, the camera's mirror, border and shadow, `sizeReference`, a new project's look and
/// a named style applied. Golden 2 holds the frames (`golden2FramesMatch`) and mix (`golden2MixMatches`) of both
/// (`golden2Cases`), recorded from the branch `golden-2-base` (`main` with only test code and the `Makefile` changed),
/// so that every change of phase 2 can show that such documents still draw and sound the same, once migrated.
///
/// Each case's take is written by `TakeBuilder` (`makeProject`), the same way on every run, with its video by the
/// hardware encoder alone (`GoldenProjects.goldenFramesEncoder`), as a package of format version 3. Its document is
/// recorded with the golden files (`documents/<case>.json`, as the app writes `edit.json`: 1b's in `documentVersion` 1,
/// 1c's in 2): `makeDocument`, which builds it from `EditDocument.legacy(for:)` by changing its fields as the editor of
/// the case's milestone would have (this target does not see the commands of `Editing`, and so it compiles the same with
/// later code; `GoldenDocumentsTests` checks that 1c's commands give the same documents), is used only when recording; a
/// comparison reads the recorded file. Its frames are drawn at `outputSize(of:)` at its `times`, all shorter than its
/// output. Changing a case, or the order of `cases` or `v2Cases`, changes the golden files: never do it once they are
/// recorded.
public enum GoldenDocuments {
    public struct Case: Sendable {
        public var name: String
        /// Output times its frames are drawn at, in order.
        public var times: [Double]
        /// Whether its mix is in the golden mix.
        public var mixes: Bool
        /// The `documentVersion` its document is recorded in: 1 for 1b's (`cases`), 2 for 1c's (`v2Cases`).
        public var documentVersion: Int = 1
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

    /// The documents of 1c (`documentVersion` 2), in the order of their frames and mix in golden 2, after `cases`.
    public static let v2Cases: [Case] = [
        Case(name: "layoutBlocks", times: [0.6, 1.2, 1.55, 2.3, 2.9, 3.35], mixes: false, documentVersion: 2),
        Case(name: "portraitSplit", times: [1.0, 2.15, 2.8], mixes: true, documentVersion: 2),
        Case(name: "namedStyle", times: [1.0, 2.0], mixes: true, documentVersion: 2),
    ]

    /// The cases of golden 2, in the order of their frames and mix: 1b's (`cases`), then 1c's (`v2Cases`).
    public static let golden2Cases: [Case] = cases + v2Cases

    /// The look of the style `namedStyle` applies, as the user saved it: a gradient, the screen padded and rounded in a
    /// light macOS window, the cursor at 125 % with a spring, ripples and the soft click sound, and the automatic zoom off.
    public static let namedStyleLook = DefaultStyle(
        style: StageStyle(
            background: .gradient(start: RGBA(0.13, 0.11, 0.28, 1), end: RGBA(0.86, 0.42, 0.55, 1), angle: 135), backgroundBlur: 0,
            padding: 0.06, cornerRadius: 0.02, shadow: 0.5, frame: .macWindow(appearance: .light, title: "Toma", buttons: true),
            screenSampling: .mipmapped, geometryTransition: .spring),
        cursor: CursorStyle(
            show: true, style: .system, scale: 1.25, smoothing: .spring(SpringSpec(damping: 0.9, response: 0.2)), hideWhenIdle: false,
            idleDelay: 2, clickEffect: "ripple-1", clickSound: "soft-1", clickSoundGain: 0.8, motionBlur: 0.4),
        zoomShow: true,
        zoomAuto: AutoZoomSettings(
            enabled: false, triggers: .clicks, holdWhileTyping: true, depth: 2.0, groupGap: 2.5, leadIn: 0.5, leadOut: 1.0, follow: true,
            planner: "autoZoom-1"),
        zoomSpring: SpringSpec(damping: 1.0, response: 0.70),
        zoomMotionBlur: 0.5)

    /// The camera of the style `namedStyle` applies: mirrored, a turquoise border of 0.5 and a shadow of 0.5, the Bubble,
    /// measured against the output's short side (as every saved style is).
    public static let namedStyleCamera = CameraLook(
        mirror: true, border: CameraBorder(width: 0.5, color: RGBA(44 / 255, 177 / 255, 188 / 255, 1)), shadow: 0.5,
        layout: CameraLayout(kind: .bubble), sizeReference: .shortSide)

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
        case "cutsAndSpeed", "backgroundsAndFrame", "portraitBubble", "layoutBlocks", "portraitSplit":
            return try await fourSecondTake(try builder(), clicks: [])
        case "zoomWithBlur", "namedStyle": return try await fourSecondTake(try builder(), clicks: [0.7, 1.9])
        case "cameraChanges":
            return try await GoldenProjects.make(
                "cameraWithStyleChanges", in: dir, formatVersion: 3, videoEncoder: GoldenProjects.goldenFramesEncoder)
        case "twoScreens": return try await twoScreens(try builder())
        default: throw TestSupportError.missing("golden case \(name)")
        }
    }

    /// The document of case `name` for `project` (its `makeProject`): `EditDocument.legacy(for:)` with the fields of the
    /// case changed as the editor of its milestone would have changed them (1b's for `cases`, 1c's for `v2Cases`), ids of
    /// its own fixed (`c-`, `z-`, `k-`, `p-` and `l-`, then 8 hex) so it is the same on every run. Its times are output
    /// times of the legacy document, which shows the take from its timeline start at 1×. It is of
    /// `EditDocument.currentVersion`: a case of `cases` is recorded reverted to version 1
    /// (`DocumentMigration.reverted(_:to:)`), as 1b wrote it.
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
        case "layoutBlocks":
            // 1c's layouts over the project's Bubble, as the Camera track leaves them (`LayoutCommands`): a Split with its
            // first settings (the camera at the end, the automatic share) over [0.4, 1.4) s, with a zoom of the user's in
            // its card; right after it a Bubble with a style of its own, a large rounded square at the top left, to
            // 2.0 s; Camera only, instant, to 2.6 s; Camera full screen to 3.2 s; and Screen only to 3.8 s, where the
            // take's bubble comes back. Every block but the instant one blends with the camera's spring.
            guard hasCamera else { throw TestSupportError.failed("\(name): a take with a camera") }
            func block(_ n: Int, _ from: Double, _ to: Double, _ kind: LayoutKind, instant: Bool = false) -> LayoutBlock {
                LayoutBlock(id: "l-0000000\(n)", take: take, start: source(from), end: source(to), kind: kind, instant: instant)
            }
            var split = block(1, 0.4, 1.4, .split)
            split.split = SplitLayout(side: .end)
            var bubble = block(2, 1.4, 2.0, .bubble)
            bubble.bubble = BubbleLayout(style: CameraStyle(shape: .roundedSquare, size: CameraStyle.large, anchor: .topLeading))
            doc.camera.layouts = [
                split, bubble, block(3, 2.0, 2.6, .cameraOnly, instant: true), block(4, 2.6, 3.2, .cameraFull),
                block(5, 3.2, 3.8, .screenOnly),
            ]
            doc.zoom.regions = [ZoomRegion(
                id: "z-00000001", take: take, start: source(0.6), end: source(1.35), origin: .user, depth: 1.6,
                focus: .fixed(x: 0.3, y: 0.35), instant: false)]
        case "portraitSplit":
            // A project recorded in 1c as it first opens (`NewDocument` with Toma's style: its stage, its cursor drawn as
            // Toma's arrow, as the take has no cursor images, its zoom's settings, which plan no block without clicks;
            // the camera of a new project, mirrored with a shadow and measured against the output's short side; and the
            // limiter on), then made 9:16, with a Split for the project's layout, the camera first (above) with 0.4 of
            // the height, a violet border of 0.6 and the shadow at 0.7, and a Bubble block over [2, 3) s, which takes the
            // take's bubble then (the medium circle at the bottom right) as its own.
            guard hasCamera else { throw TestSupportError.failed("\(name): a take with a camera") }
            let look = DefaultStyle.toma
            doc.style = look.style
            doc.style.screenSampling = .mipmapped
            doc.style.geometryTransition = .spring
            doc.cursor = look.cursor
            doc.cursor.style = .toma
            doc.zoom = ZoomPlan(
                show: look.zoomShow, auto: look.zoomAuto, spring: look.zoomSpring, motionBlur: look.zoomMotionBlur, regions: [],
                suppressed: [])
            doc.camera = CameraLook.newProjects.applied(to: doc.camera)
            doc.audio.limiter = true
            doc.aspect = .portrait
            doc.camera.layout = CameraLayout(kind: .split, split: SplitLayout(side: .start, share: 0.4))
            doc.camera.border = CameraBorder(width: 0.6, color: RGBA(127 / 255, 90 / 255, 240 / 255, 1))
            doc.camera.shadow = 0.7
            let style = try unwrap(doc.camera.initial[take], "\(name): the take's bubble")
            doc.camera.layouts = [LayoutBlock(
                id: "l-00000001", take: take, start: source(2.0), end: source(3.0), kind: .bubble, instant: false,
                bubble: BubbleLayout(style: style))]
        case "namedStyle":
            // A project of 1b, migrated, made 1:1 and with a style the user saved applied (`StyleCommands.applyStyle` of
            // `namedStyleLook` and `namedStyleCamera`): the style's stage with mipmapped sampling and the spring between
            // shapes, its cursor drawn as Toma's arrow (the take has no cursor images), its zoom's settings (the automatic
            // zoom off, so no block is planned) and its camera's look.
            guard hasCamera else { throw TestSupportError.failed("\(name): a take with a camera") }
            doc.aspect = .square
            let look = namedStyleLook
            doc.style = look.style
            doc.style.screenSampling = .mipmapped
            doc.style.geometryTransition = .spring
            doc.cursor = look.cursor
            doc.cursor.style = .toma
            doc.zoom.show = look.zoomShow
            doc.zoom.auto = look.zoomAuto
            doc.zoom.spring = look.zoomSpring
            doc.zoom.motionBlur = look.zoomMotionBlur
            doc.camera = namedStyleCamera.applied(to: doc.camera)
        default:
            throw TestSupportError.missing("golden case \(name)")
        }
        return doc
    }

    /// The JSON the document `made` of case `golden` (its `makeDocument`) is recorded as, with `ProjectJSON.encoder()`,
    /// in the case's `documentVersion`: a document of `EditDocument.currentVersion` as the app writes `edit.json`, and one
    /// of an older version reverted to it (`DocumentMigration.reverted(_:to:)`), as 1b wrote it for a case of `cases`.
    /// - Throws: `TestSupportError.failed` if `made` cannot be written in that version.
    public static func recordedJSON(of made: EditDocument, for golden: Case) throws -> Data {
        guard golden.documentVersion != made.documentVersion else { return try ProjectJSON.encoder().encode(made) }
        guard let reverted = DocumentMigration.reverted(try JSONValue(encoding: made), to: golden.documentVersion) else {
            throw TestSupportError.failed("\(golden.name)'s document cannot be written in version \(golden.documentVersion)")
        }
        return try ProjectJSON.encoder().encode(reverted)
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
