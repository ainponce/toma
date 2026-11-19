// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of the screen with its privacy regions (phase 2 design §7.1), blurred,
    /// pixelated or filled in its shader (§11, step 2): `privacy-1` (plan 2c decision 3).
    ///
    /// The screen is drawn as `mipmappedScreenFragment` draws it, from its copy with mipmaps; a pixel is in a region when
    /// the position it shows of the screen's crop (its centre's, clamped to the crop's texel centres as `imageUV` clamps
    /// what it reads, so the antialiased edge drawn past the crop is in a region at the crop's edge too) is in
    /// `[x, x + width) × [y, y + height)` of the region's rect, with no antialiasing: the edges are hard, and every pixel
    /// out of every region is exactly the screen's own. With `s` the region's shorter side in texels of the copy:
    /// - Blur: a radius `r = max(12, s × (0.2 + 0.4 × strength))`, the level `clamp(log2(r / 2), 0, levels − 1)` and 9
    ///   samples at that level in `{−r/2, 0, r/2}²` about the pixel, weighed `(1, 2, 1) ⊗ (1, 2, 1) / 16`.
    /// - Pixelate: cells `max(8, s / 12)` texels square from the region's top-left corner, each the colour of its centre
    ///   at the level `log2(cell)`.
    /// - Fill: the colour, opaque (its alpha is not read: nothing shows through).
    /// A copy without mipmaps (one level) cannot blur nor pixelate: those regions are black, so nothing they hide shows.
    /// Where regions overlap, the last one is drawn.
    static let privacyMetal = #"""
    struct PrivacyRegionUniform {
        float4 rect;     // x, y, width, height: fractions of the screen's crop as it is drawn
        float4 color;    // the fill's, sRGB, not premultiplied
        float4 params;   // x: the effect (0 blur, 1 pixelate, 2 fill); y: the strength, 0 to 1
    };

    struct PrivacyUniforms {
        uint count;
        PrivacyRegionUniform regions[8];
    };

    // Whether a region holds the pixel whose texture coordinates are `uv` (before a crop clamps them), and then the colour
    // it gives it in `color`.
    static bool privacyColor(float2 uv, thread float3 &color, constant QuadUniforms &u, constant PrivacyUniforms &privacy,
                             texture2d<float> source, sampler trilinearSampler) {
        float2 size = float2(source.get_width(), source.get_height());
        float levels = float(source.get_num_mip_levels());
        // What the pixel shows of the crop: its texture coordinates clamped to the crop's texel centres, as fractions of
        // the crop.
        float2 halfTexel = 0.5 / size;
        float2 low = u.uvOrigin + halfTexel;
        float2 high = max(u.uvOrigin + u.uvSize - halfTexel, low);
        float2 p = clamp(uv, low, high);
        float2 f = (p - u.uvOrigin) / u.uvSize;
        uint count = min(privacy.count, 8u);
        for (uint k = count; k > 0; k--) {
            PrivacyRegionUniform r = privacy.regions[k - 1];
            if (!(f.x >= r.rect.x && f.x < r.rect.x + r.rect.z && f.y >= r.rect.y && f.y < r.rect.y + r.rect.w)) {
                continue;
            }
            uint effect = uint(r.params.x);
            if (effect == 2u) {
                color = r.color.rgb;
                return true;
            }
            if (levels <= 1.0) {
                color = float3(0.0);
                return true;
            }
            float2 extent = r.rect.zw * u.uvSize * size;
            float s = min(extent.x, extent.y);
            if (effect == 1u) {
                float cell = max(8.0, s / 12.0);
                float2 corner = (u.uvOrigin + r.rect.xy * u.uvSize) * size;
                float2 centre = corner + (floor((p * size - corner) / cell) + 0.5) * cell;
                float lod = clamp(log2(cell), 0.0, levels - 1.0);
                color = source.sample(trilinearSampler, centre / size, level(lod)).rgb;
                return true;
            }
            float strength = clamp(r.params.y, 0.0, 1.0);
            float radius = max(12.0, s * (0.2 + 0.4 * strength));
            float lod = clamp(log2(radius * 0.5), 0.0, levels - 1.0);
            float2 step = radius * 0.5 / size;
            float3 sum = float3(0.0);
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    float weight = float((2 - abs(dx)) * (2 - abs(dy)));
                    sum += weight * source.sample(trilinearSampler, p + float2(dx, dy) * step, level(lod)).rgb;
                }
            }
            color = sum / 16.0;
            return true;
        }
        return false;
    }

    // The screen with its regions: `privacyColor` in a region, `mipmappedScreenFragment`'s colour out of every one, over
    // `imageCoverage`, at `opacity`. The derivatives are taken before anything branches, so the screen's own colour is
    // exactly `mipmappedScreenFragment`'s.
    static float4 privacyScreenColor(QuadOut in, constant QuadUniforms &u, float coverage, float opacity,
                                     constant PrivacyUniforms &privacy, texture2d<float> source, sampler trilinearSampler) {
        float2 uv = imageUV(in.uv, u, source);
        float2 gx = dfdx(in.uv), gy = dfdy(in.uv);
        float3 color;
        if (!privacyColor(in.uv, color, u, privacy, source, trilinearSampler)) {
            color = source.sample(trilinearSampler, uv, gradient2d(gx, gy)).rgb;
        }
        return float4(color, 1.0) * coverage * opacity;
    }

    fragment float4 privacyScreenFragment(QuadOut in [[stage_in]],
                                          constant QuadUniforms &u [[buffer(0)]],
                                          constant float &opacity [[buffer(1)]],
                                          constant PrivacyUniforms &privacy [[buffer(3)]],
                                          texture2d<float> source [[texture(0)]],
                                          sampler trilinearSampler [[sampler(0)]]) {
        return privacyScreenColor(in, u, imageCoverage(in.p, u), opacity, privacy, source, trilinearSampler);
    }

    // Cut to a card, as `clippedMipmappedScreenFragment`.
    fragment float4 clippedPrivacyScreenFragment(QuadOut in [[stage_in]],
                                                 constant QuadUniforms &u [[buffer(0)]],
                                                 constant float &opacity [[buffer(1)]],
                                                 constant QuadUniforms &clip [[buffer(2)]],
                                                 constant PrivacyUniforms &privacy [[buffer(3)]],
                                                 texture2d<float> source [[texture(0)]],
                                                 sampler trilinearSampler [[sampler(0)]]) {
        float coverage = min(imageCoverage(in.p, u), imageCoverage(in.p, clip));
        return privacyScreenColor(in, u, coverage, opacity, privacy, source, trilinearSampler);
    }

    // The same two into the target of the motion blur's pass (attachment 2).
    fragment TargetOut privacyScreenTargetFragment(QuadOut in [[stage_in]],
                                                   constant QuadUniforms &u [[buffer(0)]],
                                                   constant float &opacity [[buffer(1)]],
                                                   constant PrivacyUniforms &privacy [[buffer(3)]],
                                                   texture2d<float> source [[texture(0)]],
                                                   sampler trilinearSampler [[sampler(0)]]) {
        TargetOut out;
        out.color = privacyScreenColor(in, u, imageCoverage(in.p, u), opacity, privacy, source, trilinearSampler);
        return out;
    }

    fragment TargetOut clippedPrivacyScreenTargetFragment(QuadOut in [[stage_in]],
                                                          constant QuadUniforms &u [[buffer(0)]],
                                                          constant float &opacity [[buffer(1)]],
                                                          constant QuadUniforms &clip [[buffer(2)]],
                                                          constant PrivacyUniforms &privacy [[buffer(3)]],
                                                          texture2d<float> source [[texture(0)]],
                                                          sampler trilinearSampler [[sampler(0)]]) {
        TargetOut out;
        float coverage = min(imageCoverage(in.p, u), imageCoverage(in.p, clip));
        out.color = privacyScreenColor(in, u, coverage, opacity, privacy, source, trilinearSampler);
        return out;
    }

    """#
}
