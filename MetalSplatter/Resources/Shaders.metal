#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

constant const int kMaxViewCount = 2;
constant static const float kBoundsRadius = 2;
constant static const float kBoundsRadiusSquared = kBoundsRadius*kBoundsRadius;

enum BufferIndex: int32_t
{
    BufferIndexUniforms = 0,
    BufferIndexSplat    = 1,
    BufferIndexOrder    = 2,
};

enum SplatAttribute: int32_t
{
    SplatAttributePosition     = 0,
    SplatAttributeColor        = 1,
    SplatAttributeScale        = 2,
    SplatAttributeRotationQuat = 3,
};

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 viewMatrix;
    uint2 screenSize;
} Uniforms;

typedef struct
{
    Uniforms uniforms[kMaxViewCount];
} UniformsArray;

typedef struct
{
    float3 position      [[attribute(SplatAttributePosition)]];
    float4 color         [[attribute(SplatAttributeColor)]];
    float3 scale         [[attribute(SplatAttributeScale)]];
    float4 rotationQuat  [[attribute(SplatAttributeRotationQuat)]];
} Splat;

typedef struct
{
    float4 position [[position]];
    float2 textureCoordinates;
    float4 color;
} ColorInOut;

float3x3 quaternionToMatrix(float4 quaternion) {
    float3x3 rotationMatrix;
    rotationMatrix[0] = {
        1 - 2 * (quaternion.z * quaternion.z + quaternion.w * quaternion.w),
            2 * (quaternion.y * quaternion.z + quaternion.x * quaternion.w),
            2 * (quaternion.y * quaternion.w - quaternion.x * quaternion.z),
    };
    rotationMatrix[1] = {
            2 * (quaternion.y * quaternion.z - quaternion.x * quaternion.w),
        1 - 2 * (quaternion.y * quaternion.y + quaternion.w * quaternion.w),
            2 * (quaternion.z * quaternion.w + quaternion.x * quaternion.y),
    };
    rotationMatrix[2] = {
            2 * (quaternion.y * quaternion.w + quaternion.x * quaternion.z),
            2 * (quaternion.z * quaternion.w - quaternion.x * quaternion.y),
        1 - 2 * (quaternion.y * quaternion.y + quaternion.z * quaternion.z),
    };
    return rotationMatrix;
}

float3x3 scaleToMatrix(float3 scale) {
    float3x3 scaleMatrix;
    scaleMatrix[0] = { scale.x, 0, 0 };
    scaleMatrix[1] = { 0, scale.y, 0 };
    scaleMatrix[2] = { 0, 0, scale.z };
    return scaleMatrix;
}

void calcCovariance3D(float3 scale, float4 quaternion, thread float3 &cov3Da, thread float3 &cov3Db) {
    float3x3 transform = quaternionToMatrix(quaternion) * scaleToMatrix(scale);
    float3x3 cov3D = transform * transpose(transform);
    cov3Da = float3(cov3D[0][0], cov3D[0][1], cov3D[0][2]);
    cov3Db = float3(cov3D[1][1], cov3D[1][2], cov3D[2][2]);
}

float3 calcCovariance2D(float3 worldPos,
                        float3 cov3Da,
                        float3 cov3Db,
                        float4x4 viewMatrix,
                        float4x4 projectionMatrix,
                        uint2 screenSize) {
    float3 viewPos = (viewMatrix * float4(worldPos, 1)).xyz;

    float tanHalfFovX = 1 / projectionMatrix[0][0];
    float tanHalfFovY = 1 / projectionMatrix[1][1];
    float limX = 1.3 * tanHalfFovX;
    float limY = 1.3 * tanHalfFovY;
    viewPos.x = clamp(viewPos.x / viewPos.z, -limX, limX) * viewPos.z;
    viewPos.y = clamp(viewPos.y / viewPos.z, -limY, limY) * viewPos.z;

    float focalX = screenSize.x * projectionMatrix[0][0] / 2;
    float focalY = screenSize.y * projectionMatrix[1][1] / 2;

    float3x3 J = float3x3(
        focalX / viewPos.z, 0, 0,
        0, focalY / viewPos.z, 0,
        -(focalX * viewPos.x) / (viewPos.z * viewPos.z), -(focalY * viewPos.y) / (viewPos.z * viewPos.z), 0
    );
    float3x3 W = float3x3(viewMatrix[0].xyz, viewMatrix[1].xyz, viewMatrix[2].xyz);
    float3x3 T = J * W;
    float3x3 Vrk = float3x3(
        cov3Da.x, cov3Da.y, cov3Da.z,
        cov3Da.y, cov3Db.x, cov3Db.y,
        cov3Da.z, cov3Db.y, cov3Db.z
    );
    float3x3 cov = T * transpose(Vrk) * transpose(T);

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

    lambda1 *= 2;
    lambda2 *= 2;

    v1 = eigenvector1 * sqrt(lambda1);
    v2 = eigenvector2 * sqrt(lambda2);
}

