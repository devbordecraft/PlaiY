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

    float3 linear;
    for (int i = 0; i < 3; i++) {
        float v = hlg[i];
        if (v <= 0.5) {
            linear[i] = (v * v) / 3.0;
        } else {
            linear[i] = (exp((v - c) / a) + b) / 12.0;
        }
    }
    return linear * 1000.0; // HLG reference white ~1000 cd/m2
}

// sRGB/BT.709 gamma encode (linear -> gamma)
float3 srgbGamma(float3 linear) {
    float3 result;
    for (int i = 0; i < 3; i++) {
        float v = linear[i];
        if (v <= 0.0031308) {
            result[i] = 12.92 * v;
        } else {
            result[i] = 1.055 * pow(v, 1.0 / 2.4) - 0.055;
        }
    }
    return result;
}

// sRGB/BT.709 inverse gamma (gamma-encoded -> linear)
// Needed because CAMetalLayer uses extendedLinearDisplayP3 colorspace,
// so all shader output must be linear light.
float3 srgbToLinear(float3 srgb) {
    float3 result;
    for (int i = 0; i < 3; i++) {
        float v = srgb[i];
        if (v <= 0.04045) {
            result[i] = v / 12.92;
        } else {
            result[i] = pow((v + 0.055) / 1.055, 2.4);
        }
    }
    return result;
}

// Tone mapping for HDR content: maps linear light (cd/m2) to EDR output [0, edrHeadroom].
// Preserves SDR range (values at sdrWhite map to 1.0), smoothly compresses highlights
// above SDR white toward the display's EDR peak using extended Reinhard.
float3 hdrToneMap(float3 linearCdm2, float sdrWhite, float maxLum, float edrHeadroom) {
    // Normalize so SDR white = 1.0
    float3 x = linearCdm2 / sdrWhite;
    float peak = edrHeadroom;

    float3 mapped;
    for (int i = 0; i < 3; i++) {
        float v = x[i];
        if (v <= 1.0) {
            // SDR range: pass through linearly (preserves SDR content perfectly)
            mapped[i] = v;
        } else {
            // HDR range: compress [1, inf) -> [1, peak) using Reinhard on the excess
            float excess = v - 1.0;
            float headroom = peak - 1.0;
            mapped[i] = 1.0 + headroom * excess / (excess + headroom);
        }
    }

    return clamp(mapped, 0.0, peak);
}

// ---- Uniforms ----

struct VideoUniforms {
    int colorSpace;     // 0=BT.709, 1=BT.2020
    int transferFunc;   // 0=SDR/BT.709, 1=PQ (HDR10), 2=HLG
    int colorRange;     // 0=limited/video range, 1=full/JPEG range
    float edrHeadroom;  // Max EDR value (e.g., 2.0 means 2x SDR brightness)
    float maxLuminance; // Max content luminance in cd/m2
    float sdrWhite;     // SDR reference white in cd/m2 (typically 203)
};

// ---- NV12/P010 fragment shader (biplanar: Y + UV textures) ----

fragment float4 fragmentBiplanar(
    VertexOut in [[stage_in]],
    texture2d<float> textureY [[texture(0)]],
    texture2d<float> textureUV [[texture(1)]],
    constant VideoUniforms& uniforms [[buffer(0)]])
{
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);

    float y = textureY.sample(texSampler, in.texCoord).r;
    float2 uv = textureUV.sample(texSampler, in.texCoord).rg;

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
    if (uniforms.transferFunc == 1) {
        // PQ HDR10: clamp to valid signal range first (chroma overshoot can
        // produce values outside [0,1] which cause NaN in pow()).
        rgb = clamp(rgb, 0.0, 1.0);
        float3 linear = pqEOTF(rgb);
        float sdrWhite = max(uniforms.sdrWhite, 1.0);
        float maxLum = max(uniforms.maxLuminance, 1000.0);
        rgb = hdrToneMap(linear, sdrWhite, maxLum, uniforms.edrHeadroom);
    } else if (uniforms.transferFunc == 2) {
        // HLG: same clamp needed
        rgb = clamp(rgb, 0.0, 1.0);
        float3 linear = hlgEOTF(rgb);
        float sdrWhite = max(uniforms.sdrWhite, 1.0);
        float maxLum = max(uniforms.maxLuminance, 1000.0);
        rgb = hdrToneMap(linear, sdrWhite, maxLum, uniforms.edrHeadroom);
    } else {
        // SDR: YCbCr-to-RGB produces gamma-encoded values. Convert to linear
        // because CAMetalLayer is configured with extendedLinearDisplayP3.
        rgb = clamp(rgb, 0.0, 1.0);
        rgb = srgbToLinear(rgb);
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
