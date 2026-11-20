// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat
import Recording

/// The documents of the golden files of milestone 1c (plan 1c decision 2), of phase 2 ("golden 2", phase 2 design §14)
/// and of phase 3 ("golden 3", phase 3 design §16).
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
/// `v3Cases` are edit documents of phase 2 (`documentVersion` 3) with what phase 2 brought that needs no model of the
/// system (no person's mask, no face, no cleanup by AUSoundIsolation, no scan by Vision): captions of a transcription
/// made here (`spokenWords`), manual privacy blocks, the keys on screen of synthetic key presses, a device frame, a look,
/// a manual framing and a sync offset of the camera, Follow the Cursor, the new formats (4:5 and like the recording) and
/// Normalize. Golden 3 holds the frames (`golden3FramesMatch`) and mix (`golden3MixMatches`) of all three
/// (`golden3Cases`), recorded from the branch `golden-3-base` (`main` with only test code and the `Makefile` changed), so
/// that every change of phase 3 can show that such documents still draw and sound the same, once migrated. They are
/// drawn small (`Case.shortSide` 360) so the golden frames do not double, and those whose look is of the picture
/// (privacy, device, camera, reframe, formats) over a checkered screen and camera, which shows it.
///
/// Each case's take is written by `TakeBuilder` (`makeProject`), the same way on every run, with its video by the
/// hardware encoder alone (`GoldenProjects.goldenFramesEncoder`), as a package of format version 3 (4 for a take with
/// key presses, `Case.formatVersion`). Its document is recorded with the golden files (`documents/<case>.json`, as the
/// app writes `edit.json`: 1b's in `documentVersion` 1, 1c's in 2, phase 2's in 3): `makeDocument`, which builds it from
/// `EditDocument.legacy(for:)` by changing its fields as the editor of the case's milestone would have (this target does
/// not see the commands of `Editing`, and so it compiles the same with later code; `GoldenDocumentsTests` checks that
/// 1c's commands give the same documents), is used only when recording; a comparison reads the recorded file. Its frames
/// are drawn at `outputSize(of:document:project:)` at its `times`, all shorter than its output. Changing a case, or the
/// order of `cases`, `v2Cases` or `v3Cases`, changes the golden files: never do it once they are recorded.
public enum GoldenDocuments {
    public struct Case: Sendable {
        public var name: String
        /// Output times its frames are drawn at, in order.
        public var times: [Double]
        /// Whether its mix is in the golden mix.
        public var mixes: Bool
        /// The `documentVersion` its document is recorded in: 1 for 1b's (`cases`), 2 for 1c's (`v2Cases`), 3 for phase
        /// 2's (`v3Cases`).
        public var documentVersion: Int = 1
        /// The format version of its package (`makeProject`): 3, or 4 for a take with key presses.
        public var formatVersion: Int = 3
        /// The shorter side of the output its frames are drawn at, in pixels (`outputSize(of:document:project:)`): 720 for
        /// the cases of golden 2, 360 for those of phase 2.
        public var shortSide: Int = 720
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

    /// The documents of phase 2 (`documentVersion` 3), in the order of their frames and mix in golden 3, after
    /// `golden2Cases`; drawn at 360 px on the shorter side. Each one's times and details are in `makeDocument`.
    public static let v3Cases: [Case] = [
        Case(name: "captionsBold", times: [0.5, 1.1, 2.0, 3.0], mixes: true, documentVersion: 3, shortSide: 360),
        Case(name: "captionsClassicTop", times: [1.5, 3.3], mixes: false, documentVersion: 3, shortSide: 360),
        Case(name: "privacyManual", times: [0.7, 2.0, 3.2], mixes: false, documentVersion: 3, shortSide: 360),
        Case(name: "keysOnScreen", times: [1.1, 2.5, 3.5], mixes: true, documentVersion: 3, formatVersion: 4, shortSide: 360),
        Case(name: "deviceFrameIPhone", times: [0.8, 2.6], mixes: false, documentVersion: 3, shortSide: 360),
        Case(name: "cameraLookWarm", times: [1.0, 2.5], mixes: true, documentVersion: 3, shortSide: 360),
        Case(name: "followCursorPortrait", times: [1.0, 2.0, 3.0], mixes: false, documentVersion: 3, shortSide: 360),
        Case(name: "fourByFive", times: [1.5], mixes: false, documentVersion: 3, shortSide: 360),
        Case(name: "likeTheRecording", times: [2.0], mixes: false, documentVersion: 3, shortSide: 360),
        // No frames: Normalize changes only the sound.
        Case(name: "normalizedMix", times: [], mixes: true, documentVersion: 3, shortSide: 360),
    ]