vertex ColorInOut splatVertexShader(uint vertexID [[vertex_id]],
                                    uint instanceID [[instance_id]],
                                    ushort amp_id [[amplification_id]],
                                    constant Splat* splatArray [[ buffer(BufferIndexSplat) ]],
                                    constant metal::uint32_t* orderArray [[ buffer(BufferIndexOrder) ]],
                                    constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]]) {
    ColorInOut out;

    Uniforms uniforms = uniformsArray.uniforms[min(int(amp_id), kMaxViewCount)];

    Splat splat = splatArray[orderArray[instanceID]];

    float3 cov3Da, cov3Db;
    calcCovariance3D(splat.scale, splat.rotationQuat, cov3Da, cov3Db);
    float3 cov2D = calcCovariance2D(splat.position, cov3Da, cov3Db,
                                    uniforms.viewMatrix, uniforms.projectionMatrix, uniforms.screenSize);

    float2 axis1;
    float2 axis2;
    decomposeCovariance(cov2D, axis1, axis2);

    float4 eyeCenter = uniforms.viewMatrix * float4(splat.position, 1.0);
    float4 projectedCenter = uniforms.projectionMatrix * eyeCenter;

    float bounds = 1.2 * projectedCenter.w;
    if (projectedCenter.z < -projectedCenter.w ||
        projectedCenter.x < -bounds ||
        projectedCenter.x > bounds ||
        projectedCenter.y < -bounds ||
        projectedCenter.y > bounds) {
        out.position = float4(0, 0, 2, 1);
        return out;
    }

    float2 textureCoordinates;
    switch (vertexID % 4) {
        case 0: textureCoordinates = float2(0, 0); break;
        case 1: textureCoordinates = float2(0, 1); break;
        case 2: textureCoordinates = float2(1, 0); break;
        case 3: textureCoordinates = float2(1, 1); break;
    }
    float2 vertexRelativePosition = float2((textureCoordinates.x - 0.5) * 2, (textureCoordinates.y - 0.5) * 2);
    float2 screenCenter = projectedCenter.xy / projectedCenter.w;
    float2 screenSizeFloat = float2(uniforms.screenSize.x, uniforms.screenSize.y);
    float2 screenDelta =
        (vertexRelativePosition.x * axis1 +
         vertexRelativePosition.y * axis2)
        * 2
        * kBoundsRadius
        / screenSizeFloat;
    float2 screenVertex = screenCenter + screenDelta;

    out.position = float4(screenVertex.x, screenVertex.y, 0, 1);
    out.textureCoordinates = textureCoordinates;
    out.color = splat.color;
    return out;
}

fragment float4 splatFragmentShader(ColorInOut in [[stage_in]]) {
    float2 v = kBoundsRadius * float2(in.textureCoordinates.x * 2 - 1, in.textureCoordinates.y * 2 - 1);
    float negativeVSquared = -dot(v, v);
    if (negativeVSquared < -kBoundsRadiusSquared) {
        discard_fragment();
    }

    float alpha = saturate(exp(negativeVSquared)) * in.color.a;
    return float4(alpha * in.color.rgb, alpha);
}

