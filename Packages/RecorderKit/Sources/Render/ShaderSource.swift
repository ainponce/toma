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
        float radius;           // corner radius of the image (of the shape, with one)
        float clampsToCrop;     // 1: sample only inside uvOrigin...uvOrigin + uvSize (a crop), 0: as given
        float2 shapeOrigin;     // top-left corner of the rounded rect that cuts the image (a window frame's)
        float2 shapeSize;       // its size; 0: none, the image's own corners are rounded
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

    // How much of the pixel at p the screen or the camera covers: its rect with antialiased rounded corners. Inside a
    // window frame, the window's rounded rect (the shape) cuts the screen instead, and its own rect, square, along the
    // edge it does not share with the window: the top one, under the bar.
    static float imageCoverage(float2 p, constant QuadUniforms &u) {
        float2 halfSize = u.contentSize * 0.5;
        float radius = min(u.radius, min(halfSize.x, halfSize.y));
        float d = roundedRectDistance(p - (u.contentOrigin + halfSize), halfSize, radius);
        float coverage = clamp(0.5 - d, 0.0, 1.0);
        if (u.shapeSize.x > 0.0) {
            float2 halfShape = u.shapeSize * 0.5;
            float shapeRadius = min(u.radius, min(halfShape.x, halfShape.y));
            float shape = roundedRectDistance(p - (u.shapeOrigin + halfShape), halfShape, shapeRadius);
            float rect = roundedRectDistance(p - (u.contentOrigin + halfSize), halfSize, 0.0);
            coverage = clamp(0.5 - max(shape, rect), 0.0, 1.0);
        }
        return coverage;
    }

    // The texture coordinates sampled for uv: for a crop, half a texel inside it at most, so neither the filter nor the
    // antialiased edge (drawn past the image) mixes in what is outside it.
    static float2 imageUV(float2 uv, constant QuadUniforms &u, texture2d<float> source) {
        if (u.clampsToCrop != 0.0) {
            float2 halfTexel = 0.5 / float2(source.get_width(), source.get_height());
            float2 low = u.uvOrigin + halfTexel;
            float2 high = max(u.uvOrigin + u.uvSize - halfTexel, low);
            uv = clamp(uv, low, high);
        }
        return uv;
    }

    // The screen and the camera: bilinear, opaque, over `imageCoverage`.
    fragment float4 screenFragment(QuadOut in [[stage_in]],
                                   constant QuadUniforms &u [[buffer(0)]],
                                   texture2d<float> source [[texture(0)]],
                                   sampler linearSampler [[sampler(0)]]) {
        float coverage = imageCoverage(in.p, u);
        float3 color = source.sample(linearSampler, imageUV(in.uv, u, source)).rgb;
        return float4(color, 1.0) * coverage;
    }

    // The screen sampled trilinear from a mipmapped copy of its frame (`ScreenLayer.mipmapped`), opaque, over
    // `imageCoverage`. The level is chosen from how fast the coordinates change before a crop clamps them: those clamped
    // stop changing along the crop's edges, where they would read the full-size level and alias.
    fragment float4 mipmappedScreenFragment(QuadOut in [[stage_in]],
                                            constant QuadUniforms &u [[buffer(0)]],
                                            texture2d<float> source [[texture(0)]],
                                            sampler trilinearSampler [[sampler(0)]]) {
        float coverage = imageCoverage(in.p, u);
        float2 uv = imageUV(in.uv, u, source);
        float3 color = source.sample(trilinearSampler, uv, gradient2d(dfdx(in.uv), dfdy(in.uv))).rgb;
        return float4(color, 1.0) * coverage;
    }

    struct ShadowUniforms {
        float2 lower;       // the box: the rect that casts the shadow, moved down by its offset
        float2 upper;
        float sigma;        // of the blur, > 0
        float corner;       // the box's corners, at most half its shorter side
        float opacity;
        float padding;
    };

    // Abramowitz and Stegun 7.1.26, within 1.5e-7 of erf, which Metal does not have: `ShadowMath.erf`, the same in Float.
    static float shadowErf(float x) {
        float a = abs(x);
        float t = 1.0 / (1.0 + 0.3275911 * a);
        float poly = 1.061405429;
        poly = -1.453152027 + t * poly;
        poly = 1.421413741 + t * poly;
        poly = -0.284496736 + t * poly;
        poly = 0.254829592 + t * poly;
        poly = t * poly;
        float y = 1.0 - poly * exp(-a * a);
        return x < 0.0 ? -y : y;
    }

    // The box's row at height y from its centre (narrower in its rounded corners) blurred along x by sigma, at x from its
    // centre: exact, with two erf.
    static float shadowRow(float x, float y, float sigma, float corner, float2 halfSize) {
        float delta = min(halfSize.y - corner - abs(y), 0.0);
        float curved = halfSize.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
        float k = 0.70710678 / sigma;
        return 0.5 * (shadowErf((x + curved) * k) - shadowErf((x - curved) * k));
    }

    // The normal density of sigma at x.
    static float shadowGaussian(float x, float sigma) {
        return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.5066282746 * sigma);
    }

    // The shadow of a rounded box blurred by a Gaussian (Evan Wallace's, `ShadowMath`): the rows blurred along x,
    // integrated along y at `ShadowMath.ySamples` samples, at the middle of equal steps over [-3 sigma, 3 sigma] clipped to
    // the box. Premultiplied black at that alpha times the opacity.
    fragment float4 shadowFragment(QuadOut in [[stage_in]],
                                   constant ShadowUniforms &u [[buffer(0)]]) {
        float2 centre = (u.lower + u.upper) * 0.5;
        float2 halfSize = (u.upper - u.lower) * 0.5;
        float2 p = in.p - centre;
        float low = p.y - halfSize.y;
        float high = p.y + halfSize.y;
        float start = min(max(-3.0 * u.sigma, low), high);
        float end = min(max(3.0 * u.sigma, low), high);
        float span = (end - start) / float(\#(ShadowMath.ySamples));
        float y = start + span * 0.5;
        float value = 0.0;
        for (int i = 0; i < \#(ShadowMath.ySamples); i++) {
            value += shadowRow(p.x, p.y - y, u.sigma, u.corner, halfSize) * shadowGaussian(y, u.sigma) * span;
            y += span;
        }
        return float4(0.0, 0.0, 0.0, u.opacity * value);
    }

    struct WindowBarUniforms {
        float4 barColor;
        float4 red;             // the buttons' colours, left to right
        float4 yellow;
        float4 green;
        float2 windowOrigin;    // the whole window, bar and screen
        float2 windowSize;
        float2 firstButton;     // the first button's centre
        float buttonSpacing;    // between the buttons' centres
        float buttonRadius;     // 0: no buttons
        float radius;           // the window's corners
        float barBottom;        // where the bar meets the screen
        float2 padding;
    };

    // A window frame's title bar (`WindowFrameLayer`), over a quad around it: the window's rounded rect down to one pixel
    // under the screen's top edge, so the screen, drawn over it, leaves no seam of background where they meet; in the
    // bar's colour, with the buttons' antialiased circles. Opaque, premultiplied by how much of the pixel it covers.
    fragment float4 windowBarFragment(QuadOut in [[stage_in]],
                                      constant WindowBarUniforms &u [[buffer(0)]]) {
        float2 halfSize = u.windowSize * 0.5;
        float radius = min(u.radius, min(halfSize.x, halfSize.y));
        float window = roundedRectDistance(in.p - (u.windowOrigin + halfSize), halfSize, radius);
        float bar = in.p.y - (u.barBottom + 1.0);
        float coverage = clamp(0.5 - max(window, bar), 0.0, 1.0);
        float3 color = u.barColor.rgb;
        if (u.buttonRadius > 0.0) {
            float3 buttons[3] = { u.red.rgb, u.yellow.rgb, u.green.rgb };
            for (int i = 0; i < 3; i++) {
                float2 centre = u.firstButton + float2(u.buttonSpacing * float(i), 0.0);
                float button = clamp(0.5 - (length(in.p - centre) - u.buttonRadius), 0.0, 1.0);
                color = mix(color, buttons[i], button);
            }
        }
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

    // The mesh gradient of one of Toma's wallpapers at a stage point: its colours, each weighing exp(-d² / 0.06) by its
    // squared distance d² to the point in units of the stage's longer side (relative to the nearest point's, so the
    // weights never all vanish).
    static float3 wallpaperMesh(float2 stage, constant WallpaperUniforms &u, constant float2 *points, constant float4 *colors) {
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
        return sum / total;
    }

    // A wallpaper's grain at an output pixel: ±2 % from an integer hash of the pixel. It is of the output pixel, not of
    // the stage point, so a zoom of the stage enlarges the gradient and not the grain, and a blur softens the gradient
    // and not the grain.
    static float wallpaperGrain(float2 pixel) {
        uint2 p = uint2(pixel);
        uint h = hash32(p.x ^ hash32(p.y));
        return (float(h >> 8) / 16777216.0 - 0.5) * 0.04;
    }

    // One of Toma's wallpapers, over a quad of any part of the target: its mesh gradient plus its grain. Nothing
    // interpolated is read: a pixel depends on where it is alone, however the drawing is split.
    fragment float4 wallpaperFragment(QuadOut in [[stage_in]],
                                      constant WallpaperUniforms &u [[buffer(0)]],
                                      constant float2 *points [[buffer(1)]],   // fractions of the stage
                                      constant float4 *colors [[buffer(2)]]) { // opaque
        float2 pixel = in.position.xy;   // the centre of the output pixel
        float2 stage = pixel;            // the stage point under it: the same until something transforms the stage
        return float4(saturate(wallpaperMesh(stage, u, points, colors) + wallpaperGrain(pixel)), 1.0);
    }

    // A wallpaper's mesh gradient alone, without its grain, over the whole target (the stage, `BackgroundImages`): what
    // is blurred for a blurred wallpaper.
    fragment float4 wallpaperMeshFragment(GradientOut in [[stage_in]],
                                          constant WallpaperUniforms &u [[buffer(0)]],
                                          constant float2 *points [[buffer(1)]],
                                          constant float4 *colors [[buffer(2)]]) {
        return float4(wallpaperMesh(in.position.xy, u, points, colors), 1.0);
    }

    // A blurred wallpaper over the whole target: its mesh gradient blurred (`BackgroundImages`, the stage's size) at the
    // stage point under the output pixel, plus the grain of the output pixel, as sharp as without the blur.
    fragment float4 blurredWallpaperFragment(GradientOut in [[stage_in]],
                                             constant float2 &stageSize [[buffer(0)]],
                                             texture2d<float> mesh [[texture(0)]],
                                             sampler linearSampler [[sampler(0)]]) {
        float2 pixel = in.position.xy;
        float2 stage = pixel;
        return float4(saturate(mesh.sample(linearSampler, stage / stageSize).rgb + wallpaperGrain(pixel)), 1.0);
    }

    // A background image (`BackgroundImages`), over the whole target: its texture is the stage's size, the image
    // already covering it and blurred, so the output pixel reads the texel of the stage point under it. The stage point
    // is the output pixel until something transforms the stage.
    fragment float4 backgroundImageFragment(GradientOut in [[stage_in]],
                                            constant float2 &stageSize [[buffer(0)]],
                                            texture2d<float> image [[texture(0)]],
                                            sampler linearSampler [[sampler(0)]]) {
        float2 stage = in.position.xy;
        return float4(image.sample(linearSampler, stage / stageSize).rgb, 1.0);
    }

    struct CoverUniforms {
        float2 targetSize;   // the target, in pixels
        float2 uvOrigin;     // texture coordinates at the target's top-left corner
        float2 uvSize;       // texture coordinates across the target
        float2 padding;
    };

    // An image covering the whole target (`BackgroundImages`): the part uvOrigin...uvOrigin + uvSize of it, trilinear
    // from its mipmaps, so an image larger than the target is reduced without aliasing. Opaque.
    fragment float4 coverFragment(GradientOut in [[stage_in]],
                                  constant CoverUniforms &u [[buffer(0)]],
                                  texture2d<float> image [[texture(0)]],
                                  sampler mipSampler [[sampler(0)]]) {
        float2 uv = u.uvOrigin + in.position.xy / u.targetSize * u.uvSize;
        return float4(image.sample(mipSampler, uv).rgb, 1.0);
    }

    struct BlurUniforms {
        float2 direction;   // one texel along the pass: (1, 0) or (0, 1)
        float sigma;        // in texels, > 0
        int radius;         // texels read on each side of the pixel's own: ceil(3σ)
    };

    // One pass of a separable Gaussian blur of σ texels (`BackgroundImages`, where Metal Performance Shaders cannot run),
    // from a source the target's size. A texel past the edge is the edge's (clamp to edge), so nothing dark comes in
    // from outside the image; the weights are normalized over the taps read.
    fragment float4 blurFragment(GradientOut in [[stage_in]],
                                 constant BlurUniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
        constexpr sampler edge(coord::pixel, address::clamp_to_edge, filter::nearest);
        float2 centre = in.position.xy;
        float4 sum = 0.0;
        float total = 0.0;
        for (int i = -u.radius; i <= u.radius; i++) {
            float weight = exp(-float(i * i) / (2.0 * u.sigma * u.sigma));
            sum += source.sample(edge, centre + u.direction * float(i)) * weight;
            total += weight;
        }
        return sum / total;
    }

    // A window frame's title, already premultiplied.
    fragment float4 spriteFragment(QuadOut in [[stage_in]],
                                   texture2d<float> sprite [[texture(0)]],
                                   sampler mipSampler [[sampler(0)]]) {
        return sprite.sample(mipSampler, in.uv);
    }

    // The cursor's image, already premultiplied, at `opacity` (0...1; at 1, exactly the image).
    fragment float4 cursorFragment(QuadOut in [[stage_in]],
                                   constant float &opacity [[buffer(0)]],
                                   texture2d<float> sprite [[texture(0)]],
                                   sampler mipSampler [[sampler(0)]]) {
        return sprite.sample(mipSampler, in.uv) * opacity;
    }

    struct ClickEffectUniforms {
        float2 center;      // output pixels
        float radius;       // a ring's middle circle, or a disc's edge
        float thickness;    // a ring's white, across
        float opacity;      // of the white
        float outline;      // of a ring's 1 px black outline, along both edges of its white
        float ring;         // 1: a ring (a ripple), 0: a filled disc (a circle)
        float padding;
    };

    // A click effect (`ClickEffectLayer`), over a quad around it: a white ring with its outline, or a white disc, with
    // antialiased edges. Premultiplied: the white and the black cover parts of the pixel that do not overlap.
    fragment float4 clickEffectFragment(QuadOut in [[stage_in]],
                                        constant ClickEffectUniforms &u [[buffer(0)]]) {
        float r = length(in.p - u.center);
        if (u.ring == 0.0) {
            return float4(u.opacity * clamp(u.radius + 0.5 - r, 0.0, 1.0));
        }
        float d = abs(r - u.radius);
        float halfWidth = u.thickness * 0.5;
        float white = clamp(halfWidth + 0.5 - d, 0.0, 1.0);
        float outlined = clamp(halfWidth + 1.5 - d, 0.0, 1.0);
        float w = u.opacity * white;
        return float4(w, w, w, w + u.outline * (outlined - white));
    }
    """#
}
