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

// ---- Bayer 8x8 dithering matrix ----
// Threshold values normalized to [-0.5, 0.5] range for ordered dithering.
// Eliminates banding in smooth gradients at sub-LSB cost.
constant float bayerMatrix8x8[64] = {
     0.0/64.0 - 0.5, 32.0/64.0 - 0.5,  8.0/64.0 - 0.5, 40.0/64.0 - 0.5,  2.0/64.0 - 0.5, 34.0/64.0 - 0.5, 10.0/64.0 - 0.5, 42.0/64.0 - 0.5,
    48.0/64.0 - 0.5, 16.0/64.0 - 0.5, 56.0/64.0 - 0.5, 24.0/64.0 - 0.5, 50.0/64.0 - 0.5, 18.0/64.0 - 0.5, 58.0/64.0 - 0.5, 26.0/64.0 - 0.5,
    12.0/64.0 - 0.5, 44.0/64.0 - 0.5,  4.0/64.0 - 0.5, 36.0/64.0 - 0.5, 14.0/64.0 - 0.5, 46.0/64.0 - 0.5,  6.0/64.0 - 0.5, 38.0/64.0 - 0.5,
    60.0/64.0 - 0.5, 28.0/64.0 - 0.5, 52.0/64.0 - 0.5, 20.0/64.0 - 0.5, 62.0/64.0 - 0.5, 30.0/64.0 - 0.5, 54.0/64.0 - 0.5, 22.0/64.0 - 0.5,
     3.0/64.0 - 0.5, 35.0/64.0 - 0.5, 11.0/64.0 - 0.5, 43.0/64.0 - 0.5,  1.0/64.0 - 0.5, 33.0/64.0 - 0.5,  9.0/64.0 - 0.5, 41.0/64.0 - 0.5,
    51.0/64.0 - 0.5, 19.0/64.0 - 0.5, 59.0/64.0 - 0.5, 27.0/64.0 - 0.5, 49.0/64.0 - 0.5, 17.0/64.0 - 0.5, 57.0/64.0 - 0.5, 25.0/64.0 - 0.5,
    15.0/64.0 - 0.5, 47.0/64.0 - 0.5,  7.0/64.0 - 0.5, 39.0/64.0 - 0.5, 13.0/64.0 - 0.5, 45.0/64.0 - 0.5,  5.0/64.0 - 0.5, 37.0/64.0 - 0.5,
    63.0/64.0 - 0.5, 31.0/64.0 - 0.5, 55.0/64.0 - 0.5, 23.0/64.0 - 0.5, 61.0/64.0 - 0.5, 29.0/64.0 - 0.5, 53.0/64.0 - 0.5, 21.0/64.0 - 0.5
};

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

// BT.601 YCbCr to RGB (video range, SD content: NTSC/PAL/DVD)
constant float3x3 bt601Matrix = float3x3(
    float3(1.164384,  1.164384,  1.164384),
    float3(0.0,      -0.391762,  2.017232),
    float3(1.596027, -0.812968,  0.0)
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

    // Chroma subsampling format: 0=4:2:0, 1=4:2:2, 2=4:4:4
    int chromaFormat;
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
    float sharpness;         // [0, 1], 0 = off
    float debandEnabled;     // 0.0 = off, 1.0 = on
    float lanczosUpscaling;  // 0.0 = off, 1.0 = on (Lanczos-3 for Y upscaling)
};

// ---- Bicubic Catmull-Rom chroma upsampling ----
// 4:2:0 chroma is half-resolution. Bilinear upsampling causes color bleeding at
// sharp edges. This uses 4 bilinear taps to efficiently evaluate a Catmull-Rom
// bicubic filter, producing sharper chroma reconstruction.

