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

    // How a stage drawn through the zoom camera, or into a target of another size, is read: the stage point under a
    // target pixel is `pixel × scale + offset`, in pixels of the frame's output size.
    struct StageMapping {
        float2 scale;
        float2 offset;
    };

    // The gradient at the stage point under the pixel (`StageMapping`), over the whole target: `gradientFragment` through
    // the zoom camera.
    fragment float4 stageGradientFragment(GradientOut in [[stage_in]],
                                          constant GradientUniforms &u [[buffer(0)]],
                                          constant StageMapping &m [[buffer(1)]],
                                          constant float2 &stageSize [[buffer(2)]]) {
        float2 uv = (in.position.xy * m.scale + m.offset) / stageSize;
        float t = clamp(dot(uv - 0.5, u.direction) + 0.5, 0.0, 1.0);
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
        float shapeBottomRadius;   // the shape's bottom corners (`radius` its top ones)
        float topRadius;           // with a shape, the image's own top corners (0: square)
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

    // The same with corners of topRadius along its top edge and bottomRadius along its bottom one (y grows down), each at
    // most half its shorter side.
    static float roundedRectDistance(float2 p, float2 halfSize, float topRadius, float bottomRadius) {
        float most = min(halfSize.x, halfSize.y);
        return roundedRectDistance(p, halfSize, min(p.y < 0.0 ? topRadius : bottomRadius, most));
    }

    // How much of the pixel at p the screen or the camera covers: its rect with antialiased rounded corners. Inside a
    // window frame, the window's rounded rect (the shape, its top and bottom corners each its own) cuts the screen
    // instead, and its own rect along the edge it does not share with the window: the top one, under the bar, square or
    // with corners of topRadius (a window take's, the bar showing behind them).
    static float imageCoverage(float2 p, constant QuadUniforms &u) {
        float2 halfSize = u.contentSize * 0.5;
        float radius = min(u.radius, min(halfSize.x, halfSize.y));
        float d = roundedRectDistance(p - (u.contentOrigin + halfSize), halfSize, radius);
        float coverage = clamp(0.5 - d, 0.0, 1.0);
        if (u.shapeSize.x > 0.0) {
            float2 halfShape = u.shapeSize * 0.5;
            float shape = roundedRectDistance(p - (u.shapeOrigin + halfShape), halfShape, u.radius, u.shapeBottomRadius);
            float rect = roundedRectDistance(p - (u.contentOrigin + halfSize), halfSize, u.topRadius, 0.0);
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

    // The screen and the camera: bilinear, opaque, over `imageCoverage`. The one body of `screenFragment` and of
    // `cameraTargetFragment`.
    static float4 screenColor(QuadOut in, constant QuadUniforms &u, texture2d<float> source, sampler linearSampler) {
        float coverage = imageCoverage(in.p, u);
        float3 color = source.sample(linearSampler, imageUV(in.uv, u, source)).rgb;
        return float4(color, 1.0) * coverage;
    }

    // The screen (`screenColor`) at `opacity`: 1 opaque, exactly as without it; less while it fades in over the screen
    // being left.
    fragment float4 screenFragment(QuadOut in [[stage_in]],
                                   constant QuadUniforms &u [[buffer(0)]],
                                   constant float &opacity [[buffer(1)]],
                                   texture2d<float> source [[texture(0)]],
                                   sampler linearSampler [[sampler(0)]]) {
        return screenColor(in, u, source, linearSampler) * opacity;
    }

    // The screen sampled trilinear from a mipmapped copy of its frame (`ScreenLayer.mipmapped`), over `imageCoverage`, at
    // `opacity`. The level is chosen from how fast the coordinates change before a crop clamps them: those clamped
    // stop changing along the crop's edges, where they would read the full-size level and alias.
    fragment float4 mipmappedScreenFragment(QuadOut in [[stage_in]],
                                            constant QuadUniforms &u [[buffer(0)]],
                                            constant float &opacity [[buffer(1)]],
                                            texture2d<float> source [[texture(0)]],
                                            sampler trilinearSampler [[sampler(0)]]) {
        float coverage = imageCoverage(in.p, u);
        float2 uv = imageUV(in.uv, u, source);
        float3 color = source.sample(trilinearSampler, uv, gradient2d(dfdx(in.uv), dfdy(in.uv))).rgb;
        return float4(color, 1.0) * coverage * opacity;
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

    // The shadow of a rounded box blurred by a Gaussian (Evan Wallace's, `ShadowMath`) at `point`, before its opacity:
    // the rows blurred along x, integrated along y at `ShadowMath.ySamples` samples, at the middle of equal steps over
    // [-3 sigma, 3 sigma] clipped to the box.
    static float shadowValue(float2 point, constant ShadowUniforms &u) {
        float2 centre = (u.lower + u.upper) * 0.5;
        float2 halfSize = (u.upper - u.lower) * 0.5;
        float2 p = point - centre;
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
        return value;
    }

    // The shadow (`shadowValue`): premultiplied black at that alpha times the opacity.
    fragment float4 shadowFragment(QuadOut in [[stage_in]],
                                   constant ShadowUniforms &u [[buffer(0)]]) {
        return float4(0.0, 0.0, 0.0, u.opacity * shadowValue(in.p, u));
    }

    // The camera's shadow (`shadowValue`, at its opacity) under the camera, whose rounded rect is `camera`'s image
    // (`imageCoverage`), drawn over it next at `opacity`: at `opacity` where the camera is not, and under the camera only
    // what the camera lets through, so the two drawn one after the other are the shadow with the camera over it, together
    // at `opacity`. The camera hides its own shadow at any opacity, as it does opaque.
    static float cameraShadowAlpha(float2 p, constant ShadowUniforms &u, constant QuadUniforms &camera, float opacity) {
        float shadow = u.opacity * shadowValue(p, u);
        float covered = imageCoverage(p, camera);
        float shown = covered * opacity;
        return shown < 1.0 ? shadow * opacity * (1.0 - covered) / (1.0 - shown) : 0.0;
    }

    // The camera's shadow (`cameraShadowAlpha`): premultiplied black.
    fragment float4 cameraShadowFragment(QuadOut in [[stage_in]],
                                         constant ShadowUniforms &u [[buffer(0)]],
                                         constant QuadUniforms &camera [[buffer(1)]],
                                         constant float &opacity [[buffer(2)]]) {
        return float4(0.0, 0.0, 0.0, cameraShadowAlpha(in.p, u, camera, opacity));
    }

    // The screen's shadow in the camera layouts, under the screen's group fading at `opacity` (`RenderFrame.screenOpacity`):
    // as the camera's (`cameraShadowAlpha`), with `group` the image of the group's shape (the window with a frame, the
    // screen's rounded rect without), so the group hides its own shadow at any opacity. Premultiplied black.
    fragment float4 screenShadowFragment(QuadOut in [[stage_in]],
                                         constant ShadowUniforms &u [[buffer(0)]],
                                         constant QuadUniforms &group [[buffer(1)]],
                                         constant float &opacity [[buffer(2)]]) {
        return float4(0.0, 0.0, 0.0, cameraShadowAlpha(in.p, u, group, opacity));
    }

    struct CameraBorderUniforms {
        float4 color;   // sRGB, not premultiplied
        float width;    // output pixels, above 0
        float padding0;
        float padding1;
        float padding2;
    };

    // The camera's picture (`screenColor`'s) with its border over it: a stroke `width` wide inside its rounded rect, along
    // its edge and antialiased as the edge is, the picture filling the rect under it. Premultiplied: of the part of the
    // pixel inside the rect, the part in the stroke shows the border's colour over the picture.
    static float4 borderedCameraColor(QuadOut in, constant QuadUniforms &u, constant CameraBorderUniforms &b,
                                      texture2d<float> source, sampler linearSampler) {
        float2 halfSize = u.contentSize * 0.5;
        float radius = min(u.radius, min(halfSize.x, halfSize.y));
        float d = roundedRectDistance(in.p - (u.contentOrigin + halfSize), halfSize, radius);
        float coverage = clamp(0.5 - d, 0.0, 1.0);
        float stroke = (coverage - clamp(0.5 - (d + b.width), 0.0, 1.0)) * b.color.a;
        float3 picture = source.sample(linearSampler, imageUV(in.uv, u, source)).rgb;
        return float4(picture * (coverage - stroke) + b.color.rgb * stroke, coverage);
    }

    // The camera with its border (`borderedCameraColor`) at `opacity`.
    fragment float4 borderedCameraFragment(QuadOut in [[stage_in]],
                                           constant QuadUniforms &u [[buffer(0)]],
                                           constant float &opacity [[buffer(1)]],
                                           constant CameraBorderUniforms &b [[buffer(2)]],
                                           texture2d<float> source [[texture(0)]],
                                           sampler linearSampler [[sampler(0)]]) {
        return borderedCameraColor(in, u, b, source, linearSampler) * opacity;
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
        float radius;           // the window's top corners
        float barBottom;        // where the bar meets the screen
        float bottomRadius;     // the window's bottom corners
        float below;            // how far under the screen's top edge the bar goes on: its round top corners, or 0
    };

    // A window frame's title bar (`WindowFrameLayer`), over a quad around it: the window's rounded rect down to one pixel
    // under the screen's top edge (and behind the screen's round top corners), so the screen, drawn over it, leaves no
    // seam of background where they meet; in the bar's colour, with the buttons' antialiased circles. Opaque,
    // premultiplied by how much of the pixel it covers. The one body of `windowBarFragment` and
    // `fadingWindowBarFragment`.
    static float4 windowBar(QuadOut in, constant WindowBarUniforms &u) {
        float2 halfSize = u.windowSize * 0.5;
        float window = roundedRectDistance(in.p - (u.windowOrigin + halfSize), halfSize, u.radius, u.bottomRadius);
        float bar = in.p.y - (u.barBottom + 1.0 + u.below);
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

    // The title bar (`windowBar`).
    fragment float4 windowBarFragment(QuadOut in [[stage_in]],
                                      constant WindowBarUniforms &u [[buffer(0)]]) {
        return windowBar(in, u);
    }

    // The title bar (`windowBar`) in the screen's group fading at `opacity` (`RenderFrame.screenOpacity`), under the screen
    // drawn over it next at `opacity` (`screen`'s image, `imageCoverage`): at `opacity` where the screen is not, and under
    // it only what the screen lets through, so the bar and the screen over it are the window at `opacity`, never the bar
    // seen through the screen where it goes on under it. At 1, the bar wherever the screen does not cover it whole.
    fragment float4 fadingWindowBarFragment(QuadOut in [[stage_in]],
                                            constant WindowBarUniforms &u [[buffer(0)]],
                                            constant QuadUniforms &screen [[buffer(1)]],
                                            constant float &opacity [[buffer(2)]]) {
        float covered = imageCoverage(in.p, screen);
        float shown = covered * opacity;
        return shown < 1.0 ? windowBar(in, u) * (opacity * (1.0 - covered) / (1.0 - shown)) : float4(0.0);
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

    // One of Toma's wallpapers, over a quad of any part of the target: its mesh gradient at the stage point under the
    // pixel (`StageMapping`) plus the grain of the pixel. Nothing interpolated is read: a pixel depends on where it is
    // alone, however the drawing is split.
    fragment float4 wallpaperFragment(QuadOut in [[stage_in]],
                                      constant WallpaperUniforms &u [[buffer(0)]],
                                      constant float2 *points [[buffer(1)]],   // fractions of the stage
                                      constant float4 *colors [[buffer(2)]],   // opaque
                                      constant StageMapping &m [[buffer(3)]]) {
        float2 pixel = in.position.xy;           // the centre of the target's pixel
        float2 stage = pixel * m.scale + m.offset;
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
    // stage point under the pixel (`StageMapping`), plus the grain of the target's pixel, as sharp as without the blur.
    fragment float4 blurredWallpaperFragment(GradientOut in [[stage_in]],
                                             constant float2 &stageSize [[buffer(0)]],
                                             constant StageMapping &m [[buffer(1)]],
                                             texture2d<float> mesh [[texture(0)]],
                                             sampler linearSampler [[sampler(0)]]) {
        float2 pixel = in.position.xy;
        float2 stage = pixel * m.scale + m.offset;
        return float4(saturate(mesh.sample(linearSampler, stage / stageSize).rgb + wallpaperGrain(pixel)), 1.0);
    }

    // A background image (`BackgroundImages`), over the whole target: its texture is the stage's size, the image
    // already covering it and blurred, so the pixel reads the texel of the stage point under it (`StageMapping`).
    fragment float4 backgroundImageFragment(GradientOut in [[stage_in]],
                                            constant float2 &stageSize [[buffer(0)]],
                                            constant StageMapping &m [[buffer(1)]],
                                            texture2d<float> image [[texture(0)]],
                                            sampler linearSampler [[sampler(0)]]) {
        float2 stage = in.position.xy * m.scale + m.offset;
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
        float2 center;          // output pixels
        float radius;           // a ring's middle circle, or a disc's edge
        float thickness;        // a ring's white, across
        float opacity;          // of the white
        float outline;          // of a ring's black outline, along both edges of its white
        float ring;             // 1: a ring (a ripple), 0: a filled disc (a circle)
        float outlineWidth;     // the outline's: 1 px, times the zoom camera's depth
    };

    // A click effect (`ClickEffectLayer`) at p: a white ring with its outline, or a white disc, with antialiased edges.
    // Premultiplied: the white and the black cover parts of the pixel that do not overlap.
    static float4 clickEffect(float2 p, constant ClickEffectUniforms &u) {
        float r = length(p - u.center);
        if (u.ring == 0.0) {
            return float4(u.opacity * clamp(u.radius + 0.5 - r, 0.0, 1.0));
        }
        float d = abs(r - u.radius);
        float halfWidth = u.thickness * 0.5;
        float outer = u.outlineWidth + 0.5;
        float white = clamp(halfWidth + 0.5 - d, 0.0, 1.0);
        float outlined = clamp(halfWidth + outer - d, 0.0, 1.0);
        float w = u.opacity * white;
        return float4(w, w, w, w + u.outline * (outlined - white));
    }

    // A click effect over a quad around it.
    fragment float4 clickEffectFragment(QuadOut in [[stage_in]],
                                        constant ClickEffectUniforms &u [[buffer(0)]]) {
        return clickEffect(in.p, u);
    }

    // The motion blur's render pass (`Compositor`): attachment 0 is a subsample of the stage, drawn there by the stage's
    // shaders as into a target; 1 is the sum of the subsamples (rgba16Float); 2 is the target. 0 and 1 stay in tile
    // memory (memoryless): the subsamples are summed by programmable blending, reading them where they are drawn.
    struct SumOut {
        float4 sum [[color(1)]];
    };

    struct TargetOut {
        float4 color [[color(2)]];
    };

    // Adds the subsample just drawn, times its weight (1/N), to the sum, over the whole target.
    fragment SumOut accumulateFragment(float4 stage [[color(0)]],
                                       float4 sum [[color(1)]],
                                       constant float &weight [[buffer(0)]]) {
        SumOut out;
        out.sum = sum + stage * weight;
        return out;
    }

    // One of the cursor's samples (`cursorFragment`), added to the sum by the pipeline's blending: `opacity` is its own
    // times its share of the average, 1/N.
    fragment SumOut cursorSampleFragment(QuadOut in [[stage_in]],
                                         constant float &opacity [[buffer(0)]],
                                         texture2d<float> sprite [[texture(0)]],
                                         sampler mipSampler [[sampler(0)]]) {
        SumOut out;
        out.sum = sprite.sample(mipSampler, in.uv) * opacity;
        return out;
    }

    // The average of the subsamples of the stage, into the target.
    fragment TargetOut resolveFragment(float4 sum [[color(1)]]) {
        TargetOut out;
        out.color = sum;
        return out;
    }

    // The average of the cursor's samples (premultiplied, in the sum) over the stage drawn once, into the target.
    fragment TargetOut resolveCursorFragment(float4 stage [[color(0)]],
                                             float4 cursor [[color(1)]]) {
        TargetOut out;
        out.color = cursor + stage * (1.0 - cursor.a);
        return out;
    }

    // A click effect into the target of the motion blur's pass.
    fragment TargetOut clickEffectTargetFragment(QuadOut in [[stage_in]],
                                                 constant ClickEffectUniforms &u [[buffer(0)]]) {
        TargetOut out;
        out.color = clickEffect(in.p, u);
        return out;
    }

    // The camera (`screenColor`) at `opacity` into the target of the motion blur's pass: at 1, exactly as without it.
    fragment TargetOut cameraTargetFragment(QuadOut in [[stage_in]],
                                            constant QuadUniforms &u [[buffer(0)]],
                                            constant float &opacity [[buffer(1)]],
                                            texture2d<float> source [[texture(0)]],
                                            sampler linearSampler [[sampler(0)]]) {
        TargetOut out;
        out.color = screenColor(in, u, source, linearSampler) * opacity;
        return out;
    }

    // The camera with its border (`borderedCameraColor`) at `opacity` into the target of the motion blur's pass.
    fragment TargetOut borderedCameraTargetFragment(QuadOut in [[stage_in]],
                                                    constant QuadUniforms &u [[buffer(0)]],
                                                    constant float &opacity [[buffer(1)]],
                                                    constant CameraBorderUniforms &b [[buffer(2)]],
                                                    texture2d<float> source [[texture(0)]],
                                                    sampler linearSampler [[sampler(0)]]) {
        TargetOut out;
        out.color = borderedCameraColor(in, u, b, source, linearSampler) * opacity;
        return out;
    }

    // The camera's shadow (`cameraShadowAlpha`) into the target of the motion blur's pass.
    fragment TargetOut cameraShadowTargetFragment(QuadOut in [[stage_in]],
                                                  constant ShadowUniforms &u [[buffer(0)]],
                                                  constant QuadUniforms &camera [[buffer(1)]],
                                                  constant float &opacity [[buffer(2)]]) {
        TargetOut out;
        out.color = float4(0.0, 0.0, 0.0, cameraShadowAlpha(in.p, u, camera, opacity));
        return out;
    }
    """#
}