    /// The cases of golden 3, in the order of their frames and mix: those of golden 2 (`golden2Cases`), then phase 2's
    /// (`v3Cases`).
    public static let golden3Cases: [Case] = golden2Cases + v3Cases

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
    /// Every package is of format version 3 but `keysOnScreen`'s, of 4 as the recorder writes a take with key presses
    /// (`Case.formatVersion`), and its video is written by the hardware encoder alone
    /// (`GoldenProjects.goldenFramesEncoder`), so the frames drawn from it are the golden ones.
    /// - Throws: `TestSupportError.missing` for a name that is not a case, or what writing the take throws.
    public static func makeProject(_ name: String, in dir: URL) async throws -> LoadedProject {
        func builder(formatVersion: Int = 3) throws -> TakeBuilder {
            let builder = try TakeBuilder(in: dir, name: name, formatVersion: formatVersion)
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
        case "captionsBold", "captionsClassicTop": return try await fourSecondTake(try builder(), clicks: [])
        case "privacyManual", "deviceFrameIPhone", "cameraLookWarm", "followCursorPortrait", "fourByFive":
            // Checkered, so a blur, a pixelate, a crop that moves or a framing shows in the frames.
            return try await fourSecondTake(try builder(), clicks: [], checkered: true)
        case "keysOnScreen": return try await fourSecondTake(try builder(formatVersion: 4), clicks: [], keys: keyPresses)
        case "likeTheRecording":
            // A display of 4:3, so the output takes its proportion and not 16:9.
            return try await fourSecondTake(
                try builder(), clicks: [], screen: Rect(x: 0, y: 0, width: 640, height: 480), checkered: true)
        case "normalizedMix":
            // A quiet microphone (−29 LUFS or so, which Normalize brings up to −16) and loud stereo system audio (−11 LUFS
            // or so, brought down to −20).
            return try await fourSecondTake(
                try builder(), clicks: [], microphoneAmplitude: 0.05,
                systemAudio: AudioSegmentSpec(start: base, seconds: 4, channels: 2, frequency: 660, amplitude: 0.3))
        default: throw TestSupportError.missing("golden case \(name)")
        }
    }

