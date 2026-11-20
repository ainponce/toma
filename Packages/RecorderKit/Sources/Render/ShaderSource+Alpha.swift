// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of the transparent background (milestone 4c, design §7.1, `AlphaPipelines`),
    /// last: the background's step is the core's `transparentFragment`, drawn without blending; and the calm zoom over a
    /// transparent frame, which darkens the stage drawn and not the void. Highlight's veil times the alpha under it, read
    /// where it is drawn (`[[color(0)]]` into the target, `[[color(2)]]` into the motion blur's) and blended "over" it in
    /// the shader (`calmHighlightAlphaFragment`, `calmHighlightAlphaTargetFragment`); its ring and its glow, drawn, as they
    /// are. Dim's blurred copy darker with its own alpha (`calmDimAlphaFragment`), blended "over" as Dim's: the void stays
    /// void, and the blurred edge of the stage keeps its alpha. Neither is ever drawn over an opaque frame, whose calm zoom
    /// is the calm zoom's own (`calmZoomMetal`).
    static let alphaMetal = #"""

    // Highlight at p over `under`, what is drawn there: the calm zoom's `calmHighlight` with its veil times `under`'s
    // alpha, then "over" `under`. Where `under` is opaque, Highlight as it is over an opaque frame.
    static float4 calmHighlightOverAlpha(float2 p, constant CalmFocusUniforms &u, constant QuadUniforms &clip,
                                         float strength, float4 under) {
        float d = calmFocusDistance(p, u);
        float cut = clipCoverage(p, clip, strength);
        float hole = clamp(0.5 - d, 0.0, 1.0) * cut;
        float outside = clamp(0.5 + d, 0.0, 1.0);
        float ring = (outside - clamp(0.5 + d - u.ring, 0.0, 1.0)) * u.ringOpacity * cut;
        float beyond = max(d - u.ring, 0.0);
        float glow = u.glowOpacity * exp(-(beyond * beyond) / (2.0 * u.glowSigma * u.glowSigma)) * outside * cut;
        float4 color = float4(0.0, 0.0, 0.0, u.darken * (1.0 - hole) * under.a);
        color = float4(glow) + color * (1.0 - glow);
        color = float4(ring) + color * (1.0 - ring);
        color *= u.amount;
        return color + under * (1.0 - color.a);
    }

    // Highlight over a transparent frame, over a quad as large as the output, straight into the target.
    fragment float4 calmHighlightAlphaFragment(QuadOut in [[stage_in]],
                                               float4 under [[color(0)]],
                                               constant CalmFocusUniforms &u [[buffer(1)]],
                                               constant QuadUniforms &clip [[buffer(2)]],
                                               constant float &strength [[buffer(3)]]) {
        return calmHighlightOverAlpha(in.p, u, clip, strength, under);
    }

    // Highlight over a transparent frame into the target of the motion blur's pass.
    fragment TargetOut calmHighlightAlphaTargetFragment(QuadOut in [[stage_in]],
                                                        float4 under [[color(2)]],
                                                        constant CalmFocusUniforms &u [[buffer(1)]],
                                                        constant QuadUniforms &clip [[buffer(2)]],
                                                        constant float &strength [[buffer(3)]]) {
        TargetOut out;
        out.color = calmHighlightOverAlpha(in.p, u, clip, strength, under);
        return out;
    }

    // Dim over a transparent frame: `calmDimFragment` with the blurred copy premultiplied, its colour darker and its own
    // alpha, so where the copy is empty nothing is drawn.
    fragment float4 calmDimAlphaFragment(QuadOut in [[stage_in]],
                                         constant CalmFocusUniforms &u [[buffer(1)]],
                                         constant QuadUniforms &clip [[buffer(2)]],
                                         constant float &strength [[buffer(3)]],
                                         texture2d<float> blurred [[texture(0)]],
                                         sampler linearSampler [[sampler(0)]]) {
        float d = calmFocusDistance(in.p, u);
        float hole = (1.0 - smoothstep(0.0, u.transition, d)) * clipCoverage(in.p, clip, strength);
        float shown = (1.0 - hole) * u.amount;
        if (shown <= 0.0) {
            return float4(0.0);
        }
        float4 b = blurred.sample(linearSampler, in.uv);
        return float4(b.rgb * (1.0 - u.darken), b.a) * shown;
    }
    """#
}
