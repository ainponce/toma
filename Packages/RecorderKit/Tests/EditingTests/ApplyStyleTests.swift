// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import Foundation
import ImageIO
import RecorderKitTestSupport
import Synchronization
import Testing
import UniformTypeIdentifiers
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share, namespaced so that no other file of EditingTests meets its names.
private enum ApplyFixture {
    static let takeID = "take-001"
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static let app = AppInfo(name: "Toma", version: "0.3.0")

    /// 30 s of one display, a camera and a microphone.
    static let take = TakeRecord(
        id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base,
                        endHostTime: base.adding(seconds: 30), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ]),
            TrackRecord(id: "camera-1", kind: .camera, source: TrackSource(name: "Camera"), segments: []),
            TrackRecord(id: "mic", kind: .microphone, source: TrackSource(name: "Microphone"), segments: []),
        ],
        cameraStyle: .default)

    /// A change of the bubble while recording, at 4 s, and a click in the middle of the display at 10 s.
    static let events = [
        InputEvent(t: base.adding(seconds: 4), kind: .cameraStyle(CameraStyle(shape: .portrait, size: CameraStyle.large, anchor: .top))),
        InputEvent(t: base.adding(seconds: 10), kind: .mouseDown(.left, x: 720, y: 450)),
        InputEvent(t: base.adding(seconds: 10.05), kind: .mouseUp(.left, x: 720, y: 450)),
    ]

    /// A project of 1b: the camera of its take, not mirrored, measured against the output's height.
    static let legacy = EditDocument.legacy(take: take, events: events)

    /// A look unlike the legacy document's and unlike Toma's.
    static var look: DefaultStyle {
        var look = DefaultStyle.toma
        look.style.background = .wallpaper("dune-1")
        look.style.padding = 0.1
        look.style.cornerRadius = 0.03
        look.style.shadow = 0.4
        look.cursor.scale = 2
        look.cursor.clickEffect = "none"
        look.zoomAuto.depth = 2.5
        look.zoomSpring = SpringSpec(damping: 0.9, response: 0.5)
        look.zoomMotionBlur = 0.2
        return look
    }

    /// A camera unlike a new project's and unlike the legacy one.
    static let camera = CameraLook(
        mirror: true, border: CameraBorder(width: 0.5, color: RGBA(0, 0, 0, 1)), shadow: 0.7,
        layout: CameraLayout(kind: .split, split: SplitLayout(side: .start, share: 0.4)), sizeReference: .shortSide)

    static func style(id: String = "0a1b2c3d", name: String = "Tutoriales", look: DefaultStyle = look, camera: CameraLook = camera)
        -> NamedStyle
    {
        NamedStyle(id: id, name: name, look: look, camera: camera)
    }

    static func apply(_ style: NamedStyle, to document: EditDocument) -> EditStep? {
        StyleCommands.applyStyle(document, style, take: take, events: events)
    }

    // MARK: Sessions

    static func context(caches: URL, cameraLook: CameraLook = .newProjects) -> EditContext {
        let count = Mutex(0)
        let clock = Mutex(Date(timeIntervalSince1970: 1_794_773_523))
        return EditContext(
            app: app, cachesRoot: caches, defaultStyle: .toma,
            now: {
                // Every read 2 s later: each step is a group of its own.
                clock.withLock { date in
                    defer { date += 2 }
                    return date
                }
            },
            makeID: { prefix in
                count.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            },
            cameraLook: cameraLook)
    }

    /// A take of 1 s of one display with a click at 0.5 s, in a new package `<name>.toma` never opened. Written off the
    /// main actor, where the tests' sessions live.
    @concurrent static func package(in dir: URL, name: String) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        try builder.addEvents([
            InputEvent(t: base.adding(seconds: 0.5), kind: .mouseDown(.left, x: 320, y: 180)),
            InputEvent(t: base.adding(seconds: 0.55), kind: .mouseUp(.left, x: 320, y: 180)),
        ])
        return try builder.write()
    }

    /// The library `<dir>/Styles`, with a trash that records an issue: nothing here is ever deleted.
    static func library(in dir: URL) -> StyleLibrary {
        StyleLibrary(directory: dir.appending(path: "Styles", directoryHint: .isDirectory)) { url in
            Issue.record("trashed \(url.path)")
        }
    }

    /// A 32 × 32 PNG, filled.
    static func png() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TestSupportError.failed("no context") }
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage() else { throw TestSupportError.failed("no image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw TestSupportError.failed("no destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestSupportError.failed("no PNG") }
        return data as Data
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@Test func applyingIsOneStepThatCopiesValues() throws {
    let document = ApplyFixture.legacy
    let style = ApplyFixture.style()
    let step = try #require(ApplyFixture.apply(style, to: document))
    #expect(step.label == .styleApply)
    let edited = try document.applying(step.changes)

    // What "Apply Default Style" sets: the stage, with mipmapped sampling and the spring between shapes; the cursor, drawn
    // as Toma's arrow (the take recorded no images); the zoom's settings, and the automatic blocks planned again.
    var stage = style.look.style
    stage.screenSampling = .mipmapped
    stage.geometryTransition = .spring
    #expect(edited.style == stage)
    var cursor = style.look.cursor
    cursor.style = .toma
    #expect(edited.cursor == cursor)
    #expect(edited.zoom.show == style.look.zoomShow)
    #expect(edited.zoom.auto == style.look.zoomAuto)
    #expect(edited.zoom.spring == style.look.zoomSpring)
    #expect(edited.zoom.motionBlur == style.look.zoomMotionBlur)
    var unplanned = edited
    unplanned.zoom.regions = []
    let planned = AutoZoomPlanner.plan(take: ApplyFixture.take, events: ApplyFixture.events, document: unplanned)
    #expect(planned.count == 1)
    #expect(edited.zoom.regions == planned)
    // And the camera's look: mirror, border, shadow, the project's layout with its split, and the size's reference.
    #expect(edited.camera.mirror)
    #expect(edited.camera.border == ApplyFixture.camera.border)
    #expect(edited.camera.shadow == 0.7)
    #expect(edited.camera.layout == CameraLayout(kind: .split, split: SplitLayout(side: .start, share: 0.4)))
    #expect(edited.camera.sizeReference == .shortSide)
    #expect(edited.camera == ApplyFixture.camera.applied(to: document.camera))

    // One step: undoing it gives back the whole document.
    #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
    // Applied again, nothing changes.
    #expect(ApplyFixture.apply(style, to: edited) == nil)
    // A style whose only difference is its camera is still a step, of the camera alone.
    var mirrorless = ApplyFixture.camera
    mirrorless.mirror = false
    let camera = try #require(ApplyFixture.apply(ApplyFixture.style(camera: mirrorless), to: edited))
    #expect(camera.label == .styleApply)
    #expect(camera.changes == [try #require(edited.setChange("/camera/mirror", false))])
}

@Test func neverTouchesBlocksFormatOrBubble() throws {
    var document = ApplyFixture.legacy
    document.aspect = .portrait
    document.frameRate = 30
    // A bubble of the user's at the start, the take's change at 4 s, the camera hidden, the microphone at half.
    document.camera.initial[ApplyFixture.takeID] = CameraStyle(shape: .roundedSquare, size: CameraStyle.small, anchor: .topLeading)
    document.camera.show = false
    document.camera.spring = SpringSpec(damping: 0.8, response: 0.4)
    document.audio.tracks["take-001/mic"] = TrackGain(gain: 0.5, muted: false)
    #expect(document.camera.changes.count == 1)
    // Blocks of every kind that has settings.
    document.camera.layouts = [
        LayoutBlock(
            id: "l-00000001", take: ApplyFixture.takeID, start: ApplyFixture.base.adding(seconds: 2),
            end: ApplyFixture.base.adding(seconds: 5), kind: .cameraFull, instant: false),
        LayoutBlock(
            id: "l-00000002", take: ApplyFixture.takeID, start: ApplyFixture.base.adding(seconds: 12),
            end: ApplyFixture.base.adding(seconds: 15), kind: .split, instant: true,
            bubble: BubbleLayout(style: CameraStyle(shape: .circle, size: CameraStyle.large, anchor: .bottomLeading)),
            split: SplitLayout(side: .end, share: 0.3)),
        LayoutBlock(
            id: "l-00000003", take: ApplyFixture.takeID, start: ApplyFixture.base.adding(seconds: 20),
            end: ApplyFixture.base.adding(seconds: 22), kind: .bubble, instant: false,
            bubble: BubbleLayout(style: CameraStyle(shape: .portrait, size: CameraStyle.medium, anchor: .top))),
    ]
    let step = try #require(ApplyFixture.apply(ApplyFixture.style(), to: document))
    // Only the stage, the cursor, the zoom's settings and blocks, and the five values of the camera's look.
    let allowed = ["/style", "/cursor", "/zoom/show", "/zoom/auto", "/zoom/spring", "/zoom/motionBlur", "/zoom/regions",
        "/camera/mirror", "/camera/border", "/camera/shadow", "/camera/layout", "/camera/sizeReference"]
    for change in step.changes {
        let path = switch change {
        case let .set(path, _, _): path.string
        case let .insert(collection, _, _), let .remove(collection, _, _), let .replace(collection, _, _, _): collection.string
        }
        #expect(allowed.contains { path == $0 || path.hasPrefix($0 + "/") }, "\(path)")
    }
    let edited = try document.applying(step.changes)
    #expect(edited.camera.layouts == document.camera.layouts)
    #expect(edited.camera.initial == document.camera.initial)
    #expect(edited.camera.changes == document.camera.changes)
    #expect(edited.camera.show == document.camera.show)
    #expect(edited.camera.spring == document.camera.spring)
    #expect(edited.camera.layoutRules == document.camera.layoutRules)
    #expect(edited.aspect == .portrait)
    #expect(edited.frameRate == 30)
    #expect(edited.audio == document.audio)
    #expect(edited.sequence == document.sequence)
    #expect(edited.screens == document.screens)
    #expect(edited.zoom.suppressed == document.zoom.suppressed)
    #expect(edited.camera == ApplyFixture.camera.applied(to: document.camera))
}

@Test func applySetsTheStylesSizeReference() throws {
    // A project of 1b, measured against the height, takes the style's short side.
    let document = ApplyFixture.legacy
    #expect(document.camera.sizeReference == .height)
    let shortSide = try document.applying(try #require(ApplyFixture.apply(ApplyFixture.style(), to: document)).changes)
    #expect(shortSide.camera.sizeReference == .shortSide)

    // A style that keeps the height (one imported as it was), on a project measured against the short side: the height.
    var height = ApplyFixture.camera
    height.sizeReference = .height
    let step = try #require(ApplyFixture.apply(ApplyFixture.style(camera: height), to: shortSide))
    #expect(step.changes == [try #require(shortSide.setChange("/camera/sizeReference", SizeReference.height))])
    #expect(try shortSide.applying(step.changes).camera.sizeReference == .height)
}

@MainActor @Test func missingImageKeepsTheBackground() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        // A style saved from a project with an image of its own.
        let source = try await ApplyFixture.package(in: dir, name: "Source")
        let png = try ApplyFixture.png()
        let picked = dir.appending(path: "Background.png")
        try png.write(to: picked)
        let file = try AssetImport.copy(picked, into: source.package)
        var look = ApplyFixture.look
        look.style.background = .image(file: file)
        let library = ApplyFixture.library(in: dir)
        try await library.save(ApplyFixture.style(look: look), imageFrom: source.package)
        let style = try #require(library.list().first)
        #expect(style.look.style.background == .image(file: file))
        let images = library.imageDirectory(of: style)

        // With its image: brought into the project, named by the step, in one undo.
        let project = try await ApplyFixture.package(in: dir, name: "With")
        let session = try await EditSession.open(project.package.url, take: nil, context: ApplyFixture.context(caches: caches))
        let before = session.document
        let applied = await session.applyStyle(style, imageDirectory: images)
        #expect(applied.outcome == .applied)
        #expect(!applied.imageMissing)
        // The `create`, the two `migrate`s of the first edit and its step.
        #expect(await session.flushed() == 4)
        #expect(session.document.style.background == .image(file: file))
        #expect(try Data(contentsOf: project.package.fileURL(file)) == png)
        #expect(session.document.style.padding == 0.1)
        #expect(session.document.camera == style.camera.applied(to: before.camera))
        #expect(session.undoLabel == .styleApply)
        #expect(session.undo() == .applied)
        var undone = session.document
        undone.logSequence = before.logSequence
        #expect(undone == before)
        await session.close()

        // Without it (gone from the style's package, or without the folder): the rest is applied, and the background
        // stays as it was.
        try FileManager.default.removeItem(at: images.appending(path: String(file.dropFirst("assets/".count))))
        for (index, folder) in [images, nil].enumerated() {
            let other = try await ApplyFixture.package(in: dir, name: "Without \(index)")
            let session = try await EditSession.open(other.package.url, take: nil, context: ApplyFixture.context(caches: caches))
            let before = session.document
            let result = await session.applyStyle(style, imageDirectory: folder)
            #expect(result.outcome == .applied)
            #expect(result.imageMissing)
            #expect(session.document.style.background == before.style.background)
            #expect(session.document.style.padding == 0.1)
            #expect(session.document.style.cornerRadius == 0.03)
            #expect(session.document.cursor.scale == 2)
            #expect(session.document.zoom.auto.depth == 2.5)
            #expect(session.document.camera == style.camera.applied(to: before.camera))
            #expect(session.undoLabel == .styleApply)
            #expect(await session.flushed() == 4)
            #expect(!ApplyFixture.exists(other.package.assetsURL))
            await session.close()
        }

        // A project that cannot be edited is left alone, the image not looked for.
        let closed = try await EditSession.open(project.package.url, take: nil, context: ApplyFixture.context(caches: caches))
        await closed.close()
        let refused = await closed.applyStyle(style, imageDirectory: images)
        #expect(refused.outcome == .refused)
        #expect(!refused.imageMissing)
    }
}