    /// The document of case `name` for `project` (its `makeProject`): `EditDocument.legacy(for:)` with the fields of the
    /// case changed as the editor of its milestone would have changed them (1b's for `cases`, 1c's for `v2Cases`, phase
    /// 2's for `v3Cases`), ids of its own fixed (`c-`, `z-`, `k-`, `p-` and `l-`, then 8 hex) so it is the same on every
    /// run. Its times are output times of the legacy document, which shows the take from its timeline start at 1×. It is
    /// of `EditDocument.currentVersion`: a case of `cases` is recorded reverted to version 1, one of `v2Cases` to 2
    /// (`DocumentMigration.reverted(_:to:)`), as 1b and 1c wrote them.
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
        case "captionsBold":
            // The microphone transcribed (`spokenWords`: two captions, as the gap of 0.8 s after "screen," starts the
            // second) and the captions shown in the default style: Bold, medium, at the bottom, as written, the word being
            // said in yellow. At 0.5 s "Toma" is said; at 1.1 s, the instant "your" starts, the highlight has just moved
            // from "records" to it; at 2.0 s the first caption is still on (0.3 s after its last word), "screen," said; at
            // 3.0 s the second, "camera" said.
            guard project.take.track(microphoneTrack) != nil else { throw TestSupportError.failed("\(name): a take with a microphone") }
            doc.transcript = spokenTranscript(take: take, at: source)
            doc.captions = CaptionPlan(show: true, style: .default)
        case "captionsClassicTop":
            // The same transcription, the captions Classic (the dark box behind the text), at the top, in capitals, large,
            // without the highlight; at 1.5 s the first caption, at 3.3 s the second.
            guard project.take.track(microphoneTrack) != nil else { throw TestSupportError.failed("\(name): a take with a microphone") }
            doc.transcript = spokenTranscript(take: take, at: source)
            doc.captions = CaptionPlan(show: true, style: CaptionStyle(
                preset: .classic, size: .large, position: .top, uppercase: true, highlight: false,
                highlightColor: CaptionStyle.default.highlightColor))
        case "privacyManual":
            // Three blocks drawn by hand over the checkered screen: a blur at the top left over [0.2, 3.6) s (strength
            // 0.6), a pixelate at the top right over [0.5, 3.0) s (strength 0.8), and a fill, dark violet, over [0, 3.8) s
            // that moves with its keys from the bottom left at 1.0 s to the bottom right at 3.0 s (held before and after). At 0.7 s all
            // three, the fill still; at 2.0 s the fill halfway; at 3.2 s the pixelate gone and the fill at its last key.
            let start = NormalizedRect(x: 0.08, y: 0.6, width: 0.26, height: 0.24)
            let end = NormalizedRect(x: 0.62, y: 0.66, width: 0.3, height: 0.2)
            doc.privacy = PrivacyPlan(blocks: [
                PrivacyBlock(
                    id: "p-00000001", take: take, start: source(0.2), end: source(3.6), effect: .blur, strength: 0.6,
                    rect: NormalizedRect(x: 0.06, y: 0.08, width: 0.34, height: 0.26)),
                PrivacyBlock(
                    id: "p-00000002", take: take, start: source(0.5), end: source(3.0), effect: .pixelate, strength: 0.8,
                    rect: NormalizedRect(x: 0.58, y: 0.1, width: 0.32, height: 0.3)),
                PrivacyBlock(
                    id: "p-00000003", take: take, start: source(0), end: source(3.8), effect: .fill,
                    color: RGBA(0.16, 0.1, 0.28, 1), rect: start,
                    keys: [RectKey(t: source(1.0), rect: start), RectKey(t: source(3.0), rect: end)]),
            ])
        case "keysOnScreen":
            // The keys of the take (`keyPresses`) shown, every one (`.all`), at the bottom in the middle, medium: at 1.1 s
            // the pill of "hello", at 2.5 s the shortcut ⌘⇧4, at 3.5 s what "ok" and ↩ leave.
            guard project.events.contains(where: \.kind.requiresFormatVersion4) else {
                throw TestSupportError.failed("\(name): a take with key presses")
            }
            doc.keys = KeyOverlayPlan(mode: .all, position: .bottomCenter, size: .medium)
        case "deviceFrameIPhone":
            // The screen in a dark iPhone, with the stage's shadow at 0.5; at 0.8 and 2.6 s.
            doc.style.frame = .device(DeviceFrame(model: .iPhone, finish: .dark))
            doc.style.shadow = 0.5
        case "cameraLookWarm":
            // The camera as a large rounded square at the bottom right, so the look shows, with the Warm look at 0.8, framed
            // by hand (its centre at (0.4, 0.45) of the picture, zoomed 1.4×) and drawn 40 ms late against the sound (the
            // frame of 40 ms before); at 1.0 and 2.5 s.
            guard hasCamera else { throw TestSupportError.failed("\(name): a take with a camera") }
            doc.camera.initial[take] = CameraStyle(shape: .roundedSquare, size: CameraStyle.large, anchor: .bottomTrailing)
            doc.camera.look = CameraColor(preset: .warm, lut: nil, intensity: 0.8)
            doc.camera.framing = CameraFraming(mode: .manual, center: NormalizedPoint(x: 0.4, y: 0.45), zoom: 1.4)
            doc.camera.syncOffset = 40_000_000
        case "followCursorPortrait":
            // 9:16 with Follow the Cursor: the 16:9 screen shown in a part as wide as the output that follows the cursor,
            // which crosses the screen from left to right all along; at 1.0, 2.0 and 3.0 s.
            doc.aspect = .portrait
            doc.style.reframe = .followCursor
        case "fourByFive":
            doc.aspect = .fourByFive
        case "likeTheRecording":
            // Like the recording: the 4:3 display gives an output of 4:3.
            guard let ratio = StageLayout.contentRatio(take: project.take, document: doc, events: project.events),
                  abs(ratio - 4.0 / 3) < 1e-9
            else { throw TestSupportError.failed("\(name): a take of a 4:3 display") }
            doc.aspect = .auto
        case "normalizedMix":
            // Normalize on: each audio track brought to its target loudness by its measure (`loudness-1`), and the limiter
            // on with it.
            guard project.take.tracks.contains(where: { $0.kind == .systemAudio }) else {
                throw TestSupportError.failed("\(name): a take with system audio")
            }
            doc.audio.normalize = true
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

