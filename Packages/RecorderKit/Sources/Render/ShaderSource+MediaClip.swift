// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of an imported clip of the sequence (phase 3 design §5.4 and §12, step 2), drawn
    /// where the screens are: its frame, bilinear and opaque over its rounded rect (the core's `imageCoverage`, as the
    /// screen), read through the clip's orientation (`MediaOrientation`: the texture coordinates of the upright picture's
    /// top-left corner and along its sides), so a clip a player turns upright is drawn upright. Its shadow is the core's
    /// camera's, under it (`cameraShadowFragment`, `cameraShadowTargetFragment`, at opacity 1).
    /// - `mediaClipFragment`: straight into the target, or into a subsample's attachment.
    /// - `mediaClipTargetFragment`: into the target of the motion blur's pass (the core's `TargetOut`).
    static let mediaClipMetal = #"""

    struct MediaClipUniforms {
        float2 origin;   // texture coordinates at the upright picture's top-left corner
        float2 across;   // per unit of its width
        float2 down;     // per unit of its height
        float2 padding;
    };

    // The clip's frame at the pixel at p, over its image (`imageCoverage`): the fraction of the picture under it, through
    // the orientation, sampled bilinear, opaque.
    static float4 mediaClipColor(QuadOut in, constant QuadUniforms &u, constant MediaClipUniforms &m,
                                 texture2d<float> frame, sampler linearSampler) {
        float coverage = imageCoverage(in.p, u);
        float2 d = (in.p - u.contentOrigin) / u.contentSize;
        float2 uv = m.origin + d.x * m.across + d.y * m.down;
        float3 color = frame.sample(linearSampler, uv).rgb;
        return float4(color, 1.0) * coverage;
    }

    fragment float4 mediaClipFragment(QuadOut in [[stage_in]],
                                      constant QuadUniforms &u [[buffer(0)]],
                                      constant MediaClipUniforms &m [[buffer(1)]],
                                      texture2d<float> frame [[texture(0)]],
                                      sampler linearSampler [[sampler(0)]]) {
        return mediaClipColor(in, u, m, frame, linearSampler);
    }

    // The clip into the target of the motion blur's pass.
    fragment TargetOut mediaClipTargetFragment(QuadOut in [[stage_in]],
                                               constant QuadUniforms &u [[buffer(0)]],
                                               constant MediaClipUniforms &m [[buffer(1)]],
                                               texture2d<float> frame [[texture(0)]],
                                               sampler linearSampler [[sampler(0)]]) {
        TargetOut out;
        out.color = mediaClipColor(in, u, m, frame, linearSampler);
        return out;
    }
    """#
}
