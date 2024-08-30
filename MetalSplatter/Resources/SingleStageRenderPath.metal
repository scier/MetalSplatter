#include "SplatProcessing.h"

vertex FragmentIn singleStageSplatVertexShader(uint vertexID [[vertex_id]],
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

fragment half4 singleStageSplatFragmentShader(FragmentIn in [[stage_in]]) {
    half alpha = splatFragmentAlpha(in.relativePosition, in.color.a);
    return half4(alpha * in.color.rgb, alpha);
}
