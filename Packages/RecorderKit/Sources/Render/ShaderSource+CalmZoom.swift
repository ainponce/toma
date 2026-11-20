// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of the calm zoom (phase 3 design §6 and §12, step 4, `CalmZoomLook`): Highlight
    /// over the stage in its pass, into the target or the motion blur's (`calmHighlightFragment`,
    /// `calmHighlightTargetFragment`); Dim's veil over the frame, reading its blurred copy (`calmDimFragment`, after the
    /// core's `blurFragment`); and the loupe's lens, its shadow and its ring in one drawing, reading the copy of what is
    /// under it (`loupeFragment`). Each is premultiplied, blended "over", and transparent where it shows nothing, so what is
    /// under it there is left as it is; each is mixed with what is under it by the layer's amount. In a card's mode
    /// (`clip`, `strength`: `clipCoverage`), the focus is cut to the card.
    static let calmZoomMetal = #"""

    struct CalmFocusUniforms {
        float2 focusOrigin;   // the focus as drawn, output pixels
        float2 focusSize;
        float cornerRadius;   // at most half its shorter side
        float amount;         // how much of the effect is seen, 0 to 1
        float darken;         // how much darker outside the focus: 0.2 (Highlight), 0.6 (Dim)
        float ring;           // Highlight's ring, across, outside the focus's edge
        float ringOpacity;    // its white
        float glowOpacity;    // the glow's white past the ring
        float glowSigma;      // how fast it falls
        float transition;     // Dim's soft edge, outward from the focus's
    };

    // The signed distance from p to the focus with its corners: negative inside.
    static float calmFocusDistance(float2 p, constant CalmFocusUniforms &u) {
        float2 halfSize = u.focusSize * 0.5;
        float radius = min(u.cornerRadius, min(halfSize.x, halfSize.y));
        return roundedRectDistance(p - (u.focusOrigin + halfSize), halfSize, radius);
    }

    // Highlight at p: the rest darker, then the glow and the ring over it, white, all cut to the card. Nothing inside the
    // focus.
    static float4 calmHighlight(float2 p, constant CalmFocusUniforms &u, constant QuadUniforms &clip, float strength) {
        float d = calmFocusDistance(p, u);
        float cut = clipCoverage(p, clip, strength);
        float hole = clamp(0.5 - d, 0.0, 1.0) * cut;
        float outside = clamp(0.5 + d, 0.0, 1.0);
        float ring = (outside - clamp(0.5 + d - u.ring, 0.0, 1.0)) * u.ringOpacity * cut;
        float beyond = max(d - u.ring, 0.0);
        float glow = u.glowOpacity * exp(-(beyond * beyond) / (2.0 * u.glowSigma * u.glowSigma)) * outside * cut;
        float4 color = float4(0.0, 0.0, 0.0, u.darken * (1.0 - hole));
        color = float4(glow) + color * (1.0 - glow);
        color = float4(ring) + color * (1.0 - ring);
        return color * u.amount;
    }

    // Highlight over a quad as large as the output.
    fragment float4 calmHighlightFragment(QuadOut in [[stage_in]],
                                          constant CalmFocusUniforms &u [[buffer(1)]],
                                          constant QuadUniforms &clip [[buffer(2)]],
                                          constant float &strength [[buffer(3)]]) {
        return calmHighlight(in.p, u, clip, strength);
    }

    // Highlight into the target of the motion blur's pass.
    fragment TargetOut calmHighlightTargetFragment(QuadOut in [[stage_in]],
                                                   constant CalmFocusUniforms &u [[buffer(1)]],
                                                   constant QuadUniforms &clip [[buffer(2)]],
                                                   constant float &strength [[buffer(3)]]) {
        TargetOut out;
        out.color = calmHighlight(in.p, u, clip, strength);
        return out;
    }

    // Dim over a quad as large as the output: past the focus's soft edge, the frame's blurred copy (`blurred`, read
    // across the whole output) darker, over the frame; nothing inside the focus, cut to the card.
    fragment float4 calmDimFragment(QuadOut in [[stage_in]],
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
        float3 color = blurred.sample(linearSampler, in.uv).rgb;
        return float4(color * (1.0 - u.darken) * shown, shown);
    }

    struct LoupeUniforms {
        float2 center;        // the lens's centre, output pixels
        float2 halfSize;      // (r, r) for a circle, (1.5 r, r) for a rounded rectangle
        float2 sampleOrigin;  // the copy of what is under it: its top-left corner in the target's pixels
        float2 toTarget;      // the target's pixels for each output pixel
        float corner;         // r for a circle, 0.25 r
        float magnification;  // at least 1
        float band;           // the outer band that bulges, in from the edge: 0.15 r
        float bulge;          // how much farther out it reads at the edge: 0.08
        float ring;           // the ring, across, inside the edge
        float ringOpacity;    // its white
        float amount;         // how much of the lens is seen, 0 to 1
        float padding;
    };

    // The loupe over a quad about the lens and its shadow: the shadow (the core's `shadowValue` of its shape moved down),
    // the lens over it reading the copy at c + (p − c) / m, up to `bulge` farther out across its outer band
    // (`CalmZoomLook.lensSample`), and the ring over the lens, in one drawing. The copy is read in the target's pixels,
    // bilinear and clamped to its edge (`CalmZoomLook.lensBox`), so what is past the frame's edge is the edge, and where
    // the copy is in the target changes nothing of what is read.
    fragment float4 loupeFragment(QuadOut in [[stage_in]],
                                  constant LoupeUniforms &u [[buffer(1)]],
                                  constant ShadowUniforms &shadow [[buffer(2)]],
                                  texture2d<float> under [[texture(0)]]) {
        constexpr sampler targetPixels(coord::pixel, address::clamp_to_edge, filter::linear);
        float d = roundedRectDistance(in.p - u.center, u.halfSize, u.corner);
        float coverage = clamp(0.5 - d, 0.0, 1.0);
        float4 color = float4(0.0);
        if (coverage < 1.0) {
            color = float4(0.0, 0.0, 0.0, shadow.opacity * shadowValue(in.p, shadow));
        }
        if (coverage > 0.0) {
            float s = clamp((d + u.band) / u.band, 0.0, 1.0);
            float2 q = u.center + (in.p - u.center) / u.magnification * (1.0 + u.bulge * s * s);
            float3 lens = under.sample(targetPixels, q * u.toTarget - u.sampleOrigin).rgb;
            color = float4(lens, 1.0) * coverage + color * (1.0 - coverage);
            float ring = (coverage - clamp(0.5 - d - u.ring, 0.0, 1.0)) * u.ringOpacity;
            color = float4(ring) + color * (1.0 - ring);
        }
        return color * u.amount;
    }
    """#
}
