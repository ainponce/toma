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
        float2 uvOrigin;        // texture coordinates at the image's top-left corner
        float2 uvSize;          // texture coordinates across the image
        float radius;           // corner radius of the image
        float clampsToCrop;     // 1: sample only inside uvOrigin...uvOrigin + uvSize (a crop), 0: as given
    };

    struct QuadOut {
        float4 position [[position]];
        float2 p;    // output pixels
        float2 uv;   // texture coordinates: uvOrigin...uvOrigin + uvSize across the image
    };

    // A triangle strip of four corners: (0, 0), (1, 0), (0, 1), (1, 1).
    vertex QuadOut quadVertex(uint vid [[vertex_id]], constant QuadUniforms &u [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        float2 p = u.origin + corner * u.size;
        QuadOut out;
        out.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);
        out.p = p;
        out.uv = u.uvOrigin + (p - u.contentOrigin) / u.contentSize * u.uvSize;
        return out;
    }

    // Signed distance from p to a rectangle with rounded corners centred at the origin.
    static float roundedRectDistance(float2 p, float2 halfSize, float radius) {
        float2 q = abs(p) - halfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    // The screen and the camera: bilinear, opaque, with antialiased rounded corners. For a crop, the texture is
    // sampled half a texel inside it at most, so neither the bilinear filter nor the antialiased edge (drawn past
    // the image) mixes in what is outside it.
    fragment float4 screenFragment(QuadOut in [[stage_in]],
                                   constant QuadUniforms &u [[buffer(0)]],
                                   texture2d<float> source [[texture(0)]],
                                   sampler linearSampler [[sampler(0)]]) {
        float2 halfSize = u.contentSize * 0.5;
        float radius = min(u.radius, min(halfSize.x, halfSize.y));
        float d = roundedRectDistance(in.p - (u.contentOrigin + halfSize), halfSize, radius);
        float coverage = clamp(0.5 - d, 0.0, 1.0);
        float2 uv = in.uv;
        if (u.clampsToCrop != 0.0) {
            float2 halfTexel = 0.5 / float2(source.get_width(), source.get_height());
            float2 low = u.uvOrigin + halfTexel;
            float2 high = max(u.uvOrigin + u.uvSize - halfTexel, low);
            uv = clamp(uv, low, high);
        }
        float3 color = source.sample(linearSampler, uv).rgb;
        return float4(color, 1.0) * coverage;
    }

    struct WallpaperUniforms {
        float2 stageSize;   // the stage, in output pixels
        uint count;         // points: 1...6 (`WallpaperPreset.init`)
        uint padding;
    };

    // lowbias32 (Chris Wellons): a 32-bit integer hash whose every output bit depends on every input bit.
    static uint hash32(uint x) {
        x ^= x >> 16;
        x *= 0x7feb352du;
        x ^= x >> 15;
        x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }

    // One of Toma's wallpapers, over a quad of any part of the target: a mesh gradient of its colours, each weighing
    // exp(-d² / 0.06) by its squared distance d² to the stage point in units of the stage's longer side (relative to
    // the nearest point's, so the weights never all vanish), plus a grain of ±2 % from an integer hash of the output
    // pixel. Nothing interpolated is read: a pixel depends on where it is alone, however the drawing is split. The grain
    // is of the output pixel, not of the stage point, so a zoom of the stage enlarges the gradient and not the grain.
    fragment float4 wallpaperFragment(QuadOut in [[stage_in]],
                                      constant WallpaperUniforms &u [[buffer(0)]],
                                      constant float2 *points [[buffer(1)]],   // fractions of the stage
                                      constant float4 *colors [[buffer(2)]]) { // opaque
        float2 pixel = in.position.xy;   // the centre of the output pixel
        float2 stage = pixel;            // the stage point under it: the same until something transforms the stage
        float side = max(u.stageSize.x, u.stageSize.y);
        float distances[6];
        float nearest = INFINITY;
        for (uint i = 0; i < u.count; i++) {
            float2 d = (stage - points[i] * u.stageSize) / side;
            distances[i] = dot(d, d);
            nearest = min(nearest, distances[i]);
        }
        float3 sum = 0.0;
        float total = 0.0;
        for (uint i = 0; i < u.count; i++) {
            float weight = exp((nearest - distances[i]) / 0.06);
            sum += colors[i].rgb * weight;
            total += weight;
        }
        uint2 p = uint2(pixel);
        uint h = hash32(p.x ^ hash32(p.y));
        float grain = (float(h >> 8) / 16777216.0 - 0.5) * 0.04;
        return float4(saturate(sum / total + grain), 1.0);
    }

    // The cursor sprite, already premultiplied.
    fragment float4 spriteFragment(QuadOut in [[stage_in]],
                                   texture2d<float> sprite [[texture(0)]],
                                   sampler mipSampler [[sampler(0)]]) {
        return sprite.sample(mipSampler, in.uv);
    }
    """#
}
