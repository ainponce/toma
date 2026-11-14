// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import Metal
import ProjectFormat

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
}

/// Renders frames of a take: the one drawing path behind the editor preview and the MP4 export.
///
/// A frame is a function of the project and the output time alone (`FrameEvaluator`), drawn by
/// `Compositor` over the screen frame `TrackFrameReader` decodes for that time. Every way to draw —
/// `render(at:into:)`, `renderBytes(at:)` and `PreviewRenderer` — goes through `encode(at:into:commandBuffer:)`.
///
/// Use one renderer per consumer: the preview and an export each make their own. A renderer keeps one
/// decoder position for its screen track, so two consumers reading different times would keep sending
/// it back and forth, reopening a reader for nearly every frame.
///
/// Decoding is synchronous, on the caller's thread: the first frame read from each segment loads its
/// track and decodes from the keyframe before it, and so does every scrub (a step back, or a jump of
/// 2 s or more). Reading forward frame by frame only decodes the frames in between.
///
/// Thread-safe: frames are encoded one at a time.
public final class FrameRenderer: @unchecked Sendable {
    public let outputSize: SIMD2<Int>
    /// The device everything is drawn with; a view showing the preview must use it too.
    public let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    private let evaluator: FrameEvaluator
    private let reader: TrackFrameReader?
    private let compositor: Compositor
    private let cursorTexture: any MTLTexture
    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()

    /// Output seconds the take lasts.
    public var duration: Double { evaluator.duration }

    /// The spans of the screen shown with the frame before them so far, because a segment could not be
    /// decoded there (`TrackFrameReader`), in output seconds clamped to `[0, duration]`, in time order. After
    /// drawing every frame of the timeline in order (an export), it lists every such span of the output.
    public var missingVideo: [MissingVideo] {
        let start = evaluator.timelineStart, duration = evaluator.duration
        return (reader?.gaps ?? [])
            .compactMap { gap -> MissingVideo? in
                let from = gap.start.seconds(since: start), to = gap.end.seconds(since: start)
                guard to >= 0, from <= duration else { return nil }
                let clamped = min(max(from, 0), duration)
                return MissingVideo(file: gap.file, start: clamped, end: max(clamped, min(to, duration)), reason: gap.reason)
            }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Opens nothing yet: segments are read as frames need them, and unreadable ones are gaps.
    /// - Parameter device: the system default device when `nil`.
    /// - Throws: `RenderError.noMetalDevice` without a Metal device, `invalidOutputSize`, and the
    ///   errors of `Compositor.init` and `CursorSprite.makeTexture`.
    public init(project: LoadedProject, outputSize: SIMD2<Int>, device: (any MTLDevice)? = nil) throws {
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
        self.outputSize = outputSize
        self.device = device
        self.commandQueue = commandQueue
        textureCache = cache
        compositor = try Compositor(device: device)
        cursorTexture = try CursorSprite.makeTexture(device: device)
        evaluator = FrameEvaluator(take: project.take, events: project.events, style: StyleV0(), outputSize: outputSize)
        reader = evaluator.screenTrackID
            .flatMap { project.take.track($0) }
            .map { TrackFrameReader(package: project.package, track: $0) }
    }

    /// Encodes the frame at `outputTime` into `target`, which must be `.bgra8Unorm` and `outputSize` big
    /// (otherwise this throws and encodes nothing). The caller commits `commandBuffer`.
    public func encode(at outputTime: Double, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        let size = SIMD2(target.width, target.height)
        guard size == outputSize else { throw RenderError.targetSizeMismatch(expected: outputSize, actual: size) }
        guard target.pixelFormat == Compositor.pixelFormat else { throw RenderError.unsupportedPixelFormat }
        try lock.withLock {
            CVMetalTextureCacheFlush(textureCache, 0)
            let frame = evaluator.frame(at: outputTime)
            var screen: (any MTLTexture)?
            if let layer = frame.screen, let pixelBuffer = reader?.pixelBuffer(at: layer.sourceTime) {
                let texture = try metalTexture(for: pixelBuffer)
                screen = texture.texture
                commandBuffer.addCompletedHandler { _ in withExtendedLifetime(texture) {} }
            }
            compositor.encode(frame, screen: screen, cursor: cursorTexture, into: target, commandBuffer: commandBuffer)
        }
    }

    /// Draws the frame at `outputTime` into `pixelBuffer` (32BGRA, IOSurface-backed, `outputSize` big)
    /// and waits for the GPU to finish.
    public func render(at outputTime: Double, into pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw RenderError.unsupportedPixelFormat
        }
        let size = SIMD2(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        guard size == outputSize else { throw RenderError.targetSizeMismatch(expected: outputSize, actual: size) }
        let target = try lock.withLock { try metalTexture(for: pixelBuffer) }
        let commandBuffer = try makeCommandBuffer()
        try encode(at: outputTime, into: target.texture, commandBuffer: commandBuffer)
        try finish(commandBuffer)
        withExtendedLifetime(target) {}
    }

    /// The frame at `outputTime` as BGRA bytes, `outputSize.x × 4` per row with no padding.
    public func renderBytes(at outputTime: Double) throws -> [UInt8] {
        try renderOffscreen { target, commandBuffer in
            try encode(at: outputTime, into: target, commandBuffer: commandBuffer)
        }
    }

    /// Runs `draw` on a new `.bgra8Unorm` texture of `outputSize`, waits for the GPU and returns the
    /// texture's bytes without row padding.
    func renderOffscreen(_ draw: (any MTLTexture, any MTLCommandBuffer) throws -> Void) throws -> [UInt8] {
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
        guard commandBuffer.status == .completed else {
            throw RenderError.gpuFailed(commandBuffer.error.map { String(describing: $0) } ?? "status \(commandBuffer.status.rawValue)")
        }
    }

    /// `pixelBuffer` as a `.bgra8Unorm` texture sharing its memory, through the texture cache. The
    /// `CVMetalTexture` must outlive every use of its texture by the GPU. Call with `lock` held.
    private func metalTexture(for pixelBuffer: CVPixelBuffer) throws -> CachedTexture {
        var created: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, Compositor.pixelFormat,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &created)
        guard status == kCVReturnSuccess, let created, let texture = CVMetalTextureGetTexture(created) else {
            throw RenderError.textureCreationFailed(status)
        }
        return CachedTexture(cvTexture: created, pixelBuffer: pixelBuffer, texture: texture)
    }
}

/// A texture from the texture cache, with what keeps its memory alive: held until the GPU is done with it.
private final class CachedTexture: @unchecked Sendable {
    let cvTexture: CVMetalTexture
    let pixelBuffer: CVPixelBuffer
    let texture: any MTLTexture

    init(cvTexture: CVMetalTexture, pixelBuffer: CVPixelBuffer, texture: any MTLTexture) {
        self.cvTexture = cvTexture
        self.pixelBuffer = pixelBuffer
        self.texture = texture
    }
}
