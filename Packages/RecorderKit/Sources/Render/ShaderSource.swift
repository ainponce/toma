// SPDX-License-Identifier: GPL-3.0-or-later

/// The compositor's Metal shaders, compiled at run time with `MTLDevice.makeLibrary(source:options:)`
/// (no `.metal` files: the Metal toolchain is not part of the build).
///
/// Every value comes from the frame being drawn: nothing reads a clock, a random source or memory that
/// was not written. Colours are premultiplied; positions are output pixels with the origin at the top left.
public enum ShaderSource {
    public static let metal: String = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct GradientUniforms {
        float4 start;
        float4 end;
        float2 direction;   // (sin θ, −cos θ) in uv space, v growing down
        float2 padding;
    };

    struct GradientOut {
        float4 position [[position]];
        float2 uv;
    };

    // One triangle that covers the whole target: uv (0, 0), (2, 0), (0, 2).
    vertex GradientOut gradientVertex(uint vid [[vertex_id]]) {
        float2 uv = float2(float((vid << 1) & 2), float(vid & 2));
        GradientOut out;
        out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
        out.uv = uv;
        return out;
    }

    fragment float4 gradientFragment(GradientOut in [[stage_in]],
                                     constant GradientUniforms &u [[buffer(0)]]) {
        float t = clamp(dot(in.uv - 0.5, u.direction) + 0.5, 0.0, 1.0);
        return mix(u.start, u.end, t);
    }

    struct QuadUniforms {
        float2 viewport;        // output size
        float2 origin;          // top-left corner of the quad drawn
        float2 size;            // size of the quad drawn
        float2 contentOrigin;   // top-left corner of the image in it
        float2 contentSize;     // size of the image
        float radius;           // corner radius of the image
        float padding;
    };

    struct QuadOut {
        float4 position [[position]];
        float2 p;    // output pixels
        float2 uv;   // 0...1 across the image
    };

    // A triangle strip of four corners: (0, 0), (1, 0), (0, 1), (1, 1).
    vertex QuadOut quadVertex(uint vid [[vertex_id]], constant QuadUniforms &u [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        float2 p = u.origin + corner * u.size;
        QuadOut out;
        out.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);
        out.p = p;
        out.uv = (p - u.contentOrigin) / u.contentSize;
        return out;
    }

    // Signed distance from p to a rectangle with rounded corners centred at the origin.
    static float roundedRectDistance(float2 p, float2 halfSize, float radius) {
        float2 q = abs(p) - halfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    // The screen: bilinear, opaque, with antialiased rounded corners.
    fragment float4 screenFragment(QuadOut in [[stage_in]],
                                   constant QuadUniforms &u [[buffer(0)]],
                                   texture2d<float> source [[texture(0)]],
                                   sampler linearSampler [[sampler(0)]]) {
        float2 halfSize = u.contentSize * 0.5;
        float radius = min(u.radius, min(halfSize.x, halfSize.y));
        float d = roundedRectDistance(in.p - (u.contentOrigin + halfSize), halfSize, radius);
        float coverage = clamp(0.5 - d, 0.0, 1.0);
        float3 color = source.sample(linearSampler, in.uv).rgb;
        return float4(color, 1.0) * coverage;
    }

    // The cursor sprite, already premultiplied.
    fragment float4 spriteFragment(QuadOut in [[stage_in]],
                                   texture2d<float> sprite [[texture(0)]],
                                   sampler mipSampler [[sampler(0)]]) {
        return sprite.sample(mipSampler, in.uv);
    }
    """#
}
