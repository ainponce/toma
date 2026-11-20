// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import Synchronization

public enum RenderError: Error, Equatable {
    /// This Mac has no Metal device.
    case noMetalDevice
    /// The output size is not positive in both directions.
    case invalidOutputSize(SIMD2<Int>)
    /// A target to draw into is not the renderer's output size.
    case targetSizeMismatch(expected: SIMD2<Int>, actual: SIMD2<Int>)
    /// A target to draw into is not `.bgra8Unorm` (or a pixel buffer not 32BGRA).
    case unsupportedPixelFormat
    /// Metal could not make an object the renderer needs (named).
    case metalResourceUnavailable(String)
    /// A function is missing from the compiled shaders.
    case missingShaderFunction(String)
    /// A pixel buffer could not be used as a Metal texture (`CVReturn`), for example one not backed by an IOSurface.
    case textureCreationFailed(CVReturn)
    /// The GPU did not complete the frame.
    case gpuFailed(String)
    /// A frame was to be drawn without the frame of track `track` at source instant `sourceTime` that it shows, which
    /// was never decoded for it: drawing it would show no screen (or camera) where there is one.
    case frameNotDecoded(track: String, sourceTime: HostTime)
}

/// Renders frames of a take: the one drawing path behind the editor preview and the MP4 export.
///
/// A frame is a function of the project, its edit document and the output time alone (`FrameEvaluator`), drawn by
/// `Compositor` over the screen and camera frames that a `TrackFrameReader` of each track decodes for that time: of each
/// screen track only while it is shown (and both screens while a change of screen crossfades).
/// Every way to draw — `render(at:into:completion:)`, `render(at:into:)`, `renderBytes(at:)` and `PreviewRenderer` — draws
/// the frame `FrameEvaluator` gives through the same `draw` with the same decoded frames: `encode(at:into:commandBuffer:)`
/// decodes them as it draws, `render(at:into:completion:)` ahead of it (`FramePrefetcher`).
///
/// Use one renderer per consumer: the preview and an export each make their own. A renderer keeps one
/// decoder position per track it reads, so two consumers reading different times would keep sending
/// them back and forth, reopening a reader for nearly every frame.
///
/// A scene can show several takes of the package (phase 3 design §9, `FrameEvaluator.init(project:document:…)`): the
/// project's own and each other one its sequence shows, whose frames say which (`RenderFrame.take`). Every take's tracks
/// are read apart from the others', however alike their ids: the readers, the prefetchers that decode ahead, what a
/// frame was drawn with and the cursor images are by take and track (`TrackKey`), and the missing video is every take's.
///
/// What it draws is a scene (`FrameEvaluator`), which carries its output size: the renderer's own (`setScene(_:)`, the
/// one `init` makes, at the size given) for `encode(at:into:commandBuffer:)`, `render(at:into:)`, `renderBytes(at:)` and
/// `render(at:into:completion:)`, or any other one `encode(scene:at:into:commandBuffer:)` is given. Scenes of the same
/// project share the renderer's readers, so a scene of another size or revision (`makeScene(document:paths:outputSize:)`,
/// `FrameEvaluator.resized(to:)`) draws without opening any decoder again. What depends on the size (a blurred
/// background's or a wallpaper's texture, the window title's) is kept for each size, for the last two sizes drawn.
///
/// `render(at:into:completion:)` only queues the frame and returns: on queues of the renderer's, each track's frames are
/// decoded ahead (up to `FramePrefetcher.maxFrames`) along the grid of `frameRate` from the frame asked for, as the export
/// asks for them, and the frame is drawn once its own are; the completion comes when the GPU is done with it. A track
/// that a layout hid and a block border brings back starts decoding `FramePrefetcher.borderLookahead` (1 s of output)
/// before the border (`DecodeAhead`, 1c design §14.4). The frames asked for one after the other on that grid find theirs
/// decoded already; another one starts the reading ahead again from there.
///
/// Elsewhere, decoding is synchronous, on the caller's thread: the first frame read from each segment loads its track and decodes
/// from the keyframe before it, and so does every scrub (a step back, or a jump of 2 s or more). Reading forward frame
/// by frame only decodes the frames in between. So is a background image's: the first frame that shows it decodes it
/// (unless another renderer holds it already) and covers and blurs it, waiting for the GPU (`BackgroundImages`); the
/// frames after it reuse that. A blurred wallpaper is drawn and blurred the same way, once. A window frame's title is
/// drawn by CoreText the first time it is shown (`TitleTexture`), and reused the same way; under the zoom camera, again
/// at each step of √2 of the depth, so it stays sharp. So is a cursor's image: each of Toma's cursors is drawn, and
/// each image the take recorded read and uploaded, the first time a frame shows it (`CursorImages`), and reused. A
/// screen sampled with mipmaps (`ScreenLayer.mipmapped`) is not: every frame copies the part shown of its decoded frame
/// and makes its mipmaps on the GPU (`Compositor`). A sharp wallpaper is drawn by its shader, except under the zoom
/// camera's motion blur: there, its mesh gradient is drawn once into a texture of the output's size
/// (`BackgroundImages`, like a blurred one's) and each subsample reads it, rather than working it out again up to 16
/// times over the whole output.
///
/// Thread-safe: frames are encoded one at a time, and those of `render(at:into:completion:)` in the order asked for.
public final class FrameRenderer: @unchecked Sendable {
    /// The size of the renderer's scene, which `encode(at:into:commandBuffer:)` checks its target against.
    public var outputSize: SIMD2<Int> { scene.outputSize }
    /// The device everything is drawn with; a view showing the preview must use it too.
    public let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    /// The renderer's scene (`setScene(_:)`).
    private let current: Mutex<FrameEvaluator>
    /// Internal for phase 3's layers (`FrameRenderer+<Layer>.swift`), which read the package's assets.
    let package: ProjectPackage
    /// The project the scenes draw: its own take, and the package's other takes a scene's sequence shows.
    private let project: LoadedProject
    private var take: TakeRecord { project.take }
    /// Every take of the manifest, by id, with the project's own.
    private let takeRecords: [String: TakeRecord]
    /// The frames per second scenes are drawn at; the document's when `nil`.
    private let frameRateOverride: Int?
    /// Some camera track of the take has a segment that can be read (plan decision 40: one that is not empty nor
    /// unreadable and whose file is there, `LayoutTimeline.cameraReadable`), which every scene's layouts are given. What
    /// builds the paths of a scene (`MotionPaths(take:events:document:cameraReadable:)`) and draws over the preview reads
    /// it here, so they see the layouts the render draws.
    public let cameraReadable: Bool
    /// `cameraReadable` of every take of the package (the project's own's is `cameraReadable`), by id, as the scenes are
    /// given it: what builds the paths of a scene of several takes (`SequencePaths`) reads it here.
    public let cameraReadableByTake: [String: Bool]
    /// What every scene of the renderer reads of the project's analysis caches unless it is given its own
    /// (`makeScene(document:paths:outputSize:analysis:)`, phase 2 design §10): `.none` in phase 1.
    public let analysis: AnalysisInputs
    /// The reader of each track read so far, by take and track, made the first time a frame (or `missingVideo`) needs it.
    private let readers = Mutex<[TrackKey: TrackFrameReader]>([:])
    private let compositor: Compositor
    /// The textures of the frames' background images; used with `lock` held.
    let backgroundImages: BackgroundImages
    /// The textures of the frames' window titles, one store for each of the last two sizes drawn, the latest last; used
    /// with `lock` held.
    private var titleTextures: [(size: SIMD2<Int>, titles: TitleTexture)] = []
    /// The textures of the frames' cursors of the project's own take; used with `lock` held.
    private let cursorImages: CursorImages
    /// Those of each other take a frame showed, by id, made the first time (`cursorImages(of:)`); used with `lock` held.
    private var otherCursorImages: [String: CursorImages] = [:]
    /// What the camera's colour and background are drawn with: the LUTs, and the readers of the person's masks, which
    /// `videos(of:)` and `reader(for:)` add to the take's (phase 2 design §6.1 and §6.3).
    let cameraLook: CameraLookResources
    /// What phase 3's imported clips and annotations are drawn with (phase 3 design §5.1 and §5.4): their readers and
    /// images, which `videos(of:)`, `reader(for:)` and `draw` add to the take's (`FrameRenderer+<Layer>.swift`).
    let mediaResources: MediaClipResources
    let annotationResources: AnnotationResources
    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()
    /// The frames per second the renderer's scene is drawn at (the document's unless given): the motion blur's frame, and
    /// the grid along which `render(at:into:completion:)` decodes ahead.
    var frameRate: Int { scene.frameRate }
    /// Where `render(at:into:completion:)` evaluates and draws its frames, one at a time.
    private let renderQueue = DispatchQueue(label: "dev.toma.FrameRenderer", qos: .userInitiated)
    /// The last frame `render(at:into:completion:)` queued: the next one starts once it is drawn.
    private let lastQueued = Mutex<Task<Void, Never>?>(nil)
    /// What `render(at:into:completion:)` decodes ahead; used on `renderQueue`.
    private let ahead = Mutex(Ahead())

