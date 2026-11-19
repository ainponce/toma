// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of the device frame (phase 2 design §6.7, `deviceFrame-1`), drawn after the window
    /// frame (§11, step 1): our own vectors, signed distances to rounded rects with their edges antialiased as the screen's
    /// corners are (`roundedRectDistance`, a pixel's coverage `0.5 − d`), every corner concentric with the screen's.
    ///
    /// - `deviceBodyFragment`, over a quad of the device's bounds and a pixel more: from the bottom up, the MacBook's base
    ///   (its front round, its groove a darker half ellipse at the middle of its top edge, reaching up under the lid's
    ///   straight bottom edge so they meet without a seam), the iPhone's buttons (each
    ///   reaching under the band, so it meets it without a seam), the band (the MacBook's lid's rim) and the bezel inside
    ///   it, opaque under the screen too, so the screen's antialiased edge is drawn over the bezel and no background shows
    ///   between them. In a group fading at `opacity` (`RenderFrame.screenOpacity`), under the screen as the window's bar
    ///   is (`fadingWindowBarFragment`): only what the screen drawn over it next lets through.
    /// - `deviceCutoutFragment` (and `deviceCutoutTargetFragment`, into the motion blur's target): the iPhone's island, a
    ///   capsule, or the MacBook's notch, its bottom corners round and its top in the bezel, with the concave corners where
    ///   it meets the screen's top edge; in the bezel's colour, over the screen and the cursor.
    static let deviceFrameMetal: String = #"""

    struct DeviceBodyUniforms {
        float4 band;        // sRGB, not premultiplied, opaque: the band (the MacBook's lid)
        float4 bezel;
        float4 base;
        float4 body;        // x, y, width, height, in output pixels
        float4 screen;
        float4 baseRect;    // width 0: no base
        float4 groove;      // the base's groove: width 0, none
        float4 buttons[4];  // each reaching under the band; width 0: none
        float bodyRadius;   // the body's corners: its top ones, and its bottom ones but the MacBook's
        float bodyBottomRadius;
        float bandWidth;
        float screenRadius;
        float baseFrontRadius;
        float grooveShade;  // the groove's colour is the base's times this
        float buttonRadius;
        float opacity;      // of the screen's group, 0...1
    };

    // How much of the pixel at a signed distance d (output pixels) a shape covers: antialiased over one pixel.
    static float deviceCoverage(float d) {
        return clamp(0.5 - d, 0.0, 1.0);
    }

    // The signed distance from p to the rect r (x, y, width, height) with corners of topRadius at its top and
    // bottomRadius at its bottom.
    static float deviceRectDistance(float2 p, float4 r, float topRadius, float bottomRadius) {
        float2 halfSize = r.zw * 0.5;
        return roundedRectDistance(p - (r.xy + halfSize), halfSize, topRadius, bottomRadius);
    }

    // `top` over `under`, both premultiplied.
    static float4 deviceOver(float4 top, float4 under) {
        return top + under * (1.0 - top.a);
    }

    fragment float4 deviceBodyFragment(QuadOut in [[stage_in]],
                                       constant DeviceBodyUniforms &u [[buffer(0)]]) {
        float2 p = in.p;
        float4 color = float4(0.0);
        // The MacBook's base, its front round, with its groove: a half ellipse hanging from the middle of its top edge.
        if (u.baseRect.z > 0.0) {
            // Reaching up under the lid's straight bottom edge, so the two edges that meet there leave no seam of what
            // is under them.
            float lidCorner = u.bodyBottomRadius;
            float4 under = float4(u.body.x + lidCorner, u.baseRect.y - lidCorner - 1.0, u.body.z - 2.0 * lidCorner, lidCorner + 2.0);
            float base = deviceCoverage(min(
                deviceRectDistance(p, u.baseRect, 0.0, u.baseFrontRadius), deviceRectDistance(p, under, 0.0, 0.0)));
            float3 shade = u.base.rgb;
            if (u.groove.z > 0.0 && u.groove.w > 0.0) {
                float2 axes = float2(u.groove.z * 0.5, u.groove.w);
                float2 q = (p - float2(u.groove.x + axes.x, u.groove.y)) / axes;
                float k = max(length(q), 1e-6);
                // The ellipse's implicit distance over its gradient: a signed distance near its edge.
                float2 gradient = q / (axes * k);
                float d = (k - 1.0) / max(length(gradient), 1e-6);
                shade = mix(shade, shade * u.grooveShade, deviceCoverage(d));
            }
            color = float4(shade, 1.0) * base;
        }
        // The iPhone's side buttons, in the band's colour, under the body.
        for (int i = 0; i < 4; i++) {
            float4 button = u.buttons[i];
            if (button.z <= 0.0) { continue; }
            float b = deviceCoverage(deviceRectDistance(p, button, u.buttonRadius, u.buttonRadius));
            color = deviceOver(float4(u.band.rgb, 1.0) * b, color);
        }
        // The band, then the bezel inside it: its corners concentric with the body's.
        float body = deviceCoverage(deviceRectDistance(p, u.body, u.bodyRadius, u.bodyBottomRadius));
        color = deviceOver(float4(u.band.rgb, 1.0) * body, color);
        float4 inner = float4(u.body.xy + u.bandWidth, u.body.zw - 2.0 * u.bandWidth);
        float bezel = deviceCoverage(deviceRectDistance(
            p, inner, max(u.bodyRadius - u.bandWidth, 0.0), max(u.bodyBottomRadius - u.bandWidth, 0.0)));
        color = deviceOver(float4(u.bezel.rgb, 1.0) * bezel, color);
        // Fading as one group with the screen over it.
        if (u.opacity < 1.0) {
            float covered = deviceCoverage(deviceRectDistance(p, u.screen, u.screenRadius, u.screenRadius));
            float shown = covered * u.opacity;
            color *= shown < 1.0 ? u.opacity * (1.0 - covered) / (1.0 - shown) : 0.0;
        }
        return color;
    }

    struct DeviceCutoutUniforms {
        float4 color;       // sRGB, not premultiplied, opaque: the bezel's
        float4 cutout;      // x, y, width, height, as drawn (the notch reaching up into the bezel)
        float topRadius;
        float bottomRadius;
        float fillet;       // the notch's concave corners at the screen's top edge (`edge`); 0: none
        float edge;
        float opacity;
        float padding0;
        float padding1;
        float padding2;
    };

    static float4 deviceCutout(float2 p, constant DeviceCutoutUniforms &u) {
        float d = deviceRectDistance(p, u.cutout, u.topRadius, u.bottomRadius);
        if (u.fillet > 0.0) {
            float f = u.fillet;
            float left = u.cutout.x, right = u.cutout.x + u.cutout.z;
            // Beside each side, at the screen's top edge: a square of the fillet outside the circle that rounds it.
            float leftFillet = max(
                deviceRectDistance(p, float4(left - f, u.edge - f, f, 2.0 * f), 0.0, 0.0),
                f - length(p - float2(left - f, u.edge + f)));
            float rightFillet = max(
                deviceRectDistance(p, float4(right, u.edge - f, f, 2.0 * f), 0.0, 0.0),
                f - length(p - float2(right + f, u.edge + f)));
            d = min(d, min(leftFillet, rightFillet));
        }
        return float4(u.color.rgb, 1.0) * (deviceCoverage(d) * u.opacity);
    }

    fragment float4 deviceCutoutFragment(QuadOut in [[stage_in]],
                                         constant DeviceCutoutUniforms &u [[buffer(0)]]) {
        return deviceCutout(in.p, u);
    }

    // The island or the notch into the target of the motion blur's pass.
    fragment TargetOut deviceCutoutTargetFragment(QuadOut in [[stage_in]],
                                                  constant DeviceCutoutUniforms &u [[buffer(0)]]) {
        TargetOut out;
        out.color = deviceCutout(in.p, u);
        return out;
    }
    """#
}
