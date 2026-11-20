// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import Metal
import ProjectFormat
import QuartzCore
import Synchronization
import os

/// What the preview is asked to show.
public enum PreviewRequest: Equatable, Sendable {
    /// Paused at frame `frame` of the scene's frame grid: exactly that frame of the export, at the export's size.
    case paused(frame: Int)
    /// The playhead dragged to output second `seconds`: the screen's key frame at or before it, with the stage, the
    /// cursor and the zoom of that instant, at the export's size.
    case scrubbing(seconds: Double)
    /// Playing at output second `seconds`: the frame of the grid at or before it, with the frames decoded ahead.
    case playing(seconds: Double)
}

/// Shows the preview in a `CAMetalLayer` without the main thread ever decoding, drawing or waiting for the GPU (design
/// §7.8): `request(_:)` stores what to show and returns; a queue of the engine's own evaluates the frame, decodes what it
/// shows, draws it through the renderer (the export's one drawing path) and presents it. While a frame is being drawn
/// only the latest request is kept: those in between are never drawn.
///
/// - `.paused(frame:)`: frame `n` of the scene given (`setScene(_:)`, at the export's size: plan decision 11), its videos
///   decoded exactly as the export decodes them (`TrackFrameReader`, through each track's `FramePrefetcher`, the tracks
///   at once); the bytes are the export's. The frames a pause decoded are kept, so pausing on it again, or playing from
///   it, decodes nothing.
/// - `.scrubbing(seconds:)` (plan decision 32): the key frame at or before the instant of each video it shows, alone
///   (`FramePrefetcher.keyFrame(atSource:)`, no `AVAssetReader`), with the stage, the cursor and the zoom of the exact
///   instant; releasing asks for `.paused(frame:)`, which shows the exact frame. Meanwhile each track's prefetcher decodes
///   the exact frames nearest the playhead in the background, as the export does (its reader opens `AVAssetReader`s for
///   that), so the release finds its frame decoded.
/// - `.playing(seconds:)`: the frame of the scene's grid at or before the instant, its videos decoded ahead by each
///   track's `FramePrefetcher` (the frames of the grid after it are scheduled as it goes, and a second ahead the first
///   frame of a track that a block border brings back: `DecodeAhead`, 1c design §14.4); a frame not decoded in time
///   leaves the one before it on screen, and the frame is late. Late for `PreviewQuality.lateWindow` seconds in a row, the
///   preview draws at half the side (`PreviewQuality`, `FrameEvaluator.resized(to:)`) until it pauses.
///
/// Every frame is drawn into a texture of the engine's own at the scene's size (what the tests read: a `framebufferOnly`
/// drawable cannot be read) and reduced on the GPU with a box filter to the layer's drawable, so the layer shows it
/// pixel for pixel (Core Animation would reduce it without mipmaps, and text would shimmer). The layer is the renderer's
/// device, `.bgra8Unorm`, tagged Rec. 709 like the export (as QuickTime shows the MP4), and waits at most a second for a
/// drawable. Whoever drives it asks from a display link (`NSView.displayLink(target:selector:)`) added to the run loop's
/// `.common` modes, so it keeps asking while a slider of the panel is dragged.
///
/// Errors while drawing are logged once each and leave the frame before on screen.
public final class PreviewEngine: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "PreviewEngine")
    /// Frames on the GPU at most: the next one is encoded while the last one is drawn.
    static let framesInFlight = 2

    private let renderer: FrameRenderer
    private let layer: CAMetalLayer
    /// Where frames are evaluated, decoded, drawn and presented, one at a time.
    private let queue = DispatchQueue(label: "dev.toma.PreviewEngine", qos: .userInteractive)
    private let inFlight = DispatchSemaphore(value: PreviewEngine.framesInFlight)
    private let shared: Mutex<Shared>
    /// What only `queue` uses.
    private var drawing: Drawing

    /// What the caller's thread and `queue` share.
    private struct Shared {
        /// The request to draw next, the latest one.
        var pending: PreviewRequest?
        /// The last request, drawn again when the scene changes.
        var last: PreviewRequest?
        /// A job is draining requests on `queue`.
        var draining = false
        /// The scene at the export's size, and a number that changes with it.
        var scene: FrameEvaluator
        var sceneNumber = 0
        var onPresented: (@Sendable (_ seconds: Double, _ late: Bool) -> Void)?
        /// The size of the last frame drawn.
        var drawnSize: SIMD2<Int>?
        /// Tests and the benchmark.
        var hooks = Hooks()
    }

    /// What tests and `recorder-dev bench-preview` look at.
    struct Hooks {
        /// Called on `queue` before each request is drawn.
        var beforeDrawing: (@Sendable (PreviewRequest) -> Void)?
        /// Called once the GPU finished a frame: what it drew, how long it took from the start of its work on `queue`,
        /// and the frames of the videos it showed, by track.
        var onDrawn: (@Sendable (DrawnFrame) -> Void)?
        /// The size to play at instead of `PreviewQuality`'s.
        var playbackSize: SIMD2<Int>?
        /// Whether scrubbing decodes the exact frames ahead (`decodeExactFramesAhead(around:of:)`); off, a test sees what
        /// the scrubbed frames alone read.
        var decodesExactFramesWhileScrubbing = true
    }

    /// A frame the engine drew.
    struct DrawnFrame: @unchecked Sendable {
        var request: PreviewRequest
        var frame: RenderFrame
        /// Seconds from the start of its work on the engine's queue to the end of the GPU's.
        var duration: Double
        var late: Bool
        /// The frames of the videos it showed, by track.
        var videos: [String: CVPixelBuffer]
    }

    private struct Drawing {
        /// The texture frames are drawn into, at the scene's size.
        var target: (any MTLTexture)?
        var downsample: (any MTLRenderPipelineState)?
        var downsampleFailed = false
        /// The frame of each track last drawn, by take and track: what stays on screen while a newer one is not decoded
        /// (never another take's of the same id).
        var shown: [TrackKey: CachedTexture?] = [:]
        /// The frames the last pause decoded exactly, by (track, source instant).
        var exact: [DecodedKey: CachedTexture?] = [:]
        var quality: PreviewQuality
        /// The scene at the quality's size, of scene `number`.
        var sized: (number: Int, scene: FrameEvaluator)?
        /// The number of the scene last made the renderer's.
        var sceneNumber = 0
        /// While scrubbing: the output second of the last scrub, and the frames of the grid decoded ahead for it.
        var lastScrub: Double?
        var decodingAhead: [Int] = []
        /// The tracks those frames show: the imported clips' among them are kept (`releaseMedia(keeping:)`).
        var decodingAheadTracks: Set<TrackKey> = []
        /// While playing: the frame of the grid presented last, of which scene and at which size, and the last one
        /// scheduled ahead.
        var playing: (presented: Int, scene: Int, size: SIMD2<Int>, scheduledThrough: Int)?
        /// While playing: what is scheduled of the frames ahead (`DecodeAhead`).
        var ahead: DecodeAhead?
    }

    /// Shows `renderer`'s frames in `layer`, which it sets up: `renderer.device`, `.bgra8Unorm`, Rec. 709,
    /// `allowsNextDrawableTimeout`. The scene is the renderer's (`FrameRenderer.scene`) until `setScene(_:)`. Whoever
    /// owns the layer sets its `drawableSize` to the view's size in pixels.
    public init(renderer: FrameRenderer, layer: CAMetalLayer) {
        self.renderer = renderer
        self.layer = layer
        let scene = renderer.scene
        shared = Mutex(Shared(scene: scene))
        drawing = Drawing(quality: PreviewQuality(exportSize: scene.outputSize))
        // In a transaction of its own, so it is committed from any thread, one without a run loop too.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.device = renderer.device
        layer.pixelFormat = Compositor.pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        layer.framebufferOnly = true
        layer.allowsNextDrawableTimeout = true
        layer.maximumDrawableCount = 3
        CATransaction.commit()
    }

    /// Called once the GPU finished each frame drawn (presented in the layer when the layer gave a drawable), from a
    /// thread of Metal's: its output second and whether it was late (a video's frame not decoded in time, or frames of the
    /// grid skipped).
    public var onPresented: (@Sendable (_ seconds: Double, _ late: Bool) -> Void)? {
        get { shared.withLock { $0.onPresented } }
        set { shared.withLock { $0.onPresented = newValue } }
    }

    /// Shows `request`, from any thread: returns at once, the frame being drawn on the engine's queue. While a frame is
    /// being drawn, only the latest request is kept. A drag released pauses on the frame of the grid nearest its last
    /// instant, `Int((seconds × frameRate).rounded())`, or the one before it: those are decoded ahead while scrubbing.
    public func request(_ request: PreviewRequest) {
        let start = shared.withLock { shared in
            shared.pending = request
            shared.last = request
            defer { shared.draining = true }
            return !shared.draining
        }
        if start { queue.async { self.drain() } }
    }

    /// Makes `scene` (at the export's size: `FrameRenderer.makeScene(document:paths:outputSize:)`) the one shown, and the
    /// renderer's once the engine's queue gets to it, and draws the last request again with it (the paused frame with a
    /// new revision of the edit). Returns at once, from any thread.
    public func setScene(_ scene: FrameEvaluator) {
        let start = shared.withLock { shared in
            shared.scene = scene
            shared.sceneNumber += 1
            if shared.pending == nil { shared.pending = shared.last }
            guard shared.pending != nil else { return false }
            defer { shared.draining = true }
            return !shared.draining
        }
        if start { queue.async { self.drain() } }
    }

    /// The size of the last frame drawn (`nil` before the first): the export's while paused or scrubbing, and while
    /// playing the one `PreviewQuality` gives.
    public var drawnSize: SIMD2<Int>? { shared.withLock { $0.drawnSize } }

    var hooks: Hooks {
        get { shared.withLock { $0.hooks } }
        set { shared.withLock { $0.hooks = newValue } }
    }

    /// The bytes of the texture the last frame was drawn into (at its scene's size, BGRA, no row padding), once the
    /// frames queued before are drawn: for tests.
    func drawnBytes() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.readTarget() })
            }
        }
    }

    // MARK: - On the engine's queue

    /// Draws the pending requests, the latest each time, until there is none.
    private func drain() {
        while true {
            let next = shared.withLock { shared -> (PreviewRequest, FrameEvaluator, Int, Hooks)? in
                guard let request = shared.pending else {
                    shared.draining = false
                    return nil
                }
                shared.pending = nil
                return (request, shared.scene, shared.sceneNumber, shared.hooks)
            }
            guard let (request, scene, number, hooks) = next else { return }
            if number != drawing.sceneNumber {
                // Here rather than on the caller's thread: the renderer may be busy decoding on this queue.
                renderer.setScene(scene)
                drawing.sceneNumber = number
                // It dropped what was decoded ahead: a scrub schedules the exact frames again.
                drawing.decodingAhead = []
                drawing.decodingAheadTracks = []
                drawing.lastScrub = nil
            }
            hooks.beforeDrawing?(request)
            do {
                try draw(request, scene: scene, number: number, hooks: hooks)
            } catch {
                report(error, "Preview frame not drawn")
            }
        }
    }

    private func draw(_ request: PreviewRequest, scene: FrameEvaluator, number: Int, hooks: Hooks) throws {
        let started = CACurrentMediaTime()
        switch request {
        case let .paused(frame: n):
            stopPlaying()
            drawing.lastScrub = nil
            drawing.decodingAhead = []
            drawing.decodingAheadTracks = []
            let index = clamp(n, scene)
            let seconds = Double(TimeMap.frameTime(index, frameRate: scene.frameRate)) / 1e9
            let frame = try renderer.frame(of: scene, at: seconds)
            let keys = videos(of: frame)
            var exact = try exactFrames(of: keys.filter(needsDecoding))
            for key in keys where exact[key] == nil { exact[key] = drawing.exact[key] }
            drawing.exact = exact
            try present(frame, request: request, seconds: seconds, late: false, started: started, hooks: hooks) { exact[$0] ?? nil }
            releaseMedia(keeping: Set(keys.map(\.track)))
        case let .scrubbing(seconds):
            stopPlaying()
            let frame = try renderer.frame(of: scene, at: seconds)
            var keyFrames: [DecodedKey: CachedTexture?] = [:]
            for key in videos(of: frame) {
                if let keyFrame = try renderer.prefetcher(for: key.track)?.keyFrame(atSource: key.time) {
                    keyFrames[key] = keyFrame
                } else {
                    // None there (before the track's first key frame, or unreadable): the frame shown stays.
                    keyFrames[key] = drawing.shown[key.track] ?? nil
                }
            }
            try present(frame, request: request, seconds: seconds, late: false, started: started, hooks: hooks) {
                keyFrames[$0] ?? nil
            }
            if hooks.decodesExactFramesWhileScrubbing { try decodeExactFramesAhead(around: seconds, of: scene) }
            releaseMedia(keeping: Set(videos(of: frame).map(\.track)).union(drawing.decodingAheadTracks))
        case let .playing(seconds):
            drawing.lastScrub = nil
            drawing.decodingAhead = []
            drawing.decodingAheadTracks = []
            try play(at: seconds, request: request, scene: scene, number: number, started: started, hooks: hooks)
        }
    }

    /// Draws the frame of the grid at or before `seconds`, with the videos decoded ahead, unless it is the one shown.
    private func play(
        at seconds: Double, request: PreviewRequest, scene exportScene: FrameEvaluator, number: Int, started: Double,
        hooks: Hooks
    ) throws {
        if drawing.quality.exportSize != exportScene.outputSize {
            drawing.quality = PreviewQuality(exportSize: exportScene.outputSize)
        }
        let size = hooks.playbackSize ?? drawing.quality.size
        let scene: FrameEvaluator
        if size == exportScene.outputSize {
            scene = exportScene
        } else if let sized = drawing.sized, sized.number == number, sized.scene.outputSize == size {
            scene = sized.scene
        } else {
            scene = exportScene.resized(to: size)
            drawing.sized = (number, scene)
        }
        let rate = Double(scene.frameRate)
        let n = clamp(Int((seconds.isFinite ? seconds * rate + 1e-6 : 0).rounded(.down)), scene)
        let previous = drawing.playing
        // The frame shown already, of this scene at this size.
        if let previous, previous.presented == n, previous.scene == number, previous.size == size { return }
        // A jump, or a new scene (`FrameRenderer.setScene(_:)` dropped what was decoded ahead): schedule again from `n`.
        let jumped = previous.map { n < $0.presented || n > $0.scheduledThrough + 1 || $0.scene != number } ?? true
        if jumped {
            resetPrefetchers()
            drawing.ahead = nil
        }
        let frameSeconds = Double(TimeMap.frameTime(n, frameRate: scene.frameRate)) / 1e9
        let frame = try renderer.frame(of: scene, at: frameSeconds)
        var late = previous.map { n > $0.presented + 1 } ?? false
        var videos: [DecodedKey: CachedTexture?] = [:]
        for key in self.videos(of: frame) {
            if let exact = drawing.exact[key] {
                videos[key] = exact
                continue
            }
            switch try renderer.prefetcher(for: key.track)?.latestFrame(atSource: key.time) {
            case let .onTime(texture)?:
                videos[key] = texture
            case let .late(previous)?:
                late = true
                videos[key] = previous.map(\.frame) ?? drawing.shown[key.track] ?? nil
            case nil:
                videos[key] = .some(nil)
            }
        }
        // The frames of the grid after it, scheduled in order, and a second ahead the first frame of a track that comes
        // back at a block border (1c design §14.4): it is decoded before the transition needs it.
        let last = scene.timeMap.frameCount(frameRate: scene.frameRate) - 1
        var ahead = drawing.ahead ?? DecodeAhead(frameRate: scene.frameRate)
        let keys = try ahead.advance(to: n, last: last, first: 1) { next in
            self.videos(of: try renderer.frame(of: scene, at: Double(TimeMap.frameTime(next, frameRate: scene.frameRate)) / 1e9))
        }
        drawing.ahead = ahead
        for key in keys where drawing.exact[key] == nil {
            try renderer.prefetcher(for: key.track)?.schedule(key.time)
        }
        drawing.playing = (n, number, size, max(ahead.scheduledThrough ?? n, n))
        // The imported clips neither this frame nor those a second ahead show are let go.
        releaseMedia(keeping: Set(self.videos(of: frame).map(\.track)).union(ahead.tracksAhead))
        // The first frame of a playback is not late: nothing was decoded ahead for it.
        if previous == nil { late = false }
        _ = drawing.quality.record(late: late, atSeconds: CACurrentMediaTime())
        try present(frame, request: request, seconds: frameSeconds, late: late, started: started, hooks: hooks) { videos[$0] ?? nil }
    }

    /// The frames of `keys`, decoded exactly as the export decodes them (`TrackFrameReader.pixelBuffer(at:)`, through each
    /// track's prefetcher), the tracks at once: a frame decoded ahead while scrubbing is taken as it is, one being decoded
    /// is waited for. Blocks this queue while the prefetchers decode on theirs; no Swift concurrency thread takes part.
    private func exactFrames(of keys: [DecodedKey]) throws -> [DecodedKey: CachedTexture?] {
        let decoded = DecodedFrames()
        let group = DispatchGroup()
        for key in keys {
            guard let prefetcher = try renderer.prefetcher(for: key.track) else {
                decoded.set(key, .success(nil))
                continue
            }
            group.enter()
            prefetcher.frame(atSource: key.time) { result in
                decoded.set(key, result)
                group.leave()
            }
        }
        group.wait()
        return try decoded.all.mapValues { try $0.get() }
    }

    /// While scrubbing, the frame of the grid nearest `seconds` (the one a release there pauses on) and the one before it
    /// are decoded exactly in the background by each track's prefetcher, the latest scrub replacing what was asked
    /// before (unless it asks the same frames, which stay): a release finds its frame decoded, or being decoded, or the
    /// reader just before it, where reading on costs a few frames. Dragged back, decoding starts as far back again as the
    /// drag moved since the last scrub, so the reader stays before where a release can land (a decoder never steps back
    /// without starting over from a key frame). The key frames shown meanwhile are decoded on this queue, apart.
    private func decodeExactFramesAhead(around seconds: Double, of scene: FrameEvaluator) throws {
        let rate = Double(scene.frameRate)
        let nearest = clamp(Int((seconds.isFinite ? seconds * rate : 0).rounded()), scene)
        let moved = drawing.lastScrub.map { (seconds - $0) * rate } ?? 0
        drawing.lastScrub = seconds
        let lead = moved < 0 && moved.isFinite ? min(Int((-2 * moved).rounded(.up)), 2 * scene.frameRate) : 0
        let frames = Set([nearest - lead, nearest - 1, nearest].map { clamp($0, scene) }).sorted()
        guard frames != drawing.decodingAhead else { return }
        drawing.decodingAhead = frames
        drawing.decodingAheadTracks = []
        resetPrefetchers()
        for n in frames {
            let frame = try renderer.frame(of: scene, at: Double(TimeMap.frameTime(n, frameRate: scene.frameRate)) / 1e9)
            for key in videos(of: frame) {
                drawing.decodingAheadTracks.insert(key.track)
                guard drawing.exact[key] == nil else { continue }
                try renderer.prefetcher(for: key.track)?.schedule(key.time)
            }
        }
    }

    /// Whether the frame of `key` is to be decoded for a pause: one the last pause did not decode, or an imported clip's
    /// it found none of (its file gave no frame then: its reader is made again after a while, `MediaClipResources`).
    private func needsDecoding(_ key: DecodedKey) -> Bool {
        switch drawing.exact[key] {
        case nil: true
        case .some(.none): FrameRenderer.isMedia(key.track)
        case .some(.some): false
        }
    }

    /// Lets go of the imported clips' readers and prefetchers that `kept` does not name (`FrameRenderer.releaseMedia(keeping:)`),
    /// and of the frames of theirs the engine keeps (shown, or decoded for a pause).
    private func releaseMedia(keeping kept: Set<TrackKey>) {
        let released = Set(renderer.releaseMedia(keeping: kept))
        guard !released.isEmpty else { return }
        for track in released { drawing.shown[track] = nil }
        drawing.exact = drawing.exact.filter { !released.contains($0.key.track) }
    }

    /// Leaves playback: nothing more is decoded ahead, and the next playback starts at the export's size.
    private func stopPlaying() {
        guard drawing.playing != nil else { return }
        drawing.playing = nil
        drawing.quality.reset()
        resetPrefetchers()
    }

    private func resetPrefetchers() {
        renderer.resetPrefetchers()
    }

    /// The (track, source instant) of each video `frame` shows: the screen, the screen being left, the camera, then what
    /// the camera is drawn with (the renderer's, `FrameRenderer.videos(of:)`).
    private func videos(of frame: RenderFrame) -> [DecodedKey] {
        renderer.videos(of: frame)
    }

    /// `n` within the frames of `scene`'s grid.
    private func clamp(_ n: Int, _ scene: FrameEvaluator) -> Int {
        min(max(n, 0), max(scene.timeMap.frameCount(frameRate: scene.frameRate) - 1, 0))
    }

    /// Draws `frame` with the videos `video` gives into the engine's texture, reduces it into the layer's next drawable
    /// and presents it; `onPresented` and the hooks are told once the GPU is done.
    private func present(
        _ frame: RenderFrame, request: PreviewRequest, seconds: Double, late: Bool, started: Double, hooks: Hooks,
        video: (DecodedKey) -> CachedTexture?
    ) throws {
        let target = try target(size: frame.outputSize)
        inFlight.wait()
        var committed = false
        defer { if !committed { inFlight.signal() } }
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            throw RenderError.metalResourceUnavailable("preview command buffer")
        }
        commandBuffer.label = "PreviewEngine"
        var shown: [TrackKey: CachedTexture?] = [:]
        try renderer.encode(frame, into: target, commandBuffer: commandBuffer) { track, time in
            let texture = video(DecodedKey(track, time: time))
            shown[track] = texture
            return texture
        }
        if let drawable = layer.nextDrawable() {
            try downsample(target, into: drawable.texture, commandBuffer: commandBuffer)
            commandBuffer.present(drawable)
        }
        drawing.shown.merge(shown) { $1 }
        let onPresented = shared.withLock { shared in
            shared.drawnSize = frame.outputSize
            return shared.onPresented
        }
        // By track: a frame shows the tracks of one take.
        var videos: [String: CVPixelBuffer] = [:]
        for case let (key, texture?) in shown { videos[key.track] = texture.pixelBuffer }
        let drawn = DrawnFrame(request: request, frame: frame, duration: 0, late: late, videos: videos)
        commandBuffer.addCompletedHandler { [inFlight, weak self] commandBuffer in
            inFlight.signal()
            if commandBuffer.status != .completed {
                self?.report(RenderError.gpuFailed(commandBuffer.error.map { String(describing: $0) } ?? "status \(commandBuffer.status.rawValue)"),
                             "Preview frame failed on the GPU")
                return
            }
            var done = drawn
            done.duration = CACurrentMediaTime() - started
            hooks.onDrawn?(done)
            onPresented?(seconds, late)
        }
        commandBuffer.commit()
        committed = true
    }

    /// The engine's texture, `size` big.
    private func target(size: SIMD2<Int>) throws -> any MTLTexture {
        if let target = drawing.target, target.width == size.x, target.height == size.y { return target }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: size.x, height: size.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard size.x > 0, size.y > 0, let target = renderer.device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("preview target \(size.x) × \(size.y)")
        }
        target.label = "PreviewEngine target"
        drawing.target = target
        return target
    }

    /// Reduces `source` into `drawable` with a box filter (each pixel the average of the texels it covers, in their
    /// share), or enlarges it bilinearly.
    private func downsample(_ source: any MTLTexture, into drawable: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        let pipeline = try downsamplePipeline()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.metalResourceUnavailable("preview downsample pass")
        }
        encoder.label = "PreviewEngine downsample"
        var scale = SIMD2<Float>(Float(source.width) / Float(drawable.width), Float(source.height) / Float(drawable.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func downsamplePipeline() throws -> any MTLRenderPipelineState {
        if let pipeline = drawing.downsample { return pipeline }
        let device = renderer.device
        let library = try device.makeLibrary(source: Self.downsampleSource, options: nil)
        guard let vertex = library.makeFunction(name: "previewVertex") else { throw RenderError.missingShaderFunction("previewVertex") }
        guard let fragment = library.makeFunction(name: "previewBoxFragment") else {
            throw RenderError.missingShaderFunction("previewBoxFragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Compositor.pixelFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        drawing.downsample = pipeline
        return pipeline
    }

    /// One triangle over the drawable; each pixel is the box average of the source's texels it covers (`scale` texels of
    /// the source per pixel on each axis), or, enlarging on both axes, the bilinear sample at its centre.
    static let downsampleSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct PreviewVertexOut { float4 position [[position]]; };

        vertex PreviewVertexOut previewVertex(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            PreviewVertexOut out;
            out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
            return out;
        }

        fragment float4 previewBoxFragment(PreviewVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                           constant float2 &scale [[buffer(0)]]) {
            float2 size = float2(source.get_width(), source.get_height());
            if (scale.x <= 1.0 && scale.y <= 1.0) {
                constexpr sampler linear(filter::linear, address::clamp_to_edge);
                return source.sample(linear, in.position.xy * scale / size);
            }
            float2 low = floor(in.position.xy) * scale;
            float2 high = min(low + scale, size);
            int2 first = int2(floor(low));
            int2 last = int2(ceil(high)) - 1;
            float4 sum = 0.0;
            float total = 0.0;
            for (int y = first.y; y <= last.y; y++) {
                float wy = min(high.y, float(y + 1)) - max(low.y, float(y));
                for (int x = first.x; x <= last.x; x++) {
                    float w = (min(high.x, float(x + 1)) - max(low.x, float(x))) * wy;
                    sum += source.read(uint2(x, y)) * w;
                    total += w;
                }
            }
            return total > 0.0 ? sum / total : float4(0.0, 0.0, 0.0, 1.0);
        }
        """

    /// The bytes of the engine's texture, once the GPU finished what was committed. Runs on `queue`.
    private func readTarget() throws -> [UInt8] {
        guard let target = drawing.target else { return [] }
        let bytesPerRow = target.width * 4
        guard let buffer = renderer.device.makeBuffer(length: bytesPerRow * target.height, options: .storageModeShared),
              let commandBuffer = renderer.commandQueue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw RenderError.metalResourceUnavailable("preview readback") }
        blit.copy(
            from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: target.width, height: target.height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * target.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return [UInt8](UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length))
    }

    private func report(_ error: any Error, _ context: String) {
        let description = String(describing: error)
        guard drawingReported(description) else { return }
        Self.logger.error("\(context, privacy: .public): \(description, privacy: .public)")
    }

    /// Whether `description` is reported for the first time.
    private let reportedErrors = Mutex<Set<String>>([])
    private func drawingReported(_ description: String) -> Bool {
        reportedErrors.withLock { $0.insert(description).inserted }
    }
}

/// The frames `exactFrames(of:)` gathers from the prefetchers' queues.
private final class DecodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [DecodedKey: Result<CachedTexture?, RenderError>] = [:]

    func set(_ key: DecodedKey, _ frame: Result<CachedTexture?, RenderError>) {
        lock.withLock { frames[key] = frame }
    }

    var all: [DecodedKey: Result<CachedTexture?, RenderError>] { lock.withLock { frames } }
}