    /// `body` with what `render(at:into:completion:)` decodes ahead held: for the layers' files
    /// (`FrameRenderer+<Layer>.swift`), which let go of their prefetchers there.
    func withAhead<T>(_ body: (inout Ahead) throws -> T) rethrows -> T {
        try ahead.withLock { try body(&$0) }
    }

    /// The frames `render(at:into:completion:)` evaluated and scheduled ahead, and the prefetchers decoding theirs.
    struct Ahead {
        var prefetchers: [TrackKey: FramePrefetcher] = [:]
        /// Evaluated, in order, by their index on the grid: the one expected next first, up to
        /// `FramePrefetcher.borderLookahead` after it.
        var frames: [(index: Int, frame: RenderFrame)] = []
        /// The index on the grid of the frame expected next; `nil` before the first and after one off the grid.
        var expected: Int?
        /// What is scheduled of the frames evaluated: those of the next `lookahead`, and a track that comes back.
        var plan: DecodeAhead?
    }

    /// The frames of the grid decoded ahead of the one asked for.
    static let lookahead = FramePrefetcher.maxFrames

    /// Output seconds the take lasts, in the renderer's scene.
    public var duration: Double { scene.duration }

    /// The renderer's scene: what `encode(at:into:commandBuffer:)` and the other ways to draw without a scene draw.
    public var scene: FrameEvaluator { current.withLock { $0 } }

    /// The window titles of the renderer's scene's size, for tests.
    var titleTexture: TitleTexture { lock.withLock { titles(for: outputSize) } }

    /// The spans of the screen and of the camera shown with the frame before them so far, because a segment could
    /// not be decoded there (`TrackFrameReader`), in output seconds within `[0, duration]`, in time order (by start, end
    /// and track): each span of the source through `TimeMap.outputRange(ofSource:take:)`, with the cuts inside it closed,
    /// and none that is all cut; of a screen, only where it is shown (the plan's screen, and the one being left while a
    /// change of screen crossfades: `FrameEvaluator.screenRanges`), one span for each stretch of it. The tracks are those
    /// the document shows (its screens, and the camera unless it is hidden), so the segments that cannot be used at all
    /// are listed before a frame is drawn. After drawing every frame of the timeline in order (an export), it lists every
    /// such span of the output. A scene of several takes lists those of each take's tracks in that take's clips. The
    /// imported clips of the sequence that cannot be drawn are listed too (`mediaMissingVideo(of:)`): whole when their file
    /// is not there to be read, as soon as the scene is made.
    public var missingVideo: [MissingVideo] {
        // One scene for all of it: `setScene(_:)` from another thread meanwhile never mixes two revisions.
        let current = scene, timeMap = current.timeMap
        let takes = current.takeScenesInOrder.flatMap { take, scene -> [MissingVideo] in
            let takeID = scene.takeID, shown = scene.screenRanges
            return scene.videoTrackIDs
                .compactMap { reader(for: TrackKey(take: take, track: $0)) }
                .flatMap { reader in reader.gaps.map { (reader.trackID, $0) } }
                .flatMap { track, gap -> [MissingVideo] in
                    // A span of no source (a read that timed out at one instant) is listed where that instant is shown.
                    let output = gap.start < gap.end
                        ? timeMap.outputRange(ofSource: gap.start..<gap.end, take: takeID)
                        : timeMap.output(atSource: gap.start, take: takeID).map { $0..<$0 }
                    guard let output else { return [] }
                    let parts = shown[track].map { Self.parts(of: output, shownIn: $0, duration: timeMap.duration) } ?? [output]
                    return parts.map { part in
                        MissingVideo(
                            track: track, file: gap.file, start: Double(part.lowerBound) / 1e9,
                            end: Double(part.upperBound) / 1e9, reason: gap.reason)
                    }
                }
        }
        // And the imported clips of the sequence that cannot be drawn.
        return (takes + mediaMissingVideo(of: current)).sorted { ($0.start, $0.end, $0.track) < ($1.start, $1.end, $1.track) }
    }

