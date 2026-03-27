#include <metal_stdlib>
using namespace metal;

// Vertex output
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen triangle (no vertex buffer needed)
vertex VertexOut vertexFullscreen(uint vertexID [[vertex_id]]) {
    VertexOut out;
    // Generate a full-screen triangle with 3 vertices
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    float2 texCoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// ---- Color space matrices ----

// BT.709 YCbCr to RGB (video range)
constant float3x3 bt709Matrix = float3x3(
    float3(1.164384,  1.164384, 1.164384),
    float3(0.0,      -0.213249, 2.112402),
    float3(1.792741, -0.532909, 0.0)
);

// BT.2020 YCbCr to RGB (video range, 10-bit)
constant float3x3 bt2020Matrix = float3x3(
    float3(1.164384,  1.164384,  1.164384),
    float3(0.0,      -0.187326,  2.141772),
    float3(1.678674, -0.650424,  0.0)
);

// ---- Transfer functions ----

// PQ (SMPTE ST 2084) EOTF: scalar version for single values (e.g., uniform conversion)
float pqToLinear(float pq) {
    float m1 = 0.1593017578125;
    float m2 = 78.84375;
    float c1 = 0.8359375;
    float c2 = 18.8515625;
    float c3 = 18.6875;

    float Np = pow(max(pq, 0.0), 1.0 / m2);
    float L = pow(max(Np - c1, 0.0) / (c2 - c3 * Np), 1.0 / m1);

    return L * 10000.0;
}

// PQ OETF (inverse of pqToLinear): linear cd/m2 -> PQ signal [0, 1]
float linearToPQ(float L) {
    float m1 = 0.1593017578125;
    float m2 = 78.84375;
    float c1 = 0.8359375;
    float c2 = 18.8515625;
    float c3 = 18.6875;

    float Y = max(L / 10000.0, 0.0);
    float Ym1 = pow(Y, m1);
    return pow((c1 + c2 * Ym1) / (1.0 + c3 * Ym1), m2);
}

// PQ (SMPTE ST 2084) EOTF: converts PQ signal to linear light (cd/m2)
float3 pqEOTF(float3 pq) {
    float m1 = 0.1593017578125;
    float m2 = 78.84375;
    float c1 = 0.8359375;
    float c2 = 18.8515625;
    float c3 = 18.6875;

    float3 Np = pow(max(pq, 0.0), float3(1.0 / m2));
    float3 L = pow(max(Np - c1, 0.0) / (c2 - c3 * Np), float3(1.0 / m1));

    // L is normalized to [0, 1] where 1 = 10000 cd/m2
    return L * 10000.0;
}

// HLG OETF inverse (ARIB STD-B67)
float3 hlgEOTF(float3 hlg) {
    float a = 0.17883277;
    float b = 0.28466892;
    float c = 0.55991073;

    float3 low  = (hlg * hlg) / 3.0;
    float3 high = (exp((hlg - c) / a) + b) / 12.0;
    return mix(low, high, step(float3(0.5), hlg)) * 1000.0; // HLG reference white ~1000 cd/m2
}

// sRGB/BT.709 gamma encode (linear -> gamma)
float3 srgbGamma(float3 linear) {
    float3 low  = 12.92 * linear;
    float3 high = 1.055 * pow(linear, float3(1.0 / 2.4)) - 0.055;
    return mix(low, high, step(float3(0.0031308), linear));
}

// sRGB/BT.709 inverse gamma (gamma-encoded -> linear)
// Needed because CAMetalLayer uses extendedLinearDisplayP3 colorspace,
// so all shader output must be linear light.
float3 srgbToLinear(float3 srgb) {
    float3 low  = srgb / 12.92;
    float3 high = pow((srgb + 0.055) / 1.055, float3(2.4));
    return mix(low, high, step(float3(0.04045), srgb));
}

// Tone mapping for HDR content: maps linear light (cd/m2) to EDR output [0, edrHeadroom].
// Preserves SDR range (values at sdrWhite map to 1.0), smoothly compresses highlights
// above SDR white toward the display's EDR peak using extended Reinhard.
float3 hdrToneMap(float3 linearCdm2, float sdrWhite, float maxLum, float edrHeadroom) {
    // Normalize so SDR white = 1.0
    float3 x = linearCdm2 / sdrWhite;
    float peak = edrHeadroom;

    // SDR range (v <= 1): pass through. HDR range (v > 1): Reinhard on excess.
    float headroom = peak - 1.0;
    float3 excess = x - 1.0;
    float3 compressed = 1.0 + headroom * excess / (excess + headroom);
    float3 mapped = mix(x, compressed, step(float3(1.0), x));

    return clamp(mapped, 0.0, peak);
}

// BT.2390 EETF: hermite spline tone mapping in PQ domain.
// Maps a PQ-encoded value from source range to display range with smooth roll-off.
float bt2390EETF(float pqVal, float srcMaxPQ, float dstMaxPQ) {
    float e = pqVal / max(srcMaxPQ, 0.001);

    // Knee start: where compression begins
    float ks = 1.5 * dstMaxPQ / srcMaxPQ - 0.5;
    ks = clamp(ks, 0.0, 1.0);

    if (e <= ks) {
        return e * srcMaxPQ;
    }

    // Hermite spline in [ks, 1] -> [ks, maxBound]
    float t = (e - ks) / (1.0 - ks);
    float t2 = t * t;
    float t3 = t2 * t;

    float maxBound = dstMaxPQ / srcMaxPQ;
    float p = 2.0 * t3 - 3.0 * t2 + 1.0;
    float q = t3 - 2.0 * t2 + t;
    float r = -2.0 * t3 + 3.0 * t2;

    float result = p * ks + q * (1.0 - ks) + r * maxBound;
    return result * srcMaxPQ;
}

// HDR10+ bezier curve evaluation (SMPTE ST 2094-40).
// Evaluates a bezier curve defined by knee point and anchor points.
// Input/output in PQ-normalized [0, 1] domain.
float hdr10plusBezier(float x, float kneeX, float kneeY,
                      int numAnchors, constant float* anchors) {
    if (x <= kneeX) {
        // Below knee: linear mapping
        return (kneeX > 0.0) ? x * (kneeY / kneeX) : 0.0;
    }

    // Above knee: bezier curve on [kneeX, 1] -> [kneeY, 1]
    float t = (x - kneeX) / (1.0 - kneeX);

    // Control points: [kneeY, anchors..., 1.0]
    float pts[17];
    pts[0] = kneeY;
    for (int i = 0; i < numAnchors && i < 15; i++) {
        pts[i + 1] = anchors[i];
    }
    pts[numAnchors + 1] = 1.0;
    int n = numAnchors + 1; // bezier degree

    // De Casteljau evaluation
    float work[17];
    for (int i = 0; i <= n; i++) work[i] = pts[i];
    for (int r = 1; r <= n; r++) {
        for (int i = 0; i <= n - r; i++) {
            work[i] = (1.0 - t) * work[i] + t * work[i + 1];
        }
    }
    return work[0];
}

// ---- Uniforms ----

struct VideoUniforms {
    int colorSpace;     // 0=BT.709, 1=BT.2020
    int transferFunc;   // 0=SDR/BT.709, 1=PQ (HDR10), 2=HLG
    int colorRange;     // 0=limited/video range, 1=full/JPEG range
    float edrHeadroom;  // Max EDR value (e.g., 2.0 means 2x SDR brightness)
    float maxLuminance; // Max content luminance in cd/m2
    float sdrWhite;     // SDR reference white in cd/m2 (typically 203)

    // HDR10+ dynamic metadata
    int hdr10plusPresent;       // 0=no, 1=yes
    float kneePointX;
    float kneePointY;
    int numBezierAnchors;
    float bezierAnchors[15];
    float targetMaxLuminance;

    // HDR10+ per-frame max scene content light (R,G,B) in cd/m2
    float maxscl[3];

    // MaxFALL (Maximum Frame Average Light Level) in cd/m2
    float maxFALL;
};

// Dolby Vision reshaping uniforms (passed as buffer(1))
struct DoviUniforms {
    int present;                   // 0=no, 1=yes

    // Per-component reshaping curves
    int numPivots[3];
    float pivots[3][9];
    int polyOrder[3][8];
    float polyCoef[3][8][3];

    // Per-frame brightness (PQ normalized)
    float minPQ, maxPQ, avgPQ;
    float sourceMaxPQ, sourceMinPQ;

    // Trim
    float trimSlope, trimOffset, trimPower;
    float trimChromaWeight, trimSaturationGain;
};

// Evaluate DV piecewise polynomial reshaping for one component
float doviReshape(float x, int numPivots, constant float* pivots,
                  constant int* polyOrder, constant float polyCoef[][3]) {
    if (numPivots < 2) return x;

    // Find which piece x falls into
    int piece = 0;
    for (int i = 1; i < numPivots - 1; i++) {
        if (x >= pivots[i]) piece = i;
    }

    float c0 = polyCoef[piece][0];
    float c1 = polyCoef[piece][1];
    float c2 = polyCoef[piece][2];
    float result = c0 + c1 * x;
    if (polyOrder[piece] >= 2) {
        result += c2 * x * x;
    }
    return clamp(result, 0.0, 1.0);
};

// Dolby Vision trim: apply Slope-Offset-Power curve to luminance.
// This encodes the colorist's mastering intent for the target display.
float3 doviTrimSOP(float3 rgb, float slope, float offset, float power) {
    // Identity fast path
    if (slope == 1.0 && offset == 0.0 && power == 1.0) return rgb;

    // BT.2020 luminance coefficients
    float Y = dot(rgb, float3(0.2627, 0.6780, 0.0593));
    if (Y < 1e-6) return rgb;

    float Y_trim = pow(max(slope * Y + offset, 0.0), power);
    return rgb * (Y_trim / Y);
}

// Dolby Vision trim: apply saturation gain and chroma weight desaturation in highlights.
float3 doviChromaTrim(float3 rgb, float satGain, float chromaWeight) {
    // Identity fast path
    if (satGain == 1.0 && chromaWeight == 1.0) return rgb;

    float Y = dot(rgb, float3(0.2627, 0.6780, 0.0593));

    // Global saturation adjustment
    float3 result = Y + satGain * (rgb - Y);

    // Chroma weight: desaturate highlights to prevent fluorescent-looking brights.
    // chromaWeight < 1.0 reduces chroma in bright regions.
    if (chromaWeight < 1.0 && Y > 0.0) {
        // Smooth ramp: full effect above Y=1.0 (SDR white in linear-normalized space),
        // partial effect in transition zone 0.5-1.0
        float t = smoothstep(0.5, 1.0, Y);
        float blend = mix(1.0, chromaWeight, t);
        result = Y + blend * (result - Y);
    }

    return max(result, 0.0);
}

// Crop/zoom uniforms (passed as buffer(2))
struct CropUniforms {
    float2 texOrigin;  // UV origin for cropped region (default: 0,0)
    float2 texScale;   // UV scale for cropped region (default: 1,1)
};

// Color adjustment uniforms (passed as buffer(3))
struct ColorFilterUniforms {
    float brightness;    // [-1, 1], 0 = neutral
    float contrast;      // [0, 3], 1 = neutral
    float saturation;    // [0, 3], 1 = neutral
    float sharpness;     // [0, 1], 0 = off
};

// ---- NV12/P010 fragment shader (biplanar: Y + UV textures) ----

fragment float4 fragmentBiplanar(
    VertexOut in [[stage_in]],
    texture2d<float> textureY [[texture(0)]],
    texture2d<float> textureUV [[texture(1)]],
    constant VideoUniforms& uniforms [[buffer(0)]],
    constant DoviUniforms& doviUniforms [[buffer(1)]],
    constant CropUniforms& cropUniforms [[buffer(2)]],
    constant ColorFilterUniforms& colorFilters [[buffer(3)]])
{
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);

    // Remap texture coordinates for crop (identity when origin=0, scale=1)
    float2 coord = cropUniforms.texOrigin + in.texCoord * cropUniforms.texScale;

    float y = textureY.sample(texSampler, coord).r;
    float2 uv = textureUV.sample(texSampler, coord).rg;

    // YCbCr to RGB
    float3 ycbcr = float3(y, uv.x, uv.y);

    float3 rgb;
    if (uniforms.colorRange == 1) {
        // Full/JPEG range: Y [0,255], CbCr [0,255] with 128 center
        ycbcr -= float3(0.0, 128.0/255.0, 128.0/255.0);
        // Full-range BT.709 matrix (no 16-235 scaling)
        if (uniforms.colorSpace == 1) {
            const float3x3 bt2020Full = float3x3(
                float3(1.0,  1.0,      1.0),
                float3(0.0, -0.164553, 1.8814),
                float3(1.4746, -0.571353, 0.0));
            rgb = bt2020Full * ycbcr;
        } else {
            const float3x3 bt709Full = float3x3(
                float3(1.0,  1.0,      1.0),
                float3(0.0, -0.187324, 1.8556),
                float3(1.5748, -0.468124, 0.0));
            rgb = bt709Full * ycbcr;
        }
    } else {
        // Limited/video range: Y [16,235], CbCr [16,240] with 128 center
        ycbcr -= float3(16.0/255.0, 128.0/255.0, 128.0/255.0);
        if (uniforms.colorSpace == 1) {
            rgb = bt2020Matrix * ycbcr;
        } else {
            rgb = bt709Matrix * ycbcr;
        }
    }
    // Apply transfer function and tone mapping
    float sdrWhite = max(uniforms.sdrWhite, 1.0);

    if (uniforms.transferFunc == 1) {
        // PQ content (HDR10 / HDR10+ / Dolby Vision)
        rgb = clamp(rgb, 0.0, 1.0);

        if (doviUniforms.present != 0) {
            // Dolby Vision: apply polynomial reshaping in PQ domain, then EOTF
            float3 reshaped;
            reshaped.x = doviReshape(rgb.x, doviUniforms.numPivots[0],
                                     doviUniforms.pivots[0], doviUniforms.polyOrder[0],
                                     doviUniforms.polyCoef[0]);
            reshaped.y = doviReshape(rgb.y, doviUniforms.numPivots[1],
                                     doviUniforms.pivots[1], doviUniforms.polyOrder[1],
                                     doviUniforms.polyCoef[1]);
            reshaped.z = doviReshape(rgb.z, doviUniforms.numPivots[2],
                                     doviUniforms.pivots[2], doviUniforms.polyOrder[2],
                                     doviUniforms.polyCoef[2]);
            float3 linear = pqEOTF(reshaped);

            // Apply DV trim parameters (L2): colorist's mastering intent
            linear = doviTrimSOP(linear, doviUniforms.trimSlope,
                                 doviUniforms.trimOffset, doviUniforms.trimPower);
            linear = doviChromaTrim(linear, doviUniforms.trimSaturationGain,
                                   doviUniforms.trimChromaWeight);

            // L1 brightness-adaptive tone mapping: use per-frame scene brightness
            // instead of static mastering display max luminance
            float maxLum = (doviUniforms.maxPQ > 0.0)
                ? pqToLinear(doviUniforms.maxPQ)
                : max(uniforms.maxLuminance, 1000.0);

            // Scene-adaptive headroom: use avgPQ to modulate EDR for dark scenes.
            // Dark scenes (low avgPQ) get less headroom to preserve shadow intent.
            float effectiveHeadroom = uniforms.edrHeadroom;
            float sceneMid = (doviUniforms.avgPQ > 0.0) ? pqToLinear(doviUniforms.avgPQ) : 0.0;
            if (sceneMid > 0.0 && maxLum > 0.0) {
                float normalizedAvg = sceneMid / maxLum;
                effectiveHeadroom *= mix(0.6, 1.0, smoothstep(0.0, 0.3, normalizedAvg));
            }
            rgb = hdrToneMap(linear, sdrWhite, maxLum, effectiveHeadroom);
        } else if (uniforms.hdr10plusPresent != 0) {
            // HDR10+: apply bezier curve tone mapping per-channel
            float3 norm = rgb; // already in PQ [0, 1]
            for (int i = 0; i < 3; i++) {
                norm[i] = hdr10plusBezier(norm[i], uniforms.kneePointX,
                                          uniforms.kneePointY,
                                          uniforms.numBezierAnchors,
                                          uniforms.bezierAnchors);
            }
            // Bezier output is PQ-normalized for target display; apply EOTF
            float3 linear = pqEOTF(norm);

            // Use per-frame maxscl for scene-adaptive tone mapping
            float sceneMax = max(max(uniforms.maxscl[0], uniforms.maxscl[1]),
                                 uniforms.maxscl[2]);
            if (sceneMax <= 0.0) sceneMax = max(uniforms.targetMaxLuminance, 1000.0);
            rgb = hdrToneMap(linear, sdrWhite, sceneMax, uniforms.edrHeadroom);
        } else {
            // Static HDR10: BT.2390 EETF
            float3 linear = pqEOTF(rgb);
            float maxLum = max(uniforms.maxLuminance, 1000.0);

            // Convert luminance to PQ domain for BT.2390 EETF
            float srcMaxPQ = linearToPQ(maxLum);
            float dstMaxPQ = linearToPQ(max(uniforms.edrHeadroom * sdrWhite, 1.0));

            if (srcMaxPQ > dstMaxPQ * 1.1) {
                // Source brighter than display: apply BT.2390 compression
                float3 pqNorm = rgb; // PQ signal values

                // Scene-adaptive knee using MaxFALL when available:
                // bias the BT.2390 knee higher for bright content (preserve highlights)
                float ksBias = 0.0;
                if (uniforms.maxFALL > 0.0) {
                    float normalizedAvg = uniforms.maxFALL / maxLum;
                    ksBias = mix(0.0, 0.15, smoothstep(0.0, 0.3, normalizedAvg));
                }

                for (int i = 0; i < 3; i++) {
                    pqNorm[i] = bt2390EETF(pqNorm[i], srcMaxPQ, dstMaxPQ + ksBias);
                }
                linear = pqEOTF(pqNorm);
            }
            rgb = linear / sdrWhite;
            rgb = clamp(rgb, 0.0, uniforms.edrHeadroom);
        }
    } else if (uniforms.transferFunc == 2) {
        // HLG: same clamp needed
        rgb = clamp(rgb, 0.0, 1.0);
        float3 linear = hlgEOTF(rgb);
        float maxLum = max(uniforms.maxLuminance, 1000.0);
        rgb = hdrToneMap(linear, sdrWhite, maxLum, uniforms.edrHeadroom);
    } else {
        // SDR: YCbCr-to-RGB produces gamma-encoded values. Convert to linear
        // because CAMetalLayer is configured with extendedLinearDisplayP3.
        rgb = clamp(rgb, 0.0, 1.0);
        rgb = srgbToLinear(rgb);
    }

    // ---- User color adjustments (brightness/contrast/saturation) ----
    // Applied in linear light after all HDR/SDR processing.

    // Sharpening (unsharp mask via neighboring Y texel sampling)
    if (colorFilters.sharpness > 0.001) {
        float2 texelSize = float2(1.0 / textureY.get_width(), 1.0 / textureY.get_height());
        float2 origUV = cropUniforms.texOrigin + in.texCoord * cropUniforms.texScale;
        float center = textureY.sample(texSampler, origUV).r;
        float top    = textureY.sample(texSampler, origUV + float2(0, -texelSize.y)).r;
        float bottom = textureY.sample(texSampler, origUV + float2(0,  texelSize.y)).r;
        float left   = textureY.sample(texSampler, origUV + float2(-texelSize.x, 0)).r;
        float right  = textureY.sample(texSampler, origUV + float2( texelSize.x, 0)).r;
        float blur = (top + bottom + left + right) * 0.25;
        float sharp = (center - blur) * colorFilters.sharpness * 2.0;
        rgb += sharp;
    }

    // Brightness, contrast, saturation
    if (colorFilters.brightness != 0.0 || colorFilters.contrast != 1.0 || colorFilters.saturation != 1.0) {
        rgb += colorFilters.brightness;
        float mid = uniforms.transferFunc > 0 ? 1.0 : 0.5;
        rgb = (rgb - mid) * colorFilters.contrast + mid;
        float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = lum + colorFilters.saturation * (rgb - lum);
        float maxVal = uniforms.transferFunc > 0 ? uniforms.edrHeadroom : 1.0;
        rgb = clamp(rgb, 0.0, maxVal);
    }

    return float4(rgb, 1.0);
}

// ---- Subtitle overlay shader ----

fragment float4 fragmentSubtitle(
    VertexOut in [[stage_in]],
    texture2d<float> subtitleTexture [[texture(0)]])
{
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    return subtitleTexture.sample(texSampler, in.texCoord);
}
