// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of the camera's colour, background and mask (phase 2 design §6.1 and §6.3), in
    /// its shader (§11, step 4): the camera's own drawing (`screenColor`, `borderedCameraColor`) with, on its picture, the
    /// 3D LUT of its look mixed by its intensity (`cameraLook-1`, plan 2b decision 7), and behind the person the camera
    /// itself blurred, or nothing, by the person's mask (`personMask-1`, decisions 5, 6 and 8). Bound after the camera's
    /// own buffers and textures (`Compositor.bindCameraLook`): `CameraLookUniforms` at buffer 3, the LUT at texture 1
    /// with its sampler at 1, the mask at texture 2 (bilinear, with the picture's sampler 0) and the blurred copy at
    /// texture 3 with the trilinear sampler at 2.
    static let cameraLookMetal = #"""

    struct CameraLookUniforms {
        float4 lutScale;    // xyz: the LUT's texture coordinate of a colour is colour × scale + offset
        float4 lutOffset;
        float2 blurTexel;   // a texel of the blur's level, in texture coordinates of the camera's frame
        float intensity;    // 0 to 1: how much of the LUT's result is mixed over the colour; 0, no LUT
        float mode;         // 0: the original background; 1: blurred; 2: removed
        float maskLow;      // the mask's smoothstep: 0.35
        float maskHigh;     //                        0.65
        float blurLevel;    // the level of the camera's mipmaps the blurred background is read at
        float padding;
    };

    // `c` (sRGB-encoded) through the look's LUT, mixed over it by its intensity, clamped to 0…1: `c` itself without one.
    static float3 cameraGraded(float3 c, constant CameraLookUniforms &look, texture3d<float> lut, sampler lutSampler) {
        if (look.intensity <= 0.0) {
            return c;
        }
        float3 uvw = c * look.lutScale.xyz + look.lutOffset.xyz;
        float3 graded = saturate(lut.sample(lutSampler, uvw, level(0.0)).rgb);
        return mix(c, graded, look.intensity);
    }

    // How much of the camera's pixel at uv is the person: the mask's red channel, bilinear, through the smoothstep.
    static float cameraPerson(float2 uv, constant CameraLookUniforms &look, texture2d<float> mask, sampler linearSampler) {
        float m = mask.sample(linearSampler, uv, level(0.0)).r;
        return smoothstep(look.maskLow, look.maskHigh, m);
    }

    // The camera's own frame blurred at uv: its mipmaps at the blur's level, nine samples a texel of that level apart in a
    // 1-2-1 tent on each axis.
    static float3 cameraBlurred(float2 uv, constant CameraLookUniforms &look, texture2d<float> blurred, sampler trilinearSampler) {
        float3 sum = float3(0.0);
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                float weight = float((2 - abs(dx)) * (2 - abs(dy)));
                float2 at = uv + float2(float(dx), float(dy)) * look.blurTexel;
                sum += weight * blurred.sample(trilinearSampler, at, level(look.blurLevel)).rgb;
            }
        }
        return sum / 16.0;
    }

    // The camera's picture at uv with its look, and how much of it is drawn (`a`): with a blurred background, the person
    // over the camera blurred, each through the LUT first, all of it drawn; removed, the person through the LUT, drawn by
    // the mask; the original, the picture through the LUT, all of it drawn.
    static float4 cameraLookPicture(float2 uv, constant QuadUniforms &u, constant CameraLookUniforms &look,
                                    texture2d<float> source, sampler linearSampler, texture3d<float> lut, sampler lutSampler,
                                    texture2d<float> mask, texture2d<float> blurred, sampler trilinearSampler) {
        float3 picture = cameraGraded(source.sample(linearSampler, imageUV(uv, u, source)).rgb, look, lut, lutSampler);
        if (look.mode == 1.0) {
            float3 behind = cameraGraded(cameraBlurred(uv, look, blurred, trilinearSampler), look, lut, lutSampler);
            return float4(mix(behind, picture, cameraPerson(uv, look, mask, linearSampler)), 1.0);
        }
        if (look.mode == 2.0) {
            return float4(picture, cameraPerson(uv, look, mask, linearSampler));
        }
        return float4(picture, 1.0);
    }

    // The camera (`screenColor`'s shape) with its look: premultiplied, its picture's part `a` over `imageCoverage`.
    static float4 cameraLookColor(QuadOut in, constant QuadUniforms &u, constant CameraLookUniforms &look,
                                  texture2d<float> source, sampler linearSampler, texture3d<float> lut, sampler lutSampler,
                                  texture2d<float> mask, texture2d<float> blurred, sampler trilinearSampler) {
        float coverage = imageCoverage(in.p, u);
        float4 picture = cameraLookPicture(in.uv, u, look, source, linearSampler, lut, lutSampler, mask, blurred, trilinearSampler);
        return float4(picture.rgb * picture.a, picture.a) * coverage;
    }

    // The camera with its look and its border over it (`borderedCameraColor`'s stroke): the stroke covers what it covers
    // of the picture whatever the mask, so a card whose person is cut out keeps its border.
    static float4 borderedCameraLookColor(QuadOut in, constant QuadUniforms &u, constant CameraBorderUniforms &b,
                                          constant CameraLookUniforms &look, texture2d<float> source, sampler linearSampler,
                                          texture3d<float> lut, sampler lutSampler, texture2d<float> mask,
                                          texture2d<float> blurred, sampler trilinearSampler) {
        float2 halfSize = u.contentSize * 0.5;
        float radius = min(u.radius, min(halfSize.x, halfSize.y));
        float d = roundedRectDistance(in.p - (u.contentOrigin + halfSize), halfSize, radius);
        float coverage = clamp(0.5 - d, 0.0, 1.0);
        float stroke = (coverage - clamp(0.5 - (d + b.width), 0.0, 1.0)) * b.color.a;
        float4 picture = cameraLookPicture(in.uv, u, look, source, linearSampler, lut, lutSampler, mask, blurred, trilinearSampler);
        float inside = picture.a * (coverage - stroke);
        return float4(picture.rgb * inside + b.color.rgb * stroke, inside + stroke);
    }

    // The camera with its look (`cameraLookColor`) at `opacity`.
    fragment float4 cameraLookFragment(QuadOut in [[stage_in]],
                                       constant QuadUniforms &u [[buffer(0)]],
                                       constant float &opacity [[buffer(1)]],
                                       constant CameraLookUniforms &look [[buffer(3)]],
                                       texture2d<float> source [[texture(0)]],
                                       texture3d<float> lut [[texture(1)]],
                                       texture2d<float> mask [[texture(2)]],
                                       texture2d<float> blurred [[texture(3)]],
                                       sampler linearSampler [[sampler(0)]],
                                       sampler lutSampler [[sampler(1)]],
                                       sampler trilinearSampler [[sampler(2)]]) {
        return cameraLookColor(in, u, look, source, linearSampler, lut, lutSampler, mask, blurred, trilinearSampler) * opacity;
    }

    // The camera with its look and its border (`borderedCameraLookColor`) at `opacity`.
    fragment float4 borderedCameraLookFragment(QuadOut in [[stage_in]],
                                               constant QuadUniforms &u [[buffer(0)]],
                                               constant float &opacity [[buffer(1)]],
                                               constant CameraBorderUniforms &b [[buffer(2)]],
                                               constant CameraLookUniforms &look [[buffer(3)]],
                                               texture2d<float> source [[texture(0)]],
                                               texture3d<float> lut [[texture(1)]],
                                               texture2d<float> mask [[texture(2)]],
                                               texture2d<float> blurred [[texture(3)]],
                                               sampler linearSampler [[sampler(0)]],
                                               sampler lutSampler [[sampler(1)]],
                                               sampler trilinearSampler [[sampler(2)]]) {
        return borderedCameraLookColor(in, u, b, look, source, linearSampler, lut, lutSampler, mask, blurred, trilinearSampler)
            * opacity;
    }

    // `cameraLookFragment` into the target of the motion blur's pass.
    fragment TargetOut cameraLookTargetFragment(QuadOut in [[stage_in]],
                                                constant QuadUniforms &u [[buffer(0)]],
                                                constant float &opacity [[buffer(1)]],
                                                constant CameraLookUniforms &look [[buffer(3)]],
                                                texture2d<float> source [[texture(0)]],
                                                texture3d<float> lut [[texture(1)]],
                                                texture2d<float> mask [[texture(2)]],
                                                texture2d<float> blurred [[texture(3)]],
                                                sampler linearSampler [[sampler(0)]],
                                                sampler lutSampler [[sampler(1)]],
                                                sampler trilinearSampler [[sampler(2)]]) {
        TargetOut out;
        out.color = cameraLookColor(in, u, look, source, linearSampler, lut, lutSampler, mask, blurred, trilinearSampler) * opacity;
        return out;
    }

    // `borderedCameraLookFragment` into the target of the motion blur's pass.
    fragment TargetOut borderedCameraLookTargetFragment(QuadOut in [[stage_in]],
                                                        constant QuadUniforms &u [[buffer(0)]],
                                                        constant float &opacity [[buffer(1)]],
                                                        constant CameraBorderUniforms &b [[buffer(2)]],
                                                        constant CameraLookUniforms &look [[buffer(3)]],
                                                        texture2d<float> source [[texture(0)]],
                                                        texture3d<float> lut [[texture(1)]],
                                                        texture2d<float> mask [[texture(2)]],
                                                        texture2d<float> blurred [[texture(3)]],
                                                        sampler linearSampler [[sampler(0)]],
                                                        sampler lutSampler [[sampler(1)]],
                                                        sampler trilinearSampler [[sampler(2)]]) {
        TargetOut out;
        out.color = borderedCameraLookColor(in, u, b, look, source, linearSampler, lut, lutSampler, mask, blurred,
                                            trilinearSampler) * opacity;
        return out;
    }
    """#
}