    /// The parts of output range `range` inside `shown` (ranges in order and apart) of an output `duration` long: an
    /// empty range (one instant) where it is in one of them, its end included at the output's end.
    static func parts(of range: Range<Int64>, shownIn shown: [Range<Int64>], duration: Int64) -> [Range<Int64>] {
        guard !range.isEmpty else {
            let t = range.lowerBound
            return shown.contains { $0.contains(t) || (t == $0.upperBound && t == duration) } ? [range] : []
        }
        return shown.compactMap { span in
            let lower = max(range.lowerBound, span.lowerBound), upper = min(range.upperBound, span.upperBound)
            return lower < upper ? lower..<upper : nil
        }
    }

    /// The legacy document's frames (`EditDocument.legacy(for:)`): what phase 0 and 1a draw.
    public convenience init(project: LoadedProject, outputSize: SIMD2<Int>, device: (any MTLDevice)? = nil) throws {
        try self.init(project: project, document: .legacy(for: project), outputSize: outputSize, device: device)
    }

    /// Opens nothing yet: segments are read as frames need them, and unreadable ones are gaps. Its scene is `document`
    /// at `outputSize`, of every take its sequence shows (`FrameEvaluator.init(project:document:…)`).
    /// - Parameters:
    ///   - device: the system default device when `nil`.
    ///   - frameRate: the frames per second the output is drawn at, whose frame the motion blur's shutters are
    ///     fractions of (`FrameEvaluator`), in every scene of the renderer; the document's when `nil`.
    ///   - analysis: what the scenes read of the project's analysis caches (phase 2 design §10).
    /// - Throws: `RenderError.noMetalDevice` without a Metal device, `invalidOutputSize`, and the
    ///   errors of `Compositor.init` and `CursorSprite.makeTexture`. Builds the document's motion paths
    ///   (`MotionPaths`), which takes tens of milliseconds for an hour of take: never on the main thread.
    public init(
        project: LoadedProject, document: EditDocument, outputSize: SIMD2<Int>, device: (any MTLDevice)? = nil,
        frameRate: Int? = nil, analysis: AnalysisInputs = .none
    ) throws {
        guard outputSize.x > 0, outputSize.y > 0 else { throw RenderError.invalidOutputSize(outputSize) }
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noMetalDevice }
        guard let commandQueue = device.makeCommandQueue() else {
            throw RenderError.metalResourceUnavailable("command queue")
        }
        // Textures made from pixel buffers are read (screen frames) or drawn into (export frames).
        let usage = MTLTextureUsage([.shaderRead, .renderTarget]).rawValue
        let attributes = [kCVMetalTextureUsage as String: NSNumber(value: usage)] as CFDictionary
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, attributes, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw RenderError.metalResourceUnavailable("texture cache (CVReturn \(status))")
        }
        self.device = device
        self.commandQueue = commandQueue
        textureCache = cache
        compositor = try Compositor(device: device)
        backgroundImages = try BackgroundImages(device: device, library: compositor.library, package: project.package)
        cursorImages = try CursorImages(device: device, package: project.package, take: project.take.id)
        cameraLook = CameraLookResources(device: device, package: project.package)
        mediaResources = MediaClipResources(device: device, package: project.package)
        annotationResources = AnnotationResources(device: device, package: project.package)
        var records = Dictionary(project.takes.map { ($0.id, $0) }) { first, _ in first }
        records[project.take.id] = project.take
        let readable = records.mapValues { take in
            LayoutTimeline.cameraReadable(take: take) { SegmentAvailability.classify($0, in: project.package) }
        }
        let cameraReadable = readable[project.take.id] ?? true
        current = Mutex(FrameEvaluator(
            project: project, document: document, outputSize: outputSize, frameRate: frameRate, cameraReadable: readable,
            analysis: analysis))
        frameRateOverride = frameRate
        self.cameraReadable = cameraReadable
        cameraReadableByTake = readable
        self.analysis = analysis
        package = project.package
        self.project = project
        takeRecords = records
    }

    /// A scene of this renderer's project: `document` at `outputSize`, of every take its sequence shows
    /// (`FrameEvaluator.init(project:document:…)`), with `paths` (`SequencePaths(project:document:cameraReadable:reusing:)`
    /// of `document` with `cameraReadableByTake`, built off the main thread), at the renderer's frames per second (the
    /// document's unless the renderer was given some), with each take's camera readable as the renderer found it, reading
    /// the renderer's own `analysis`. Cheap: the paths are what costs.
    public func makeScene(document: EditDocument, paths: SequencePaths, outputSize: SIMD2<Int>) -> FrameEvaluator {
        makeScene(document: document, paths: paths, outputSize: outputSize, analysis: analysis)
    }

    /// Like `makeScene(document:paths:outputSize:)`, reading `analysis` of the caches instead of the renderer's
    /// (`AnalysisInputs.none` is no analysis).
    public func makeScene(
        document: EditDocument, paths: SequencePaths, outputSize: SIMD2<Int>, analysis: AnalysisInputs
    ) -> FrameEvaluator {
        FrameEvaluator(
            project: project, document: document, outputSize: outputSize, paths: paths, frameRate: frameRateOverride,
            cameraReadable: cameraReadableByTake, analysis: analysis)
    }

    /// `makeScene(document:paths:outputSize:)` with `paths` the project's own take's
    /// (`MotionPaths(take:events:document:cameraReadable:)` of `document` with `cameraReadable`): those of any other take
    /// the sequence shows are built here, which costs what they cost. With one take, the same scene.
    public func makeScene(document: EditDocument, paths: MotionPaths, outputSize: SIMD2<Int>) -> FrameEvaluator {
        makeScene(document: document, paths: paths, outputSize: outputSize, analysis: analysis)
    }

    /// Like `makeScene(document:paths:outputSize:)` with the own take's paths, reading `analysis` of the caches instead of
    /// the renderer's.
    public func makeScene(
        document: EditDocument, paths: MotionPaths, outputSize: SIMD2<Int>, analysis: AnalysisInputs
    ) -> FrameEvaluator {
        let own = SequencePaths(byTake: [take.id: paths], cameraReadable: [take.id: cameraReadable])
        return makeScene(document: document, paths: own, outputSize: outputSize, analysis: analysis)
    }

    /// Makes `scene` the renderer's scene, and its size the one `encode(at:into:commandBuffer:)` checks: what was decoded
    /// ahead for the scene before goes, and a background image or a camera's `.cube` that could not be read is looked for
    /// again.
    public func setScene(_ scene: FrameEvaluator) {
        current.withLock { $0 = scene }
        resetPrefetchers()
        lock.withLock {
            backgroundImages.forgetUnreadable()
            cameraLook.forgetUnreadable()
        }
    }

    /// Encodes the frame at `outputTime` of the renderer's scene into `target`, which must be `.bgra8Unorm` and
    /// `outputSize` big (otherwise this throws and encodes nothing), decoding its screen and camera frames now. The caller
    /// commits `commandBuffer`.
    public func encode(at outputTime: Double, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        try encode(scene: scene, at: outputTime, into: target, commandBuffer: commandBuffer)
    }

    /// Encodes the frame at `outputTime` of `scene` (one of this renderer's take) into `target`, which must be
    /// `.bgra8Unorm` and `scene.outputSize` big (otherwise this throws and encodes nothing), decoding its screen and camera
    /// frames now. The caller commits `commandBuffer`.
    public func encode(
        scene: FrameEvaluator, at outputTime: Double, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer
    ) throws {
        try check(target, size: scene.outputSize)
        let frame = try lock.withLock {
            CVMetalTextureCacheFlush(textureCache, 0)
            let frame = try evaluate(scene, at: outputTime)
            try draw(frame, into: target, commandBuffer: commandBuffer) { key, time in
                guard let reader = reader(for: key) else { return nil }
                // An imported clip's within the renderer's limit on them (`MediaClipResources.gate`).
                let pixelBuffer = Self.isMedia(key) ? mediaResources.gate.run { reader.pixelBuffer(at: time) } : reader.pixelBuffer(at: time)
                return try pixelBuffer.map(metalTexture(for:))
            }
            return frame
        }
        // The imported clips this frame does not show are let go (after the lock: `ahead` is taken before it elsewhere).
        releaseMedia(keeping: Set(videos(of: frame).map(\.track)))
    }

    /// The frame at `outputTime` of `scene`, with the cursor images the renderer can read: what
    /// `encode(scene:at:into:commandBuffer:)` draws.
    func frame(of scene: FrameEvaluator, at outputTime: Double) throws -> RenderFrame {
        try lock.withLock { try evaluate(scene, at: outputTime) }
    }

    /// The frame at `outputTime` of `scene`, with the cursor images of each take the renderer can read. Call with `lock`
    /// held.
    private func evaluate(_ scene: FrameEvaluator, at outputTime: Double) throws -> RenderFrame {
        try scene.frame(at: outputTime, cursorImageOfTakeIsReadable: { take, hash in try cursorImages(of: take).isReadable(hash) })
    }

    /// The cursor images of the take `take` names as `RenderFrame.take` does (`nil`, the project's own), made the first
    /// time. Call with `lock` held.
    /// - Throws: `RenderError.metalResourceUnavailable` if Metal cannot make the arrow's texture.
    private func cursorImages(of take: String?) throws -> CursorImages {
        guard let take, take != self.take.id else { return cursorImages }
        if let images = otherCursorImages[take] { return images }
        let images = try CursorImages(device: device, package: package, take: take)
        otherCursorImages[take] = images
        return images
    }

    /// Encodes `frame` (of a scene of this renderer) into `target`, `.bgra8Unorm` and `frame.outputSize` big, with the
    /// frames `decoded` gives for each video (by take and track, `TrackKey`, at a source instant) it shows. The caller
    /// commits `commandBuffer`.
    func encode(
        _ frame: RenderFrame, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer,
        decoded: (_ track: TrackKey, _ time: HostTime) throws -> CachedTexture?
    ) throws {
        try check(target, size: frame.outputSize)
        try lock.withLock { try draw(frame, into: target, commandBuffer: commandBuffer, decoded: decoded) }
    }

    /// Throws unless `target` is `.bgra8Unorm` and `size` big.
    private func check(_ target: any MTLTexture, size: SIMD2<Int>) throws {
        let actual = SIMD2(target.width, target.height)
        guard actual == size else { throw RenderError.targetSizeMismatch(expected: size, actual: actual) }
        guard target.pixelFormat == Compositor.pixelFormat else { throw RenderError.unsupportedPixelFormat }
    }

    /// The window titles of frames `size` big: the store of the last two sizes drawn. Call with `lock` held.
    private func titles(for size: SIMD2<Int>) -> TitleTexture {
        if let index = titleTextures.firstIndex(where: { $0.size == size }) {
            let found = titleTextures.remove(at: index)
            titleTextures.append(found)
            return found.titles
        }
        // The oldest size's titles go.
        if titleTextures.count >= 2 { titleTextures.removeFirst() }
        let titles = TitleTexture(device: device)
        titleTextures.append((size, titles))
        return titles
    }

    /// Encodes `frame` into `target` with the frames `decoded` gives for each video (by take and track, `TrackKey`, as
    /// `videos(of:)` names it) at a source instant it shows, asked for in this order: the screen, the screen being left,
    /// the camera; then what the camera's colour and background are drawn with (`CameraLookResources`), its mask among
    /// them, whose absence draws the camera's original and is never an error; then what phase 3's imported clip and
    /// annotations are drawn with (`mediaTextures`, `annotationTextures`). Every way to draw ends here. Call with `lock`
    /// held.
    private func draw(
        _ frame: RenderFrame, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer,
        decoded: (_ track: TrackKey, _ time: HostTime) throws -> CachedTexture?
    ) throws {
        let take = takeKey(of: frame)
        /// The texture of a decoded frame of a track of the frame's take, kept alive until `commandBuffer` completes.
        func texture(_ trackID: String, _ time: HostTime) throws -> (any MTLTexture)? {
            guard let cached = try decoded(TrackKey(take: take, track: trackID), time) else { return nil }
            commandBuffer.addCompletedHandler { _ in withExtendedLifetime(cached) {} }
            return cached.texture
        }
        // Only the screens shown are decoded: the one of the frame, and the one being left during a change.
        let screen = try frame.screen.flatMap { try texture($0.trackID, $0.sourceTime) }
        let previousScreen = try frame.previousScreen.flatMap { try texture($0.trackID, $0.sourceTime) }
        let camera = try frame.camera.flatMap { try texture($0.trackID, $0.sourceTime) }
        /// What `decoded` gives for a video of the camera's look or of phase 3's layers (by a reader id no take's track
        /// has: `TrackKey.take` `nil`), kept alive until `commandBuffer` completes.
        func kept(_ id: String, _ time: HostTime) throws -> CachedTexture? {
            guard let cached = try decoded(TrackKey(take: nil, track: id), time) else { return nil }
            commandBuffer.addCompletedHandler { _ in withExtendedLifetime(cached) {} }
            return cached
        }
        let look = try cameraLook.textures(for: frame, decoded: kept, commandBuffer: commandBuffer)
        let layerTextures = LayerTextures(
            media: try mediaTextures(for: frame, decoded: kept, commandBuffer: commandBuffer),
            annotations: try annotationTextures(for: frame, decoded: kept, commandBuffer: commandBuffer))
        let backgroundImage = try Self.backgroundTexture(of: frame, images: backgroundImages, outputSize: frame.outputSize)
        let titleTexture = titles(for: frame.outputSize)
        let windowTitle = try TitleTexture.source(for: frame).flatMap {
            try titleTexture.texture(for: $0, scale: TitleTexture.scale(for: frame))
        }
        // Every cursor of the frame, blurred or not, is drawn with the image of its time.
        let image = frame.cursor?.image ?? frame.subframes.lazy.compactMap(\.cursor).first?.image ?? frame.cursorSamples.first?.image
        let cursor = try cursorImages(of: take).texture(for: image ?? .toma(.arrow))
        try compositor.encode(
            frame, screen: screen, previousScreen: previousScreen, camera: camera, cursor: cursor, backgroundImage: backgroundImage,
            windowTitle: windowTitle, cameraLook: look, into: target, commandBuffer: commandBuffer, layerTextures: layerTextures)
    }

    /// The texture `frame`'s background is drawn with (`Compositor.encode`'s `backgroundImage`), from `images`, for
    /// frames `outputSize` big: an image's; a blurred wallpaper's mesh gradient, blurred; a sharp wallpaper's mesh
    /// gradient under the zoom camera's motion blur (`RenderFrame.subframes`), which the subsamples read, but in a card's
    /// mode, whose background is drawn once (`RenderFrame.backgroundTransform`); none otherwise.
    static func backgroundTexture(
        of frame: RenderFrame, images: BackgroundImages, outputSize: SIMD2<Int>
    ) throws -> (any MTLTexture)? {
        switch frame.background {
        case let .image(image):
            return try images.texture(for: image, outputSize: outputSize)
        case let .wallpaper(preset, sigma) where sigma.isFinite && sigma > 0:
            return try images.texture(forWallpaper: preset, blurSigma: sigma, outputSize: outputSize)
        case let .wallpaper(preset, _) where !frame.subframes.isEmpty && !frame.isCardMode:
            return try images.texture(forWallpaper: preset, blurSigma: 0, outputSize: outputSize)
        default:
            return nil
        }
    }

    /// Draws the frame at `outputTime` into `pixelBuffer` (32BGRA, IOSurface-backed, `outputSize` big), decoding its
    /// frames now, and waits for the GPU to finish.
    public func render(at outputTime: Double, into pixelBuffer: CVPixelBuffer) throws {
        let scene = self.scene
        try check(pixelBuffer, size: scene.outputSize)
        let target = try lock.withLock { try metalTexture(for: pixelBuffer) }
        let commandBuffer = try makeCommandBuffer()
        try encode(scene: scene, at: outputTime, into: target.texture, commandBuffer: commandBuffer)
        try finish(commandBuffer)
        withExtendedLifetime(target) {}
    }

    /// Queues the frame at `outputTime` to be drawn into `pixelBuffer` (32BGRA, IOSurface-backed, `outputSize` big) and
    /// returns, without decoding, drawing or waiting for anything: the export's way to draw, with several frames on the
    /// GPU at once. The frames queued are drawn one at a time in the order queued, each once its screen and camera frames
    /// are decoded (ahead, along the grid of `frameRate`: see the type's notes), and they are the bytes
    /// `render(at:into:)` draws. `completion` is called once, never from this call and never on the main thread: with
    /// `nil` once the GPU finished the frame, or with the error that kept it from being drawn (what `render(at:into:)`
    /// throws: a `RenderError`, or `RenderError.gpuFailed` when the GPU did not complete it), nothing having been drawn
    /// then. `pixelBuffer` must not be read or written until then.
    public func render(
        at outputTime: Double, into pixelBuffer: CVPixelBuffer, completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        let target = PixelBufferBox(pixelBuffer)
        lastQueued.withLock { last in
            let previous = last
            last = Task.detached(priority: .userInitiated) { [self] in
                await previous?.value
                do {
                    let prepared = try await onRenderQueue { try self.prepare(at: outputTime) }
                    // Suspended while a frame is decoded: no thread waits.
                    var decoded: [DecodedKey: CachedTexture?] = [:]
                    for (key, prefetcher) in prepared.sources {
                        decoded[key] = try await prefetcher.frame(atSource: key.time)
                    }
                    let frames = decoded
                    try await onRenderQueue {
                        try self.draw(prepared.frame, decoded: frames, into: target.pixelBuffer, completion: completion)
                    }
                } catch {
                    completion(error)
                }
            }
        }
    }

    /// The frame at `outputTime`, evaluated, and the prefetchers that decode the frames it shows, with what each is asked
    /// for. Schedules the frames of the grid ahead of it, from the one expected next: from it, when it is not; and, a
    /// second of output ahead, the first frame of a track that comes back (`DecodeAhead`). Runs on `renderQueue`.
    ///
    /// The imported clips' readers that neither it nor the frames looked at ahead show are let go
    /// (`releaseMedia(keeping:in:)`), once `ahead` is no longer held.
    private func prepare(at outputTime: Double) throws -> PreparedFrame {
        let scene = self.scene, frameRate = scene.frameRate
        let index = gridIndex(of: outputTime, frameRate: frameRate)
        let lastIndex = scene.timeMap.frameCount(frameRate: frameRate) - 1
        let (prepared, released) = try ahead.withLock { ahead -> (PreparedFrame, [TrackFrameReader]) in
            // Another frame than the one expected next: what was read ahead is of no use.
            if index == nil || index != ahead.expected || ahead.frames.first.map({ $0.index != index }) == true {
                for prefetcher in ahead.prefetchers.values { prefetcher.reset() }
                ahead.frames.removeAll()
                ahead.plan = nil
            }
            ahead.expected = index.map { $0 + 1 }
            if let index, index <= lastIndex {
                var plan = ahead.plan ?? DecodeAhead(frameRate: frameRate)
                var evaluated: [(index: Int, frame: RenderFrame)] = []
                let keys = try plan.advance(to: index, last: lastIndex) { next in
                    let frame = try self.frame(of: scene, at: Double(TimeMap.frameTime(next, frameRate: frameRate)) / 1e9)
                    evaluated.append((next, frame))
                    return self.videos(of: frame)
                }
                ahead.plan = plan
                ahead.frames += evaluated
                for key in keys { try prefetcher(for: key.track, in: &ahead)?.schedule(key.time) }
                let released = releaseMedia(keeping: plan.tracksAhead, in: &ahead).1
                let first = ahead.frames.removeFirst()
                return (PreparedFrame(frame: first.frame, sources: try sources(of: first.frame, in: &ahead)), released)
            }
            let frame = try self.frame(of: scene, at: outputTime)
            let released = releaseMedia(keeping: Set(videos(of: frame).map(\.track)), in: &ahead).1
            try schedule(frame, in: &ahead)
            return (PreparedFrame(frame: frame, sources: try sources(of: frame, in: &ahead)), released)
        }
        Self.letGo(released)
        return prepared
    }

    /// Tells the prefetchers of the frames `frame` shows that they will be asked for them.
    private func schedule(_ frame: RenderFrame, in ahead: inout Ahead) throws {
        for (key, prefetcher) in try sources(of: frame, in: &ahead) { prefetcher.schedule(key.time) }
    }

    /// The (track, source instant) of each frame `frame` shows (`draw`'s order), with the prefetcher of its track, made the
    /// first time; none for a video without a reader (`reader(for:)`).
    private func sources(of frame: RenderFrame, in ahead: inout Ahead) throws -> [(DecodedKey, FramePrefetcher)] {
        try videos(of: frame).compactMap { key in try prefetcher(for: key.track, in: &ahead).map { (key, $0) } }
    }

    /// The (track, source instant) of each video `frame` shows, in `draw`'s order: the screen, the screen being left, the
    /// camera, of the frame's take (`DecodedKey.take`, as `RenderFrame.take` names it); then what the camera is drawn with
    /// (`CameraLookResources.videos(of:)`: its person's mask, by a reader id that is no track of a take), then phase 3's
    /// imported clip and annotation clips (`mediaVideos(of:)`, `annotationVideos(of:)`, by reader ids that are no track
    /// either), all without a take. A part a layout hides is not in the frame (1c design §14.4), so it is not decoded.
    /// Each once: a video two layers show at the same instant (a title card's blurred frame over the same one sharp,
    /// `TitleCardScene`) is decoded, scheduled and taken once, where it first comes.
    func videos(of frame: RenderFrame) -> [DecodedKey] {
        let take = takeKey(of: frame)
        let keys = [
            frame.screen.map { DecodedKey(trackID: $0.trackID, time: $0.sourceTime, take: take) },
            frame.previousScreen.map { DecodedKey(trackID: $0.trackID, time: $0.sourceTime, take: take) },
            frame.camera.map { DecodedKey(trackID: $0.trackID, time: $0.sourceTime, take: take) },
        ].compactMap { $0 } + cameraLook.videos(of: frame) + mediaVideos(of: frame) + annotationVideos(of: frame)
        var seen = Set<DecodedKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// The take of `frame`'s tracks as `TrackKey` names it: `nil` for the project's own (`RenderFrame.take`'s `nil`, or its
    /// id), the id of any other.
    private func takeKey(of frame: RenderFrame) -> String? {
        frame.take == take.id ? nil : frame.take
    }

    /// The prefetcher of `track` (a take's track, or a person's mask or a file of `assets/` by its reader id), made the
    /// first time; `nil` for a video without a reader (`reader(for:)`). An imported clip's decodes within the renderer's
    /// limit on them (`MediaClipResources.gate`), and is made again when its file gets a new reader (one tried again after
    /// giving no frame, `MediaClipResources.reader(for:)`).
    private func prefetcher(for track: TrackKey, in ahead: inout Ahead) throws -> FramePrefetcher? {
        let media = Self.isMedia(track)
        if let prefetcher = ahead.prefetchers[track] {
            guard media, let reader = mediaResources.reader(for: track.track), reader !== prefetcher.reader else { return prefetcher }
            prefetcher.reset()
        }
        guard let reader = reader(for: track) else { return nil }
        let prefetcher = try FramePrefetcher(reader: reader, device: device, gate: media ? mediaResources.gate : nil)
        ahead.prefetchers[track] = prefetcher
        return prefetcher
    }

    /// The prefetcher that decodes ahead the frames of `track` (made the first time; `nil` for a video without a reader,
    /// `reader(for:)`), shared with `render(at:into:completion:)`: one consumer of the renderer uses them.
    func prefetcher(for track: TrackKey) throws -> FramePrefetcher? {
        try ahead.withLock { try prefetcher(for: track, in: &$0) }
    }

    /// `prefetcher(for:)` of the track `trackID` of the project's own take (or of a person's mask or a file of `assets/`).
    func prefetcher(for trackID: String) throws -> FramePrefetcher? {
        try prefetcher(for: TrackKey(take: nil, track: trackID))
    }

    /// Drops what every prefetcher scheduled and decoded ahead, as after a jump.
    func resetPrefetchers() {
        ahead.withLock { ahead in
            for prefetcher in ahead.prefetchers.values { prefetcher.reset() }
            ahead.frames.removeAll()
            ahead.expected = nil
            ahead.plan = nil
        }
    }

    /// The index of `outputTime` on the grid of `frameRate`: `n` when it is `TimeMap.frameTime(n, frameRate:)` exactly.
    private func gridIndex(of outputTime: Double, frameRate: Int) -> Int? {
        guard frameRate > 0, outputTime.isFinite, outputTime >= 0 else { return nil }
        let nanoseconds = TimeMap.outputNanoseconds(seconds: outputTime)
        let index = Int((Double(nanoseconds) * Double(frameRate) / 1e9).rounded())
        return TimeMap.frameTime(index, frameRate: frameRate) == nanoseconds ? index : nil
    }

    /// Draws `frame` with the frames `decoded` holds into `pixelBuffer`, commits it and calls `completion` on `renderQueue`
    /// once the GPU is done; throws, having committed nothing, what kept it from being drawn: `RenderError.frameNotDecoded`
    /// for a frame `decoded` lacks of a video with a reader (`reader(for:)`: a track of the take, a person's mask, an
    /// imported clip or an annotation's clip), the preview's own rule, so the export never leaves out silently what the
    /// preview draws. Runs on `renderQueue` (and in tests).
    func draw(
        _ frame: RenderFrame, decoded: [DecodedKey: CachedTexture?], into pixelBuffer: CVPixelBuffer,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) throws {
        try check(pixelBuffer, size: frame.outputSize)
        let commandBuffer = try makeCommandBuffer()
        let target = try lock.withLock {
            CVMetalTextureCacheFlush(textureCache, 0)
            let target = try metalTexture(for: pixelBuffer)
            try draw(frame, into: target.texture, commandBuffer: commandBuffer) { key, time in
                if let texture = decoded[DecodedKey(key, time: time)] { return texture }
                // A video without a reader shows nothing, as drawing it frame by frame does; any video with one (a track
                // of a take, a person's mask, an imported clip or an annotation's clip) was decoded. A clip's reader is
                // not made here: a file that turned up since the frame was prepared shows nothing in it.
                guard reader(for: key, makingMedia: false) != nil else { return nil }
                throw RenderError.frameNotDecoded(track: key.track, sourceTime: time)
            }
            return target
        }
        commandBuffer.addCompletedHandler { [renderQueue] commandBuffer in
            let error = commandBuffer.status == .completed ? nil : Self.gpuFailure(commandBuffer)
            // Told from the renderer's queue, after the frame was drawn there, rather than from Metal's thread: what the
            // caller handed over is seen there as the caller left it (and so the Thread Sanitizer sees it too).
            renderQueue.async {
                withExtendedLifetime(target) {}
                completion(error)
            }
        }
        commandBuffer.commit()
    }

    /// Runs `body` on `renderQueue` and returns what it returns, suspended meanwhile.
    private func onRenderQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { continuation.resume(with: Result(catching: body)) }
        }
    }

    /// Throws unless `pixelBuffer` is 32BGRA and `size` big.
    private func check(_ pixelBuffer: CVPixelBuffer, size: SIMD2<Int>) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw RenderError.unsupportedPixelFormat
        }
        let actual = SIMD2(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        guard actual == size else { throw RenderError.targetSizeMismatch(expected: size, actual: actual) }
    }

    /// The frame at `outputTime` of the renderer's scene as BGRA bytes, `outputSize.x × 4` per row with no padding.
    public func renderBytes(at outputTime: Double) throws -> [UInt8] {
        let scene = self.scene
        return try renderOffscreen(size: scene.outputSize) { target, commandBuffer in
            try encode(scene: scene, at: outputTime, into: target, commandBuffer: commandBuffer)
        }
    }

    /// `renderOffscreen(size:_:)` at the size of the renderer's scene.
    func renderOffscreen(_ draw: (any MTLTexture, any MTLCommandBuffer) throws -> Void) throws -> [UInt8] {
        try renderOffscreen(size: outputSize, draw)
    }

    /// Runs `draw` on a new `.bgra8Unorm` texture `outputSize` big, waits for the GPU and returns the texture's bytes
    /// without row padding.
    func renderOffscreen(
        size outputSize: SIMD2<Int>, _ draw: (any MTLTexture, any MTLCommandBuffer) throws -> Void
    ) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: outputSize.x, height: outputSize.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("offscreen target")
        }
        let commandBuffer = try makeCommandBuffer()
        try draw(target, commandBuffer)
        try finish(commandBuffer)
        var bytes = [UInt8](repeating: 0, count: outputSize.x * outputSize.y * 4)
        target.getBytes(
            &bytes, bytesPerRow: outputSize.x * 4,
            from: MTLRegionMake2D(0, 0, outputSize.x, outputSize.y), mipmapLevel: 0)
        return bytes
    }

    private func makeCommandBuffer() throws -> any MTLCommandBuffer {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RenderError.metalResourceUnavailable("command buffer")
        }
        return commandBuffer
    }

    private func finish(_ commandBuffer: any MTLCommandBuffer) throws {
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw Self.gpuFailure(commandBuffer) }
    }

    /// `RenderError.gpuFailed` with what `commandBuffer` says went wrong.
    private static func gpuFailure(_ commandBuffer: any MTLCommandBuffer) -> RenderError {
        .gpuFailed(commandBuffer.error.map { String(describing: $0) } ?? "status \(commandBuffer.status.rawValue)")
    }

    /// The earliest and the latest source instants a frame was asked of track `trackID` of the project's own take so far
    /// (`nil` before the first, and for a track without a reader yet), for tests.
    func askedFor(track trackID: String) -> ClosedRange<HostTime>? {
        readers.withLock { $0[TrackKey(take: nil, track: trackID)] }?.askedFor
    }

    /// The reader of `track`, a track of a take of the package (`TrackKey.take`: `nil` for the project's own), made the
    /// first time it is asked for, apart from every other take's track of the same id; for an id that is no track of that
    /// take, `CameraLookResources.reader(for:)`'s (a person's mask), or else `mediaReader(for:)`'s (a file of `assets/`),
    /// `nil` for any other. Every scene of the renderer reads with it.
    func reader(for track: TrackKey) -> TrackFrameReader? {
        reader(for: track, makingMedia: true)
    }

    /// `reader(for:)`, which makes an imported clip's reader only with `makingMedia` (otherwise the one kept, if any).
    private func reader(for track: TrackKey, makingMedia: Bool) -> TrackFrameReader? {
        let take = track.take == self.take.id ? nil : track.take
        let owner: TakeRecord? = if let take { takeRecords[take] } else { self.take }
        guard let record = owner?.track(track.track) else {
            return cameraLook.reader(for: track.track)
                ?? (makingMedia ? mediaReader(for: track.track) : mediaResources.existingReader(for: track.track))
        }
        let key = TrackKey(take: take, track: track.track)
        return readers.withLock { readers in
            if let reader = readers[key] { return reader }
            let reader = TrackFrameReader(package: package, track: record)
            readers[key] = reader
            return reader
        }
    }

    /// `reader(for:)` of the track `trackID` of the project's own take (or of a person's mask or a file of `assets/`).
    func reader(for trackID: String) -> TrackFrameReader? {
        reader(for: TrackKey(take: nil, track: trackID))
    }

    /// `pixelBuffer` as a `.bgra8Unorm` texture sharing its memory, through the texture cache. The
    /// `CVMetalTexture` must outlive every use of its texture by the GPU. Call with `lock` held.
    private func metalTexture(for pixelBuffer: CVPixelBuffer) throws(RenderError) -> CachedTexture {
        try CachedTexture(pixelBuffer, cache: textureCache)
    }
}

