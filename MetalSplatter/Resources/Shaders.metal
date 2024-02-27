#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

constant const int kMaxViewCount = 2;
constant static const half kBoundsRadius = 3;
constant static const half kBoundsRadiusSquared = kBoundsRadius*kBoundsRadius;

enum PreprocessBufferIndex: int32_t
{
    PreprocessBufferIndexUniforms = 0,
    PreprocessBufferIndexSplat    = 1,
    PreprocessBufferIndexPreprocessedSplat = 2,
};

enum VertexBufferIndex: int32_t
{
    VertexBufferIndexUniforms = 0,
    VertexBufferIndexSplat    = 1,
    VertexBufferIndexPreprocessedSplat = 2,
};

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 viewMatrix;
    uint2 screenSize;

    /*
     The first N splats are represented as as 2N primitives and 4N vertex indices. The remained are represented
     as instanced of these first N. This allows us to limit the size of the indexed array (and associated memory),
     but also avoid the performance penalty of a very large number of instances.
     */
    uint splatCount;
    uint indexedSplatCount;
} Uniforms;

typedef struct
{
    Uniforms uniforms[kMaxViewCount];
} UniformsArray;

typedef struct
{
    packed_float3 position;
    packed_half4 color;
    packed_half3 covA;
    packed_half3 covB;
} Splat;

typedef struct
{
    half2 scaledAxis1;
    half2 scaledAxis2;
} PreprocessedSplat;

typedef struct
{
    float4 position [[position]];
    half2 relativePosition; // Ranges from -kBoundsRadius to +kBoundsRadius
    half4 color;
} ColorInOut;

float3 calcCovariance2D(float3 viewPos,
                        packed_half3 cov3Da,
                        packed_half3 cov3Db,
                        float4x4 viewMatrix,
                        float4x4 projectionMatrix,
                        uint2 screenSize) {
    float invViewPosZ = 1 / viewPos.z;
    float invViewPosZSquared = invViewPosZ * invViewPosZ;

    float tanHalfFovX = 1 / projectionMatrix[0][0];
    float tanHalfFovY = 1 / projectionMatrix[1][1];
    float limX = 1.3 * tanHalfFovX;
    float limY = 1.3 * tanHalfFovY;
    viewPos.x = clamp(viewPos.x * invViewPosZ, -limX, limX) * viewPos.z;
    viewPos.y = clamp(viewPos.y * invViewPosZ, -limY, limY) * viewPos.z;

    float focalX = screenSize.x * projectionMatrix[0][0] / 2;
    float focalY = screenSize.y * projectionMatrix[1][1] / 2;

    float3x3 J = float3x3(
        focalX * invViewPosZ, 0, 0,
        0, focalY * invViewPosZ, 0,
        -(focalX * viewPos.x) * invViewPosZSquared, -(focalY * viewPos.y) * invViewPosZSquared, 0
    );
    float3x3 W = float3x3(viewMatrix[0].xyz, viewMatrix[1].xyz, viewMatrix[2].xyz);
    float3x3 T = J * W;
    float3x3 Vrk = float3x3(
        cov3Da.x, cov3Da.y, cov3Da.z,
        cov3Da.y, cov3Db.x, cov3Db.y,
        cov3Da.z, cov3Db.y, cov3Db.z
    );
    float3x3 cov = T * Vrk * transpose(T);

    // Apply low-pass filter: every Gaussian should be at least
    // one pixel wide/high. Discard 3rd row and column.
    cov[0][0] += 0.3;
    cov[1][1] += 0.3;
    return float3(cov[0][0], cov[0][1], cov[1][1]);
}

// cov2D is a flattened 2d covariance matrix. Given
// covariance = | a b |
//              | c d |
// (where b == c because the Gaussian covariance matrix is symmetric),
// cov2D = ( a, b, d )
void decomposeCovariance(float3 cov2D, thread float2 &v1, thread float2 &v2) {
    float a = cov2D.x;
    float b = cov2D.y;
    float d = cov2D.z;
    float det = a * d - b * b; // matrix is symmetric, so "c" is same as "b"
    float trace = a + d;

    float mean = 0.5 * trace;
    float dist = max(0.1, sqrt(mean * mean - det)); // based on https://github.com/graphdeco-inria/diff-gaussian-rasterization/blob/main/cuda_rasterizer/forward.cu

    // Eigenvalues
    float lambda1 = mean + dist;
    float lambda2 = mean - dist;

    float2 eigenvector1;
    if (b == 0) {
        eigenvector1 = (a > d) ? float2(1, 0) : float2(0, 1);
    } else {
        eigenvector1 = normalize(float2(b, d - lambda2));
    }

    // Gaussian axes are orthogonal
    float2 eigenvector2 = float2(eigenvector1.y, -eigenvector1.x);

    v1 = eigenvector1 * sqrt(lambda1);
    v2 = eigenvector2 * sqrt(lambda2);
}

