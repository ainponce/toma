// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of the annotations (phase 3 design §5.1 and §12, steps 5 and 7, `annotation-1`),
    /// stuck to the recording and of the output: a layer's bitmap (`AnnotationRasters`), premultiplied, over the quad of
    /// its region.
    /// - `annotationVertex`: the region's corners popped by `scale` and rotated by `rotation` about `pivot` (the centre of
    ///   its box), then through the zoom, `(q − stageCenter) × depth + outputCenter` (as `StageTransform`; the output's
    ///   centre and 1 at rest); with `exact`, the region's corners as they are.
    /// - `annotationFragment`: the bitmap at `opacity`, filtered bilinearly; with `exact` (unrotated, unpopped, at rest, its
    ///   bitmap one texel a pixel), the texel under the pixel read, never filtered, so it is exactly as CoreText and
    ///   CoreGraphics drew it. `annotationTargetFragment`: the same into the target of the motion blur's pass (the core's
    ///   `TargetOut`), over its average.
    /// - `clippedAnnotationFragment` and `clippedAnnotationTargetFragment`: cut to a card by the core's `clipCoverage`
    ///   (`Compositor.CardContent`, its clip and its strength in buffers 1 and 2), as the cursor.
    ///
    /// An image or a clip (plan 3a decisions 4 and 13) is drawn from its own texture, with its shadow, in one drawing:
    /// - `overlayVertex`: a quad of the layer's coordinates (its picture, and its shadow's reach) popped and rotated about
    ///   the centre of its box and through the zoom, as `annotationVertex`; it hands the fragment both the output's pixel
    ///   and the layer's coordinates.
    /// - `overlayColor`: in the layer's coordinates, the picture's rounded rect (its corners at most half its shorter
    ///   side), antialiased over an output pixel (`pixels` of them a unit); the texture under it (an image's with mipmaps,
    ///   its alpha premultiplied; a clip's frame opaque, `opaque`), read through `texOrigin`, `texAcross` and `texDown`
    ///   (a fill's crop, a clip's turn upright, `MediaOrientation`), the level chosen from the coordinates before they are
    ///   held to the picture; under it, with `shadow`, the core's shadow of a rounded box (`shadowValue`, of `ShadowUniforms`
    ///   in buffer 1, in the layer's coordinates, moved down the output), but not under the picture's own rect, so a
    ///   transparent image does not show it through; all at `opacity`.
    /// - `overlayFragment`, `overlayTargetFragment` (into the motion blur's target), and both cut to a card
    ///   (`clippedOverlayFragment`, `clippedOverlayTargetFragment`: its clip and its strength in buffers 2 and 3).
    static let annotationsMetal = #"""

    struct AnnotationUniforms {
        float2 viewport;        // output size
        float2 origin;          // the region's top-left corner, in the layer's coordinates
        float2 size;            // the region's size
        float2 pivot;           // the centre of the layer's box: it pops and turns about it
        float2 rotation;        // cos, sin of its clockwise angle (y down)
        float2 stageCenter;     // the zoom's centre, in the stage's coordinates; the output's centre at rest
        float2 outputCenter;    // the output's centre
        float depth;            // the zoom's depth; 1 at rest
        float scale;            // its pop: 0.9 to 1
        float opacity;          // 0...1
        float exact;            // 1: at rest and one texel a pixel, read
    };

    struct AnnotationOut {
        float4 position [[position]];
        float2 p;    // output pixels
        float2 uv;   // 0...1 across the bitmap
    };

    // A triangle strip of four corners: (0, 0), (1, 0), (0, 1), (1, 1).
    vertex AnnotationOut annotationVertex(uint vid [[vertex_id]], constant AnnotationUniforms &u [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        float2 p = u.origin + corner * u.size;
        float2 o = p;
        if (u.exact == 0.0) {
            float2 d = (p - u.pivot) * u.scale;
            float2 q = u.pivot + float2(d.x * u.rotation.x - d.y * u.rotation.y, d.x * u.rotation.y + d.y * u.rotation.x);
            o = (q - u.stageCenter) * u.depth + u.outputCenter;
        }
        AnnotationOut out;
        out.position = float4(o.x / u.viewport.x * 2.0 - 1.0, 1.0 - o.y / u.viewport.y * 2.0, 0.0, 1.0);
        out.p = o;
        out.uv = corner;
        return out;
    }

    // The layer's colour at the pixel: the texel under it read when exact, its bitmap filtered otherwise; at its opacity.
    static float4 annotationColor(AnnotationOut in, constant AnnotationUniforms &u, texture2d<float> raster,
                                  sampler linearSampler) {
        if (u.exact != 0.0) {
            float2 last = float2(raster.get_width(), raster.get_height()) - 1.0;
            uint2 texel = uint2(clamp(floor(in.p - u.origin), float2(0.0), last));
            return raster.read(texel) * u.opacity;
        }
        return raster.sample(linearSampler, in.uv) * u.opacity;
    }

    fragment float4 annotationFragment(AnnotationOut in [[stage_in]],
                                       constant AnnotationUniforms &u [[buffer(0)]],
                                       texture2d<float> raster [[texture(0)]],
                                       sampler linearSampler [[sampler(0)]]) {
        return annotationColor(in, u, raster, linearSampler);
    }

    fragment TargetOut annotationTargetFragment(AnnotationOut in [[stage_in]],
                                                constant AnnotationUniforms &u [[buffer(0)]],
                                                texture2d<float> raster [[texture(0)]],
                                                sampler linearSampler [[sampler(0)]]) {
        TargetOut out;
        out.color = annotationColor(in, u, raster, linearSampler);
        return out;
    }

    // Cut to a card (`clipCoverage`), as the cursor.
    fragment float4 clippedAnnotationFragment(AnnotationOut in [[stage_in]],
                                              constant AnnotationUniforms &u [[buffer(0)]],
                                              constant QuadUniforms &clip [[buffer(1)]],
                                              constant float &strength [[buffer(2)]],
                                              texture2d<float> raster [[texture(0)]],
                                              sampler linearSampler [[sampler(0)]]) {
        return annotationColor(in, u, raster, linearSampler) * clipCoverage(in.p, clip, strength);
    }

    fragment TargetOut clippedAnnotationTargetFragment(AnnotationOut in [[stage_in]],
                                                       constant AnnotationUniforms &u [[buffer(0)]],
                                                       constant QuadUniforms &clip [[buffer(1)]],
                                                       constant float &strength [[buffer(2)]],
                                                       texture2d<float> raster [[texture(0)]],
                                                       sampler linearSampler [[sampler(0)]]) {
        TargetOut out;
        out.color = annotationColor(in, u, raster, linearSampler) * clipCoverage(in.p, clip, strength);
        return out;
    }

    struct OverlayUniforms {
        float2 viewport;        // output size
        float2 origin;          // the quad's top-left corner, in the layer's coordinates
        float2 size;            // the quad's size
        float2 pivot;           // the centre of the layer's box: it pops and turns about it
        float2 rotation;        // cos, sin of its clockwise angle (y down)
        float2 stageCenter;     // the zoom's centre, in the stage's coordinates; the output's centre at rest
        float2 outputCenter;    // the output's centre
        float2 pictureOrigin;   // the picture's rect, in the layer's coordinates
        float2 pictureSize;
        float2 texOrigin;       // texture coordinates at the picture's top-left corner
        float2 texAcross;       // per unit of its width
        float2 texDown;         // per unit of its height
        float depth;            // the zoom's depth; 1 at rest
        float scale;            // its pop: 0.9 to 1
        float opacity;          // 0...1
        float radius;           // the picture's corners, in the layer's coordinates
        float pixels;           // output pixels a unit of the layer's coordinates: scale × depth
        float shadow;           // 1: its shadow under it (buffer 1)
        float opaque;           // 1: the texture's alpha is not read (a clip's frame)
        float padding;
    };

    struct OverlayOut {
        float4 position [[position]];
        float2 p;    // output pixels
        float2 q;    // the layer's coordinates
    };

    // A triangle strip of four corners: (0, 0), (1, 0), (0, 1), (1, 1).
    vertex OverlayOut overlayVertex(uint vid [[vertex_id]], constant OverlayUniforms &u [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        float2 q = u.origin + corner * u.size;
        float2 d = (q - u.pivot) * u.scale;
        float2 r = u.pivot + float2(d.x * u.rotation.x - d.y * u.rotation.y, d.x * u.rotation.y + d.y * u.rotation.x);
        float2 o = (r - u.stageCenter) * u.depth + u.outputCenter;
        OverlayOut out;
        out.position = float4(o.x / u.viewport.x * 2.0 - 1.0, 1.0 - o.y / u.viewport.y * 2.0, 0.0, 1.0);
        out.p = o;
        out.q = q;
        return out;
    }

    // The picture over its rounded rect, its shadow under it, at its opacity: premultiplied.
    static float4 overlayColor(OverlayOut in, constant OverlayUniforms &u, constant ShadowUniforms &s,
                               texture2d<float> picture, sampler pictureSampler) {
        float2 halfSize = u.pictureSize * 0.5;
        float radius = min(u.radius, min(halfSize.x, halfSize.y));
        float d = roundedRectDistance(in.q - (u.pictureOrigin + halfSize), halfSize, radius) * u.pixels;
        float coverage = clamp(0.5 - d, 0.0, 1.0);
        float2 f = (in.q - u.pictureOrigin) / u.pictureSize;
        float2 raw = u.texOrigin + f.x * u.texAcross + f.y * u.texDown;
        float2 held = clamp(f, 0.0, 1.0);
        float2 uv = u.texOrigin + held.x * u.texAcross + held.y * u.texDown;
        float4 color = picture.sample(pictureSampler, uv, gradient2d(dfdx(raw), dfdy(raw)));
        if (u.opaque != 0.0) {
            color = float4(color.rgb, 1.0);
        }
        color *= coverage;
        if (u.shadow != 0.0) {
            float shadow = s.opacity * shadowValue(in.q, s) * (1.0 - coverage);
            color.a += shadow * (1.0 - color.a);
        }
        return color * u.opacity;
    }

    fragment float4 overlayFragment(OverlayOut in [[stage_in]],
                                    constant OverlayUniforms &u [[buffer(0)]],
                                    constant ShadowUniforms &s [[buffer(1)]],
                                    texture2d<float> picture [[texture(0)]],
                                    sampler pictureSampler [[sampler(0)]]) {
        return overlayColor(in, u, s, picture, pictureSampler);
    }

    fragment TargetOut overlayTargetFragment(OverlayOut in [[stage_in]],
                                             constant OverlayUniforms &u [[buffer(0)]],
                                             constant ShadowUniforms &s [[buffer(1)]],
                                             texture2d<float> picture [[texture(0)]],
                                             sampler pictureSampler [[sampler(0)]]) {
        TargetOut out;
        out.color = overlayColor(in, u, s, picture, pictureSampler);
        return out;
    }

    // Cut to a card (`clipCoverage`), as the cursor.
    fragment float4 clippedOverlayFragment(OverlayOut in [[stage_in]],
                                           constant OverlayUniforms &u [[buffer(0)]],
                                           constant ShadowUniforms &s [[buffer(1)]],
                                           constant QuadUniforms &clip [[buffer(2)]],
                                           constant float &strength [[buffer(3)]],
                                           texture2d<float> picture [[texture(0)]],
                                           sampler pictureSampler [[sampler(0)]]) {
        return overlayColor(in, u, s, picture, pictureSampler) * clipCoverage(in.p, clip, strength);
    }

    fragment TargetOut clippedOverlayTargetFragment(OverlayOut in [[stage_in]],
                                                    constant OverlayUniforms &u [[buffer(0)]],
                                                    constant ShadowUniforms &s [[buffer(1)]],
                                                    constant QuadUniforms &clip [[buffer(2)]],
                                                    constant float &strength [[buffer(3)]],
                                                    texture2d<float> picture [[texture(0)]],
                                                    sampler pictureSampler [[sampler(0)]]) {
        TargetOut out;
        out.color = overlayColor(in, u, s, picture, pictureSampler) * clipCoverage(in.p, clip, strength);
        return out;
    }
    """#
}
