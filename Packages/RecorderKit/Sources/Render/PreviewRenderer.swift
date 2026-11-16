// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import MetalKit
import QuartzCore
import Synchronization
import os

/// Drives an `MTKView` showing the preview, through the same `FrameRenderer` the export uses.
///
/// `configure(_:)` sets the view up: `renderer.device`, `.bgra8Unorm`, a drawable of `renderer.outputSize`
/// that does not follow the view's size. A drawable of another size is not drawn (and logged once).
/// `renderPreview` is the one drawing call, used by `draw(in:)` and by `snapshot(at:)`. Errors while
/// drawing or on the GPU are logged once each, not on every frame.
///
/// Drawing decodes frames synchronously (`TrackFrameReader`), so it blocks: never call `snapshot(at:)` or
/// `renderPreview` from a Swift concurrency thread. `PreviewPreparation` prepares one on its own queue.
public final class PreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "PreviewRenderer")
    /// How often Debug builds log the average frame rate, in seconds.
    static let frameRateLogInterval = 5.0

    private let renderer: FrameRenderer
    private let playback = Mutex(Playback())
    /// Descriptions of the errors already logged.
    private let reportedErrors = Mutex<Set<String>>([])

    private struct Playback {
        var currentTime = 0.0
        var isPlaying = false
        /// `CACurrentMediaTime()` of the last frame drawn while playing.
        var lastTick: CFTimeInterval?
        var windowStart: CFTimeInterval?
        var framesInWindow = 0
    }

    public init(renderer: FrameRenderer) {
        self.renderer = renderer
    }

    /// The output time shown, clamped to `[0, renderer.duration]`. Playing moves it forward in real time.
    public var currentTime: Double {
        get { playback.withLock { $0.currentTime } }
        set {
            let time = newValue.isNaN ? 0 : min(max(newValue, 0), renderer.duration)
            playback.withLock { $0.currentTime = time }
        }
    }

    /// Whether `draw(in:)` advances `currentTime`. Playback stops by itself at the end.
    public var isPlaying: Bool {
        get { playback.withLock { $0.isPlaying } }
        set {
            playback.withLock {
                $0.isPlaying = newValue
                $0.lastTick = nil  // the next frame starts counting time
            }
        }
    }

    /// Encodes the frame at `outputTime` into `target`; throws like `FrameRenderer.encode`.
    public func renderPreview(at outputTime: Double, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        try renderer.encode(at: outputTime, into: target, commandBuffer: commandBuffer)
    }

    /// The frame at `outputTime` of the renderer's scene (`FrameRenderer.scene`), drawn as `renderPreview` draws it into
    /// an offscreen `.bgra8Unorm` texture of that scene's size, as BGRA bytes with no row padding.
    public func snapshot(at outputTime: Double) throws -> [UInt8] {
        let scene = renderer.scene
        return try renderer.renderOffscreen(size: scene.outputSize) { target, commandBuffer in
            try renderer.encode(scene: scene, at: outputTime, into: target, commandBuffer: commandBuffer)
        }
    }

    /// Makes `view` show the preview: the renderer's device, `.bgra8Unorm` drawables of exactly
    /// `renderer.outputSize` (scaled to the view by its layer), tagged Rec. 709 like the export, and this
    /// object as its delegate. The view keeps the delegate weakly: keep this object alive while it shows.
    @MainActor
    public func configure(_ view: MTKView) {
        view.device = renderer.device
        view.colorPixelFormat = Compositor.pixelFormat
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: renderer.outputSize.x, height: renderer.outputSize.y)
        view.framebufferOnly = true
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        view.delegate = self
    }

    @MainActor
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    @MainActor
    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let duration = renderer.duration
        let time = playback.withLock { state -> Double in
            if state.isPlaying {
                if let last = state.lastTick {
                    state.currentTime = min(state.currentTime + (now - last), duration)
                }
                state.lastTick = now
                if state.currentTime >= duration {
                    state.isPlaying = false
                    state.lastTick = nil
                }
            }
            return state.currentTime
        }
        // Checked before taking a drawable, which a misconfigured view would otherwise hold for nothing.
        let drawableSize = SIMD2(Int(view.drawableSize.width), Int(view.drawableSize.height))
        guard drawableSize == renderer.outputSize else {
            reportOnce(RenderError.targetSizeMismatch(expected: renderer.outputSize, actual: drawableSize), "Preview not drawn")
            return
        }
        guard let drawable = view.currentDrawable, let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            return
        }
        do {
            try renderPreview(at: time, into: drawable.texture, commandBuffer: commandBuffer)
        } catch {
            reportOnce(error, "Preview not drawn")
            return
        }
        commandBuffer.addCompletedHandler { [weak self] commandBuffer in
            if let error = commandBuffer.error { self?.reportOnce(error, "Preview frame failed on the GPU") }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        #if DEBUG
        logFrameRate(at: now)
        #endif
    }

    /// Logs `error` the first time it is seen; returns whether it did.
    @discardableResult
    func reportOnce(_ error: any Error, _ context: String) -> Bool {
        let description = String(describing: error)
        guard reportedErrors.withLock({ $0.insert(description).inserted }) else { return false }
        Self.logger.error("\(context, privacy: .public): \(description, privacy: .public)")
        return true
    }

    /// How many distinct errors have been logged, for tests.
    var reportedErrorCount: Int { reportedErrors.withLock { $0.count } }

    #if DEBUG
    private func logFrameRate(at now: CFTimeInterval) {
        let average: Double? = playback.withLock { state in
            guard let start = state.windowStart else {
                state.windowStart = now
                state.framesInWindow = 0
                return nil
            }
            state.framesInWindow += 1
            let elapsed = now - start
            guard elapsed >= Self.frameRateLogInterval else { return nil }
            let fps = Double(state.framesInWindow) / elapsed
            state.windowStart = now
            state.framesInWindow = 0
            return fps
        }
        if let average {
            Self.logger.debug("Preview: \(average, format: .fixed(precision: 1)) fps on average over the last \(Self.frameRateLogInterval) s")
        }
    }
    #endif
}