float2 sampleChromaBicubic(texture2d<float> tex, sampler s, float2 coord) {
    float2 texSize = float2(tex.get_width(), tex.get_height());
    float2 invTexSize = 1.0 / texSize;

    // Convert to texel space, offset to texel center
    float2 tc = coord * texSize - 0.5;
    float2 f = fract(tc);
    float2 tc0 = (floor(tc) + 0.5) * invTexSize;

    // Catmull-Rom weights for the fractional position
    // w0 = -0.5*f^3 + f^2 - 0.5*f
    // w1 =  1.5*f^3 - 2.5*f^2 + 1
    // w2 = -1.5*f^3 + 2*f^2 + 0.5*f
    // w3 =  0.5*f^3 - 0.5*f^2
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);

    // Combine into 2 bilinear taps per axis (4 total)
    // Group (w0+w1) and (w2+w3), offset by weight ratio to exploit HW bilinear
    float2 s01 = w0 + w1;
    float2 s23 = w2 + w3;
    float2 offset01 = tc0 + (w1 / s01 - 1.0) * invTexSize;
    float2 offset23 = tc0 + (w3 / s23 + 1.0) * invTexSize;

    float4 t00 = tex.sample(s, float2(offset01.x, offset01.y));
    float4 t10 = tex.sample(s, float2(offset23.x, offset01.y));
    float4 t01 = tex.sample(s, float2(offset01.x, offset23.y));
    float4 t11 = tex.sample(s, float2(offset23.x, offset23.y));

    float4 result = (s01.x * (s01.y * t00 + s23.y * t01) +
                     s23.x * (s01.y * t10 + s23.y * t11));
    // Normalize: total weight = (s01.x + s23.x) * (s01.y + s23.y) = 1.0 for Catmull-Rom
    // but floating point may drift, so normalize explicitly
    result /= (s01.x + s23.x) * (s01.y + s23.y);

    return result.rg;
}

// ---- Lanczos-3 upscaling for Y plane ----
// 6-tap separable Lanczos kernel for high-quality luma upscaling.
// Only used when video resolution is significantly below display resolution.

float lanczos3(float x) {
    if (abs(x) < 1e-6) return 1.0;
    if (abs(x) >= 3.0) return 0.0;
    float pi_x = 3.14159265 * x;
    return (sin(pi_x) / pi_x) * (sin(pi_x / 3.0) / (pi_x / 3.0));
}