@Test func matchFindsNamedTomaOrCustom() async throws {
    try await withTemporaryDirectory { dir in
        // A project of 1b is none of them.
        let legacy = ApplyFixture.legacy
        let style = ApplyFixture.style()
        var other = ApplyFixture.style(id: "11111111", name: "Otro")
        other.look.style.padding = 0.2
        #expect(StyleCommands.matchingStyle(legacy, among: [style, other]) == .custom)

        // Just applied: that style, whatever the zoom blocks and the cursor's drawing (they come from the take).
        let applied = try legacy.applying(try #require(ApplyFixture.apply(style, to: legacy)).changes)
        #expect(StyleCommands.matchingStyle(applied, among: [other, style]) == .named(style.id))
        #expect(StyleCommands.matchingStyle(applied, among: [other]) == .custom)
        #expect(StyleCommands.matchingStyle(applied, among: []) == .custom)
        var noZooms = applied
        noZooms.zoom.regions = []
        noZooms.cursor.style = .system
        #expect(StyleCommands.matchingStyle(noZooms, among: [style]) == .named(style.id))

        // A new project in Toma's style is Toma's; a saved style just like Toma's is named first.
        let project = try await ApplyFixture.package(in: dir, name: "New")
        let new = NewDocument.make(project: project, defaultStyle: .toma, makeID: { $0 + "00000001" })
        #expect(StyleCommands.matchingStyle(new, among: [style, other]) == .toma)
        let likeToma = NamedStyle(id: "22222222", name: "Como Toma", look: .toma, camera: .newProjects)
        #expect(StyleCommands.matchingStyle(new, among: [style, likeToma]) == .named(likeToma.id))
        // Toma's look on the camera of a project of 1b is not Toma's style.
        var oldCamera = new
        oldCamera.camera = legacy.camera
        #expect(StyleCommands.matchingStyle(oldCamera, among: [style]) == .custom)

        // Touching the padding: custom.
        let padded = try applied.applying(try #require(StyleCommands.set(applied, "/style/padding", 0.11, label: .padding)).changes)
        #expect(StyleCommands.matchingStyle(padded, among: [style]) == .custom)
        let touched = try new.applying(try #require(StyleCommands.set(new, "/style/padding", 0.11, label: .padding)).changes)
        #expect(StyleCommands.matchingStyle(touched, among: [style]) == .custom)
        // And the camera's look too.
        let unmirrored = try applied.applying(try #require(CameraLookCommands.setMirror(applied, false)).changes)
        #expect(StyleCommands.matchingStyle(unmirrored, among: [style]) == .custom)
    }
}

@MainActor @Test func newProjectsTakeTheCameraLookOfTheirStyle() async throws {
    try await withTemporaryDirectory { dir in
        let caches = dir.appending(path: "Caches")
        #expect(ApplyFixture.context(caches: caches).cameraLook == .newProjects)
        let look = CameraLook(
            mirror: false, border: CameraBorder(width: 0.25, color: RGBA(0, 0, 0, 1)), shadow: 0,
            layout: CameraLayout(kind: .screenOnly), sizeReference: .shortSide)
        let context = ApplyFixture.context(caches: caches, cameraLook: look)

        // Read without opening, and opened: the new document of a version 3 project has the style's camera.
        let project = try await ApplyFixture.package(in: dir, name: "New")
        let legacy = EditDocument.legacy(for: project)
        let (_, read) = try EditSession.readDocument(project.package.url, take: nil, context: context)
        #expect(read.camera == look.applied(to: legacy.camera))
        #expect(!read.camera.mirror)
        #expect(read.camera.shadow == 0)
        let session = try await EditSession.open(project.package.url, take: nil, context: context)
        #expect(session.document.camera == look.applied(to: legacy.camera))
        #expect(await session.flushed() == 1)
        await session.close()
        // Written so: opened with another look, it keeps the one it was made with.
        let again = try await EditSession.open(project.package.url, take: nil, context: ApplyFixture.context(caches: caches))
        #expect(again.document.camera == look.applied(to: legacy.camera))
        await again.close()

        // Without a look of its own, a new project's.
        let other = try await ApplyFixture.package(in: dir, name: "Other")
        let plain = try await EditSession.open(other.package.url, take: nil, context: ApplyFixture.context(caches: caches))
        #expect(plain.document.camera == CameraLook.newProjects.applied(to: EditDocument.legacy(for: other).camera))
        await plain.close()
    }
}
