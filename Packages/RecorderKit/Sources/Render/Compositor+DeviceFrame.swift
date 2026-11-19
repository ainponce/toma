// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the device frame (phase 2 design §6.7), made with the compositor's (`LayerPipelines`): none in the
/// base of phase 2. Milestone 2b fills them here.
struct DeviceFramePipelines {
    init(maker: PipelineMaker) throws {}
}

extension Compositor {
    /// Draws the device `layer` around the screen through `stage` (as it is when `nil`) in an output of `outputSize`, into
    /// `pass`, counting it in `counts.deviceFrames`: in `drawFrame`, step 1 of phase 2 design §11, right after the window
    /// frame. Nothing without one: always in the base.
    func drawDeviceFrame(
        _ layer: DeviceFrameLayer?, through stage: StageTransform?, outputSize: SIMD2<Int>, pass: LayerPass,
        encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        guard layer != nil else { return }
    }
}
