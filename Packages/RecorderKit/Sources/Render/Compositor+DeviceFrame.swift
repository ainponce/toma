// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the device frame (phase 2 design §6.7), made with the compositor's (`LayerPipelines`): none in
/// milestone 2b's seam. Task I3 fills them here.
struct DeviceFramePipelines {
    init(maker: PipelineMaker) throws {}
}

extension Compositor {
    /// Draws the device `layer` around the screen through `stage` (as it is when `nil`) in an output of `outputSize`, into
    /// `pass`, counting it in `counts.deviceFrames`: in `drawFrame`, step 1 of phase 2 design §11, right after the window
    /// frame and before the screen. Nothing without one: always in the seam.
    func drawDeviceFrame(
        _ layer: DeviceFrameLayer?, through stage: StageTransform?, outputSize: SIMD2<Int>, pass: LayerPass,
        encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        guard layer != nil else { return }
    }

    /// Draws what of the device `layer` goes over the screen (the iPhone's island, the MacBook's notch) through `stage`,
    /// the frame's transform of the device (the stage's zoom on the stage, the background's in a card; as it is when
    /// `nil`), in an output of `outputSize`, into `pass`, counting it in `counts.deviceOverlays`: first in
    /// `drawOverTheStage`, once and never blurred, over the cursor and under the click effects (plan 2b decision 10).
    /// Nothing without one: always in the seam.
    func drawDeviceOverlay(
        _ layer: DeviceFrameLayer?, through stage: StageTransform?, outputSize: SIMD2<Int>, pass: LayerPass,
        encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        guard layer != nil else { return }
    }
}
