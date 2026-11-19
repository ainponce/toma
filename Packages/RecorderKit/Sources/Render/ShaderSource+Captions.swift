// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of the captions (phase 2 design §5.2), over everything (§11, step 6): their
    /// texture (`CaptionTextures`), premultiplied, drawn over the whole pixels it covers one texel a pixel, read and never
    /// filtered, so the text is exactly as CoreText drew it at the output's resolution.
    /// - `captionFragment`: straight into the target.
    /// - `captionTargetFragment`: into the target of the motion blur's pass (the core's `TargetOut`), over its average.
    static let captionsMetal = #"""

    // The texel of the caption's texture under the pixel at p: the quad is its region, whole pixels from contentOrigin.
    static float4 captionTexel(float2 p, constant QuadUniforms &u, texture2d<float> caption) {
        float2 last = float2(caption.get_width(), caption.get_height()) - 1.0;
        uint2 texel = uint2(clamp(floor(p - u.contentOrigin), float2(0.0), last));
        return caption.read(texel);
    }

    fragment float4 captionFragment(QuadOut in [[stage_in]],
                                    constant QuadUniforms &u [[buffer(0)]],
                                    texture2d<float> caption [[texture(0)]]) {
        return captionTexel(in.p, u, caption);
    }

    // The caption into the target of the motion blur's pass.
    fragment TargetOut captionTargetFragment(QuadOut in [[stage_in]],
                                             constant QuadUniforms &u [[buffer(0)]],
                                             texture2d<float> caption [[texture(0)]]) {
        TargetOut out;
        out.color = captionTexel(in.p, u, caption);
        return out;
    }
    """#
}