float sampleYLanczos3(texture2d<float> tex, sampler s, float2 coord) {
    float2 texSize = float2(tex.get_width(), tex.get_height());
    float2 invTexSize = 1.0 / texSize;

    float2 tc = coord * texSize - 0.5;
    float2 itc = floor(tc);
    float2 f = tc - itc;

    // 6 taps per axis, separable: first horizontal, then vertical
    // Compute horizontal weights
    float hWeights[6];
    float hSum = 0.0;
    for (int i = -2; i <= 3; i++) {
        hWeights[i + 2] = lanczos3(float(i) - f.x);
        hSum += hWeights[i + 2];
    }
    for (int i = 0; i < 6; i++) hWeights[i] /= hSum;

    // Compute vertical weights
    float vWeights[6];
    float vSum = 0.0;
    for (int i = -2; i <= 3; i++) {
        vWeights[i + 2] = lanczos3(float(i) - f.y);
        vSum += vWeights[i + 2];
    }
    for (int i = 0; i < 6; i++) vWeights[i] /= vSum;

    // Separable: for each row, compute horizontal interpolation, then vertical
    float result = 0.0;
    for (int j = -2; j <= 3; j++) {
        float row = 0.0;
        for (int i = -2; i <= 3; i++) {
            float2 samplePos = (itc + float2(float(i), float(j)) + 0.5) * invTexSize;
            row += tex.sample(s, samplePos).r * hWeights[i + 2];
        }
        result += row * vWeights[j + 2];
    }
    return result;
}

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

    // Y plane sampling: use Lanczos-3 when upscaling is enabled, otherwise bilinear
    float y;
    if (colorFilters.lanczosUpscaling > 0.5) {
        y = sampleYLanczos3(textureY, texSampler, coord);
    } else {
        y = textureY.sample(texSampler, coord).r;
    }

    // Chroma sampling: use bicubic for 4:2:0 (both axes subsampled),
    // bilinear for 4:2:2 (only horizontal subsampled), direct for 4:4:4.
    float2 uv;
    if (uniforms.chromaFormat == 0) {
        uv = sampleChromaBicubic(textureUV, texSampler, coord);
    } else {
        uv = textureUV.sample(texSampler, coord).rg;
    }

    // YCbCr to RGB
    float3 ycbcr = float3(y, uv.x, uv.y);

    float3 rgb;
    if (uniforms.colorRange == 1) {
        // Full/JPEG range: Y [0,255], CbCr [0,255] with 128 center
        ycbcr -= float3(0.0, 128.0/255.0, 128.0/255.0);
        if (uniforms.colorSpace == 1) {
            const float3x3 bt2020Full = float3x3(
                float3(1.0,  1.0,      1.0),
                float3(0.0, -0.164553, 1.8814),
                float3(1.4746, -0.571353, 0.0));
            rgb = bt2020Full * ycbcr;
        } else if (uniforms.colorSpace == 2) {
            // BT.601 full range (SD content)
            const float3x3 bt601Full = float3x3(
                float3(1.0,  1.0,      1.0),
                float3(0.0, -0.344136, 1.772),
                float3(1.402, -0.714136, 0.0));
            rgb = bt601Full * ycbcr;
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
        } else if (uniforms.colorSpace == 2) {
            rgb = bt601Matrix * ycbcr;
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

    // ---- BT.2020 to Display P3 gamut mapping ----
    // The output colorspace is extendedLinearDisplayP3. BT.2020 has a wider gamut
    // than Display P3, so some colors (saturated greens/blues) are out of gamut.
    // Without mapping, they hard-clip which shifts hue. This applies a primaries
    // rotation matrix followed by soft-clip desaturation toward luminance.
    if (uniforms.colorSpace == 1) {
        // BT.2020 -> Display P3 primary rotation (3x3 chromatic adaptation)
        // Derived from BT.2020 and Display P3 primary coordinates via Bradford transform
        const float3x3 bt2020ToP3 = float3x3(
            float3( 1.3434, -0.2820, -0.0462),
            float3(-0.0653,  1.0758,  0.0084),
            float3(-0.0029, -0.0193,  1.0372));
        rgb = bt2020ToP3 * rgb;

        // Soft-clip: desaturate out-of-gamut values toward luminance instead of hard clipping
        float lum = dot(rgb, float3(0.2290, 0.6917, 0.0793)); // Display P3 luminance
        float peak = uniforms.transferFunc > 0 ? uniforms.edrHeadroom : 1.0;
        float3 overshoot = max(rgb - peak, 0.0) + max(-rgb, 0.0);
        float maxOver = max(max(overshoot.x, overshoot.y), overshoot.z);
        if (maxOver > 0.0) {
            // Blend toward luminance proportionally to how far out of gamut we are
            float t = saturate(maxOver / max(peak * 0.5, 0.001));
            rgb = mix(rgb, float3(lum), t);
            rgb = clamp(rgb, 0.0, peak);
        }
    }

    // ---- User color adjustments (brightness/contrast/saturation) ----
    // Applied in linear light after all HDR/SDR processing.

    // Debanding: breaks up quantization bands in smooth gradients.
    // Samples 4 neighbors at small offsets, averages if differences are below threshold.
    // Applied before sharpening so CAS doesn't re-sharpen the debanded regions.
    if (colorFilters.debandEnabled > 0.5) {
        float2 texelSize = float2(1.0 / textureY.get_width(), 1.0 / textureY.get_height());
        float2 origUV = cropUniforms.texOrigin + in.texCoord * cropUniforms.texScale;

        // Deterministic pseudo-random offset from fragment position (avoids visible patterns)
        int2 ipos = int2(in.position.xy);
        float angle = float((ipos.x * 73 + ipos.y * 127) % 256) * (3.14159265 * 2.0 / 256.0);
        float radius = 2.0; // sample radius in texels
        float2 dir1 = float2(cos(angle), sin(angle)) * texelSize * radius;
        float2 dir2 = float2(-dir1.y, dir1.x); // perpendicular

        float center = textureY.sample(texSampler, origUV).r;
        float s0 = textureY.sample(texSampler, origUV + dir1).r;
        float s1 = textureY.sample(texSampler, origUV - dir1).r;
        float s2 = textureY.sample(texSampler, origUV + dir2).r;
        float s3 = textureY.sample(texSampler, origUV - dir2).r;

        // Only deband if all neighbors are very close (quantization band, not real edge)
        float threshold = 0.004; // ~1 step in 8-bit (1/255)
        float d0 = abs(s0 - center);
        float d1 = abs(s1 - center);
        float d2 = abs(s2 - center);
        float d3 = abs(s3 - center);
        if (d0 < threshold && d1 < threshold && d2 < threshold && d3 < threshold) {
            float avg = (s0 + s1 + s2 + s3) * 0.25;
            float diff = avg - center;
            rgb += diff; // Apply the luma correction to all channels equally
        }
    }

    // Contrast Adaptive Sharpening (CAS): edge-aware sharpening that enhances
    // real detail without amplifying noise, bands, or compression artifacts.
    // Uses a 3x3 neighborhood to detect local contrast and scales sharpening
    // inversely -- high-contrast edges get less sharpening to prevent halos.
    if (colorFilters.sharpness > 0.001) {
        float2 texelSize = float2(1.0 / textureY.get_width(), 1.0 / textureY.get_height());
        float2 origUV = cropUniforms.texOrigin + in.texCoord * cropUniforms.texScale;

        // Sample 3x3 neighborhood from Y plane
        float tl = textureY.sample(texSampler, origUV + float2(-texelSize.x, -texelSize.y)).r;
        float tc = textureY.sample(texSampler, origUV + float2(          0.0, -texelSize.y)).r;
        float tr = textureY.sample(texSampler, origUV + float2( texelSize.x, -texelSize.y)).r;
        float ml = textureY.sample(texSampler, origUV + float2(-texelSize.x,          0.0)).r;
        float mc = textureY.sample(texSampler, origUV).r;
        float mr = textureY.sample(texSampler, origUV + float2( texelSize.x,          0.0)).r;
        float bl = textureY.sample(texSampler, origUV + float2(-texelSize.x,  texelSize.y)).r;
        float bc = textureY.sample(texSampler, origUV + float2(          0.0,  texelSize.y)).r;
        float br = textureY.sample(texSampler, origUV + float2( texelSize.x,  texelSize.y)).r;

        // Local min/max for contrast detection
        float mnV = min(min(min(tl, tc), min(tr, ml)), min(min(mc, mr), min(bl, min(bc, br))));
        float mxV = max(max(max(tl, tc), max(tr, ml)), max(max(mc, mr), max(bl, max(bc, br))));

        // CAS kernel weight: inversely proportional to local contrast
        // High contrast (edges) -> less sharpening; low contrast (flat) -> more sharpening
        float localContrast = mxV - mnV;
        float adaptiveWeight = 1.0 - saturate(localContrast * 4.0);
        float w = colorFilters.sharpness * adaptiveWeight;

        // Apply sharpening: weighted difference of center vs cross neighbors
        float cross = (tc + ml + mr + bc) * 0.25;
        rgb += (mc - cross) * w * 2.0;
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

    // Ordered dithering (Bayer 8x8): eliminates banding in smooth gradients.
    // Applied as the final step so it operates on the actual output values.
    // Magnitude is one 8-bit LSB (1/255), invisible but breaks quantization bands.
    {
        int2 pos = int2(in.position.xy) % 8;
        float dither = bayerMatrix8x8[pos.y * 8 + pos.x];
        // Scale dither magnitude: 1 LSB for SDR, scaled for HDR EDR range
        float magnitude = (uniforms.transferFunc > 0)
            ? 1.0 / (max(uniforms.edrHeadroom, 1.0) * 255.0)
            : 1.0 / 255.0;
        rgb += dither * magnitude;
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
