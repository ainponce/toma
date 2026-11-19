// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of the keys on screen (phase 2 design §7.4), over the camera (§11, step 5): a
    /// box's texture (`KeyOverlayTexture`), premultiplied, drawn over the whole pixels it covers one texel a pixel, read
    /// and never filtered, so its edges and its text are exactly as CoreGraphics drew them at the output's resolution;
    /// times the item's opacity (at 1, exactly the texture).
    /// - `keyOverlayFragment`: straight into the target, or into a subsample's attachment.
    /// - `keyOverlayTargetFragment`: into the target of the motion blur's pass (the core's `TargetOut`), over its average.
    static let keysMetal = #"""

    // The texel of the box's texture under the pixel at p: the quad is its region, whole pixels from contentOrigin.
    static float4 keyOverlayTexel(float2 p, constant QuadUniforms &u, texture2d<float> keys) {
        float2 last = float2(keys.get_width(), keys.get_height()) - 1.0;
        uint2 texel = uint2(clamp(floor(p - u.contentOrigin), float2(0.0), last));
        return keys.read(texel);
    }

    fragment float4 keyOverlayFragment(QuadOut in [[stage_in]],
                                       constant QuadUniforms &u [[buffer(0)]],
                                       constant float &opacity [[buffer(1)]],
                                       texture2d<float> keys [[texture(0)]]) {
        return keyOverlayTexel(in.p, u, keys) * opacity;
    }

    // The box into the target of the motion blur's pass.
    fragment TargetOut keyOverlayTargetFragment(QuadOut in [[stage_in]],
                                                constant QuadUniforms &u [[buffer(0)]],
                                                constant float &opacity [[buffer(1)]],
                                                texture2d<float> keys [[texture(0)]]) {
        TargetOut out;
        out.color = keyOverlayTexel(in.p, u, keys) * opacity;
        return out;
    }
    """#
}
