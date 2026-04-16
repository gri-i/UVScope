#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
    float3 normal   [[attribute(2)]];
};

struct Uniforms {
    float4x4 mvp;
    uint showUVGrid;
    uint faceMode;     // 0=both, 1=front (back inactive), 2=back (front inactive)
    uint inactiveMode; // 0=gray, 1=hide
};

struct UVGridParams {
    float density;
    float lineWidth;
    float opacity;
    float _pad;
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
    float3 n;
};

vertex VSOut uv3d_vs(VertexIn in [[stage_in]],
                     constant Uniforms& u [[buffer(1)]]) {
    VSOut o;
    o.position = u.mvp * float4(in.position, 1.0);
    o.uv = in.uv;
    o.n = normalize(in.normal);
    return o;
}

fragment float4 uv3d_ps(VSOut in [[stage_in]],
                        constant Uniforms& u [[buffer(0)]],
                        constant UVGridParams& grid [[buffer(1)]],
                        texture2d<float> tex [[texture(0)]],
                        bool isFront [[front_facing]]) {
    constexpr sampler s(address::repeat, filter::linear);

    bool isVenue    = (u.showUVGrid == 2 || u.showUVGrid == 3);
    bool isEdgePass = (u.showUVGrid == 3);

    // Edge pass for venue: pure black lines
    if (isEdgePass) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // Base color
    float4 texCol;
    if (isVenue) {
        // Venue: чистый плоский серый без освещения и текстуры.
        float3 base = float3(0.6, 0.6, 0.6);
        texCol = float4(base, 1.0);
    } else {
        // Normal model: texture or dark gray fallback.
        texCol = float4(0.15, 0.15, 0.15, 1.0);
        if (tex.get_width() > 0) {
            texCol = tex.sample(s, in.uv);
        }
    }

    // Inactive side color (flat, no shading)
    float4 gray = float4(0.45, 0.45, 0.45, 1.0);

    // Determine which side is "active"
    bool active = true;
    if (u.faceMode == 1) {        // front active
        active = isFront;
    } else if (u.faceMode == 2) { // back active
        active = !isFront;
    }

    // Choose final color depending on inactive mode
    float4 col = texCol;
    if (!active) {
        if (u.inactiveMode == 1) {
            discard_fragment(); // hide inactive side
        } else {
            col = gray; // flat gray, no shading
        }
    }

    // Optional UV grid overlay (density controlled by UI) — только для основного меша.
    if (!isVenue && u.showUVGrid == 1) {
        float2 uv = in.uv * max(1.0, grid.density);

        float2 f = abs(fract(uv) - 0.5);
        float line = 1.0 - smoothstep(0.0, grid.lineWidth, min(f.x, f.y));

        float3 gridColor = float3(1.0, 1.0, 1.0);
        col.rgb = mix(col.rgb, gridColor, saturate(line) * grid.opacity);
    }

    return col;
}

// ---------------------------
// Floor grid pass (world-space lines, alpha blended)
// ---------------------------

struct GridVSOut {
    float4 position [[position]];
};

vertex GridVSOut grid_vs(uint vid [[vertex_id]],
                         constant float3* pos [[buffer(0)]],
                         constant float4x4& mvp [[buffer(1)]]) {
    GridVSOut o;
    o.position = mvp * float4(pos[vid], 1.0);
    return o;
}

fragment half4 grid_ps() {
    // светлая линия с альфой (прозрачность настраиваем на стороне Swift)
    return half4(0.85, 0.85, 0.85, 0.28);
}

// ---------------------------
// Present pass (capTex -> drawable)
// ---------------------------

struct PresentVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex PresentVSOut present_vs(uint vid [[vertex_id]]) {
    float2 pos[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };

    // Обычно правильно для MTKView (если будет вверх ногами — скажешь, инвертнём Y)
    float2 uv[6] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(1.0, 0.0)
    };

    PresentVSOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.uv = uv[vid];
    return o;
}

fragment float4 present_ps(PresentVSOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return tex.sample(s, in.uv);
}