kernel void splatPreprocessShader(constant UniformsArray& uniformsArray [[ buffer(PreprocessBufferIndexUniforms) ]],
                                  constant Splat* splatArray [[ buffer(PreprocessBufferIndexSplat) ]],
                                  device PreprocessedSplat* preprocessedSplatArray [[ buffer(PreprocessBufferIndexPreprocessedSplat) ]],
                                  uint splatID [[thread_position_in_grid]]) {
    const uint uniformID = 0;
    Uniforms uniforms = uniformsArray.uniforms[min(int(uniformID), kMaxViewCount)];

    Splat splat = splatArray[splatID];
    float3 viewPosition = (uniforms.viewMatrix * float4(splat.position, 1)).xyz;

    float3 cov2D = calcCovariance2D(viewPosition, splat.covA, splat.covB,
                                    uniforms.viewMatrix, uniforms.projectionMatrix, uniforms.screenSize);

    float2 axis1;
    float2 axis2;
    decomposeCovariance(cov2D, axis1, axis2);

    half2 axisScale = half2(2 * kBoundsRadius / uniforms.screenSize.x,
                            2 * kBoundsRadius / uniforms.screenSize.y);
    PreprocessedSplat result;
    result.scaledAxis1 = half2(axis1) * axisScale;
    result.scaledAxis2 = half2(axis2) * axisScale;

    preprocessedSplatArray[splatID] = result;
}

vertex ColorInOut splatVertexShader(constant UniformsArray& uniformsArray [[ buffer(VertexBufferIndexUniforms) ]],
                                    constant Splat* splatArray [[ buffer(VertexBufferIndexSplat) ]],
                                    constant PreprocessedSplat* preprocessedSplatArray [[ buffer(VertexBufferIndexPreprocessedSplat) ]],
                                    uint vertexID [[vertex_id]],
                                    uint instanceID [[instance_id]],
                                    ushort amplificationID [[amplification_id]]) {
    ColorInOut out;

    Uniforms uniforms = uniformsArray.uniforms[min(int(amplificationID), kMaxViewCount)];

    uint splatID = instanceID * uniforms.indexedSplatCount + (vertexID / 4);
    if (splatID >= uniforms.splatCount) {
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    Splat splat = splatArray[splatID];
    PreprocessedSplat preprocessedSplat = preprocessedSplatArray[splatID];
    float4 projectedCenter = uniforms.projectionMatrix * uniforms.viewMatrix * float4(splat.position, 1);

    float bounds = 1.2 * projectedCenter.w;
    if (projectedCenter.z < -projectedCenter.w ||
        projectedCenter.x < -bounds ||
        projectedCenter.x > bounds ||
        projectedCenter.y < -bounds ||
        projectedCenter.y > bounds) {
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    const half2 relativeCoordinatesArray[] = { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } };
    half2 relativeCoordinates = relativeCoordinatesArray[vertexID % 4];
    half2 projectedScreenDelta = relativeCoordinates.x * preprocessedSplat.scaledAxis1 + relativeCoordinates.y * preprocessedSplat.scaledAxis2;
    out.position = float4(projectedCenter.x + projectedScreenDelta.x * projectedCenter.w,
                          projectedCenter.y + projectedScreenDelta.y * projectedCenter.w,
                          projectedCenter.z,
                          projectedCenter.w);
    out.relativePosition = kBoundsRadius * relativeCoordinates;
    out.color = splat.color;
    return out;
}

fragment half4 splatFragmentShader(ColorInOut in [[stage_in]]) {
    half2 v = in.relativePosition;
    half negativeVSquared = -dot(v, v);
    if (negativeVSquared < -kBoundsRadiusSquared) {
        discard_fragment();
    }

    half alpha = exp(0.5 * negativeVSquared) * in.color.a;
    return half4(alpha * in.color.rgb, alpha);
}

