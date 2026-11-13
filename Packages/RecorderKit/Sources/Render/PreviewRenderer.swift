// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import MetalKit
import QuartzCore
import Synchronization
import os

/// Drives an `MTKView` showing the preview, through the same `FrameRenderer` the export uses.
///
/// The view must use `renderer.device`, draw `.bgra8Unorm` and keep its drawable at `renderer.outputSize`
/// (`autoResizeDrawable = false`); a drawable of another size is not drawn. `renderPreview` is the one
/// drawing call, used by `draw(in:)` and by `snapshot(at:)`.
public final class PreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "PreviewRenderer")
    /// How often Debug builds log the average frame rate, in seconds.
    static let frameRateLogInterval = 5.0

    private let renderer: FrameRenderer
    private let playback = Mutex(Playback())

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

    /// The frame at `outputTime` drawn by `renderPreview` into an offscreen `.bgra8Unorm` texture of
    /// `renderer.outputSize`, as BGRA bytes with no row padding.
    public func snapshot(at outputTime: Double) throws -> [UInt8] {
        try renderer.renderOffscreen { target, commandBuffer in
            try renderPreview(at: outputTime, into: target, commandBuffer: commandBuffer)
        }
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
        guard let drawable = view.currentDrawable, let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            return
        }
        do {
            try renderPreview(at: time, into: drawable.texture, commandBuffer: commandBuffer)
        } catch {
            Self.logger.error("Preview frame at \(time) s not drawn: \(String(describing: error), privacy: .public)")
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        #if DEBUG
        logFrameRate(at: now)
        #endif
    }

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
