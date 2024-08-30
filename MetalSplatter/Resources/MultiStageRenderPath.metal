#include "SplatProcessing.h"

typedef struct
{
    half4 color [[raster_order_group(0)]];
    float depth [[raster_order_group(0)]];
} FragmentValues;

typedef struct
{
    FragmentValues values [[imageblock_data]];
} FragmentStore;

typedef struct
{
    half4 color [[color(0)]];
    float depth [[depth(any)]];
} FragmentOut;

kernel void initializeFragmentStore(imageblock<FragmentValues, imageblock_layout_explicit> blockData,
                                    ushort2 localThreadID [[thread_position_in_threadgroup]]) {
    threadgroup_imageblock FragmentValues *values = blockData.data(localThreadID);
    values->color = { 0, 0, 0, 0 };
    values->depth = 0;
}

vertex FragmentIn multiStageSplatVertexShader(uint vertexID [[vertex_id]],
                                              uint instanceID [[instance_id]],
                                              ushort amplificationID [[amplification_id]],
                                              constant Splat* splatArray [[ buffer(BufferIndexSplat) ]],
                                              constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]]) {
    Uniforms uniforms = uniformsArray.uniforms[min(int(amplificationID), kMaxViewCount)];

    uint splatID = instanceID * uniforms.indexedSplatCount + (vertexID / 4);
    if (splatID >= uniforms.splatCount) {
        FragmentIn out;
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    Splat splat = splatArray[splatID];

    return splatVertex(splat, uniforms, vertexID % 4);
}

fragment FragmentStore multiStageSplatFragmentShader(FragmentIn in [[stage_in]],
                                                     FragmentValues previousFragmentValues [[imageblock_data]]) {
    FragmentStore out;

    half alpha = splatFragmentAlpha(in.relativePosition, in.color.a);
    half4 colorWithPremultipliedAlpha = half4(in.color.rgb * alpha, alpha);

    half oneMinusAlpha = 1 - alpha;

    half4 previousColor = previousFragmentValues.color;
    out.values.color = previousColor * oneMinusAlpha + colorWithPremultipliedAlpha;

    float previousDepth = previousFragmentValues.depth;
    float depth = in.position.z;
    out.values.depth = previousDepth * oneMinusAlpha + depth * alpha;

    return out;
}

/// Generate a single triangle covering the entire screen
vertex FragmentIn postprocessVertexShader(uint vertexID [[vertex_id]]) {
    FragmentIn out;

    float4 position;
    position.x = (vertexID == 2) ? 3.0 : -1.0;
    position.y = (vertexID == 0) ? -3.0 : 1.0;
    position.zw = 1.0;

    out.position = position;
    return out;
}

fragment FragmentOut postprocessFragmentShader(FragmentValues fragmentValues [[imageblock_data]]) {
    FragmentOut out;
    out.depth = (fragmentValues.color.a == 0) ? 0 : fragmentValues.depth / fragmentValues.color.a;
    out.color = fragmentValues.color;
    return out;
}

fragment half4 postprocessFragmentShaderNoDepth(FragmentValues fragmentValues [[imageblock_data]]) {
    return fragmentValues.color;
}