/// A video a frame shows, as the renderer reads it (phase 3 design §9): a track of a take (`take`, as `RenderFrame.take`
/// names it: `nil` for the project's own), apart from any other take's track of the same id; or, with `take` `nil`, a
/// person's mask or a file of `assets/` by its reader id, which no take's track has.
struct TrackKey: Hashable, Sendable {
    var take: String?
    var track: String
}

/// The screen or camera frame a frame shows: its track, its source instant and its take (`TrackKey`).
struct DecodedKey: Hashable, Sendable {
    var trackID: String
    var time: HostTime
    /// `nil` for the project's own take, and for a video that is no take's track.
    var take: String? = nil

    /// The frame of `track` at source instant `time`.
    init(_ track: TrackKey, time: HostTime) {
        self.init(trackID: track.track, time: time, take: track.take)
    }

    init(trackID: String, time: HostTime, take: String? = nil) {
        self.trackID = trackID
        self.time = time
        self.take = take
    }

    /// Its take and track.
    var track: TrackKey { TrackKey(take: take, track: trackID) }
}

/// A frame `render(at:into:completion:)` draws: evaluated, with the prefetchers of the frames it shows.
private struct PreparedFrame: Sendable {
    var frame: RenderFrame
    var sources: [(DecodedKey, FramePrefetcher)]
}