    /// The output the frames of `document`, of case `golden` for `project`, are drawn at: its aspect with a short side of
    /// `golden.shortSide` px, like the recording (`Aspect.auto`) from the take's screen, as the export sheet makes it. For
    /// the cases of golden 2, `outputSize(of:)`.
    public static func outputSize(of golden: Case, document: EditDocument, project: LoadedProject) -> SIMD2<Int> {
        StageLayout.outputSize(
            aspect: document.aspect, shortSide: golden.shortSide,
            contentRatio: StageLayout.contentRatio(take: project.take, document: document, events: project.events))
    }

    // MARK: - The takes

    /// A take of 4 s of the display (`screen`, 16:9 unless given), the microphone (the sine at `microphoneAmplitude`), the
    /// cursor moving over the display the whole time and a 4:3 camera (its colours inverted, so it never looks like the
    /// screen) with the default style, the medium circle at the bottom right; with a left click at each of `clicks`
    /// (seconds from the take's start), where the cursor is then, the key presses `keys` (which need a package of format
    /// version 4), the display's and the camera's frames `checkered` (`invertingCheckers`) and, given its segment, stereo
    /// system audio after the microphone. With the defaults, the take of the cases of golden 2, whose bytes never change.
    private static func fourSecondTake(
        _ builder: TakeBuilder, clicks: [Double], screen: Rect = screenFrame, keys: [InputEvent] = [], checkered: Bool = false,
        microphoneAmplitude: Float = 0.25, systemAudio: AudioSegmentSpec? = nil
    ) async throws -> LoadedProject {
        builder.cameraStyle = .default
        try await builder.addVideoTrack(
            id: displayTrack, source: displaySource(1, globalFrame: screen),
            segments: [VideoSegmentSpec(
                start: base, seconds: 4, width: Int(screen.width), height: Int(screen.height),
                transform: checkered ? invertingCheckers : nil)])
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera"),
            segments: [VideoSegmentSpec(
                start: base, seconds: 4, width: 640, height: 480,
                transform: checkered ? { invertingCheckers($0, invertingColors($0, $1)) } : invertingColors)])
        try await builder.addAudioTrack(
            id: microphoneTrack, source: microphone,
            segments: [AudioSegmentSpec(start: base, seconds: 4, amplitude: microphoneAmplitude)])
        if let systemAudio {
            try await builder.addAudioTrack(
                id: "system-audio", kind: .systemAudio, source: TrackSource(name: "Synthetic System Audio", excludedBundleIDs: []),
                segments: [systemAudio])
        }
        try builder.addEvents([startGeometry(1, screen)])
        try builder.addEvents(cursorEvents(from: base, seconds: 4, across: screen))
        try builder.addEvents(clicks.flatMap { t -> [InputEvent] in
            let at = cursorPosition(at: t, seconds: 4, across: screen)
            return [
                InputEvent(t: base.adding(seconds: t), kind: .mouseDown(.left, x: at.x, y: at.y)),
                InputEvent(t: base.adding(seconds: t + 0.08), kind: .mouseUp(.left, x: at.x, y: at.y)),
            ]
        })
        try builder.addEvents(keys)
        return try builder.write()
    }

