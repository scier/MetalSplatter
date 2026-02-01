#import "ShaderCommon.h"

// MARK: - Spherical Harmonics

/// Evaluates spherical harmonics to compute view-dependent color.
half3 evaluateSH(float3 dir,
                 half3 sh0,
                 device const half* shCoeffs,
                 SHDegree shDegree,
                 uint splatIndex);

// MARK: - Covariance

float3 calcCovariance2D(float3 viewPos,
                        packed_half3 cov3Da,
                        packed_half3 cov3Db,
                        float4x4 viewMatrix,
                        float focalX,
                        float focalY,
                        float tanHalfFovX,
                        float tanHalfFovY);

void decomposeCovariance(float3 cov2D, thread float2 &v1, thread float2 &v2);

// MARK: - Vertex Processing

/// Vertex processing with spherical harmonics evaluation.
/// All splats use this path - splat.color contains raw SH0 coefficients.
/// For SH degree 0, shCoefficients can be nullptr.
FragmentIn splatVertex(Splat splat,
                       Uniforms uniforms,
                       uint relativeVertexIndex,
                       device const half* shCoefficients,
                       SHDegree shDegree,
                       uint splatIndex);

// MARK: - Fragment Processing

half splatFragmentAlpha(half2 relativePosition, half splatAlpha);