/// The pixel buffer a frame of `render(at:into:completion:)` is drawn into, handed to the queues that draw it; the caller
/// leaves it alone until the completion.
private final class PixelBufferBox: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    init(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

/// A texture from a texture cache, with what keeps its memory alive: held until the GPU is done with it. Immutable.
final class CachedTexture: @unchecked Sendable {
    let cvTexture: CVMetalTexture
    let pixelBuffer: CVPixelBuffer
    let texture: any MTLTexture
    /// The cache that made `cvTexture`, which a `CVMetalTexture` does not retain. Declared last, so released after it:
    /// a texture released on one thread while its cache is finalized on another crashes in Core Video
    /// (`CVMetalTextureCache::bufferBackingNotInUse`), as the last frame of an export did when the renderer's queue let
    /// go of it while the export, done, released the renderer. With this, a cache outlives every texture it made.
    private let cache: CVMetalTextureCache

    /// `pixelBuffer` as a `.bgra8Unorm` texture sharing its memory, made by `cache`.
    /// - Throws: `RenderError.textureCreationFailed` when Core Video cannot make it (a pixel buffer that is not backed by
    ///   an IOSurface, for example).
    init(_ pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) throws(RenderError) {
        var created: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, Compositor.pixelFormat,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &created)
        guard status == kCVReturnSuccess, let created, let texture = CVMetalTextureGetTexture(created) else {
            throw RenderError.textureCreationFailed(status)
        }
        cvTexture = created
        self.pixelBuffer = pixelBuffer
        self.texture = texture
        self.cache = cache
    }
}