    /// The words the microphone of the 4 s take says, as a transcription made here gives them (seconds from the take's
    /// start, `[start, end)`): "Toma records your screen," then, 0.8 s later (a gap that starts a caption), "your camera
    /// and voice."
    public static let spokenWords: [(text: String, start: Double, end: Double)] = [
        ("Toma", 0.30, 0.62), ("records", 0.66, 1.05), ("your", 1.10, 1.28), ("screen,", 1.32, 1.80),
        ("your", 2.60, 2.80), ("camera", 2.84, 3.20), ("and", 3.24, 3.36), ("voice.", 3.40, 3.80),
    ]

    /// The transcription of `spokenWords` of the microphone of `take`, in American English by `speechTranscriber-1`, whose
    /// second `t` from the take's start is source time `source(t)`.
    private static func spokenTranscript(take: String, at source: (Double) -> HostTime) -> Transcript {
        Transcript(language: "en-US", engine: "speechTranscriber-1", takes: [TranscriptTake(
            take: take, track: microphoneTrack,
            words: spokenWords.map { TranscriptWord(start: source($0.start), end: source($0.end), text: $0.text) })])
    }

    /// The keys pressed in `keysOnScreen`'s take, as the recorder logs them (`keyPress`, with ⇧ ⌃ ⌥ ⌘ as the low 32 bits
    /// of `CGEventFlags`): "hello" typed from 0.40 s, ⌘⇧4 at 2.2 s (a shortcut with modifiers, which types "$" and whose
    /// key is "4"), then "ok" from 3.0 s and ↩ (which types nothing) at 3.3 s.
    private static let keyPresses: [InputEvent] = {
        let shift: UInt32 = 0x0002_0000, command: UInt32 = 0x0010_0000
        func press(_ t: Double, _ code: UInt16, _ chars: String?, mods: UInt32 = 0, key: String? = nil) -> InputEvent {
            InputEvent(
                t: base.adding(seconds: t), kind: .keyPress(code: code, chars: chars, mods: mods, isRepeat: false, key: key ?? chars))
        }
        return [
            press(0.40, 4, "h"), press(0.52, 14, "e"), press(0.64, 37, "l"), press(0.76, 37, "l"), press(0.88, 31, "o"),
            press(2.2, 21, "$", mods: command | shift, key: "4"),
            press(3.0, 31, "o"), press(3.12, 40, "k"), press(3.3, 36, nil),
        ]
    }()

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
    private static let microphoneTrack = "mic"
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

    /// `sample` with the red, green and blue of every other square of 40 × 40 px inverted, from the top left (a
    /// `VideoSegmentSpec.transform`): a checkerboard of the frame's colour and its inverse, which shows what a blur, a
    /// pixelate, a crop or a scale does to the picture.
    @Sendable private static func invertingCheckers(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { preconditionFailure("GoldenDocuments: no image") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let pixels = CVPixelBufferGetBaseAddress(pixelBuffer) else { preconditionFailure("GoldenDocuments: no pixels") }
        let width = CVPixelBufferGetWidth(pixelBuffer), bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
            let row = pixels.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width where (x / 40 + y / 40) % 2 == 1 { row[x] ^= 0x00FF_FFFF }  // BGRA bytes: B, G and R, not A
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
