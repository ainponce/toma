// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of a title card (phase 3 design §5.2 and §12, `titleCard-1`), in the place of steps
    /// 1 to 6, over what its frame drew and under the output's annotations:
    /// - `titleCardFillFragment`: its fill or its veil, a premultiplied colour, over the whole target (with
    ///   `gradientVertex`).
    /// - `titleCardTextFragment`: its texts' texture (`TitleCardTextures`), premultiplied, over the whole pixels it covers
    ///   one texel a pixel, read and never filtered, times the card's opacity, so the text is exactly as CoreText drew it
    ///   at the output's resolution.
    /// - `…TargetFragment`: the same into the target of the motion blur's pass (the core's `TargetOut`), over its average.
    static let titleCardMetal = #"""

    fragment float4 titleCardFillFragment(GradientOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
        return color;
    }

    fragment TargetOut titleCardFillTargetFragment(GradientOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
        TargetOut out;
        out.color = color;
        return out;
    }

    // The texel of the card's texture under the pixel at p, times the card's opacity: the quad is its region, whole pixels
    // from contentOrigin.
    static float4 titleCardTexel(float2 p, constant QuadUniforms &u, float opacity, texture2d<float> text) {
        float2 last = float2(text.get_width(), text.get_height()) - 1.0;
        uint2 texel = uint2(clamp(floor(p - u.contentOrigin), float2(0.0), last));
        return text.read(texel) * opacity;
    }

    fragment float4 titleCardTextFragment(QuadOut in [[stage_in]],
                                          constant QuadUniforms &u [[buffer(0)]],
                                          constant float &opacity [[buffer(1)]],
                                          texture2d<float> text [[texture(0)]]) {
        return titleCardTexel(in.p, u, opacity, text);
    }

    fragment TargetOut titleCardTextTargetFragment(QuadOut in [[stage_in]],
                                                   constant QuadUniforms &u [[buffer(0)]],
                                                   constant float &opacity [[buffer(1)]],
                                                   texture2d<float> text [[texture(0)]]) {
        TargetOut out;
        out.color = titleCardTexel(in.p, u, opacity, text);
        return out;
    }
    """#
}
