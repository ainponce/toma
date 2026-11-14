// SPDX-License-Identifier: GPL-3.0-or-later
import MetalKit
import Render
import SwiftUI
import os

/// The editor's preview: an `MTKView` that `PreviewRenderer` draws, at the renderer's output size scaled
/// to fit. While playing, the view's timer draws every frame and the renderer moves the time forward;
/// paused, it draws only when the time shown changes.
struct PreviewView: NSViewRepresentable {
    let preview: PreviewRenderer
    let isPlaying: Bool
    /// The output time the editor shows; a change makes SwiftUI update the view, which redraws it if paused
    /// and the renderer's time is not the one last drawn.
    let time: Double
    /// Called on the main thread after every frame drawn.
    let onDraw: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(preview: preview)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        // Device, `.bgra8Unorm`, a fixed drawable of `renderer.outputSize` and the Rec. 709 color space.
        preview.configure(view)
        // `configure` made the renderer the delegate: draw through the coordinator, which times each frame.
        view.delegate = context.coordinator
        view.layer?.contentsGravity = .resizeAspect
        view.preferredFramesPerSecond = 60
        context.coordinator.onDraw = onDraw
        apply(isPlaying, to: view)
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.onDraw = onDraw
        apply(isPlaying, to: view)
        // Paused, a new frame is drawn only when the time shown changes.
        if !isPlaying, context.coordinator.lastDrawnTime != preview.currentTime { view.needsDisplay = true }
    }

    /// Playing: the view's own timer draws. Paused: it draws when it needs display.
    private func apply(_ playing: Bool, to view: MTKView) {
        guard view.isPaused == playing else { return }
        view.isPaused = !playing
        view.enableSetNeedsDisplay = !playing
    }

    /// Forwards to `PreviewRenderer` and logs frames that take longer than one refresh at 60 Hz: decoding
    /// runs on the main thread, so a scrub (a jump back, or forward by 2 s or more) shows up here.
    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Preview")
        private static let slowFrame = Duration.milliseconds(17)

        let preview: PreviewRenderer
        var onDraw: @MainActor () -> Void = {}
        /// The output time of the last frame drawn.
        private(set) var lastDrawnTime: Double?

        init(preview: PreviewRenderer) {
            self.preview = preview
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            preview.mtkView(view, drawableSizeWillChange: size)
        }

        func draw(in view: MTKView) {
            let time = preview.currentTime
            let start = ContinuousClock.now
            preview.draw(in: view)
            let elapsed = ContinuousClock.now - start
            lastDrawnTime = preview.currentTime  // where playing moved it to
            if elapsed > Self.slowFrame {
                let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                Self.logger.debug("Frame at \(time, format: .fixed(precision: 2)) s took \(milliseconds, format: .fixed(precision: 1)) ms on the main thread")
            }
            onDraw()
        }
    }
}
