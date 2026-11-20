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
    """#
}
