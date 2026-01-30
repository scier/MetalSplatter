#import "SplatProcessing.h"

// MARK: - Color Space Conversion

/// Converts sRGB color to linear color space.
/// This is needed because Metal with sRGB framebuffers expects linear input,
/// while SH evaluation produces sRGB output (matching the reference implementation).
inline half3 sRGBToLinear(half3 srgb) {
    // Using gamma 2.2 approximation (standard for 3DGS training)
    return pow(srgb, half3(2.2h));
}

// MARK: - Spherical Harmonics Evaluation

/// Evaluates spherical harmonics to compute view-dependent color.
/// - Parameters:
///   - dir: Normalized view direction vector (from camera to splat)
///   - sh0: DC term (raw SH band 0 coefficients, RGB)
///   - shCoeffs: Pointer to higher-order SH coefficients (can be null for degree 0)
///   - shDegree: The SH degree (0-3)
///   - splatIndex: Index of the splat (for computing offset into shCoeffs)
/// - Returns: Final RGB color after SH evaluation
inline half3 evaluateSH(float3 dir,
                        half3 sh0,
                        device const half* shCoeffs,
                        SHDegree shDegree,
                        uint splatIndex) {
    // Degree 0 (constant/ambient)
    float3 result = SH_C0 * float3(sh0);

    if (shDegree >= SHDegree1 && shCoeffs != nullptr) {
        float x = dir.x, y = dir.y, z = dir.z;

        // Calculate offset: SH1=3, SH2=8, SH3=15 coefficients (each is RGB triplet)
        uint coeffsPerSplat = (shDegree == SHDegree1) ? 3 :
                              (shDegree == SHDegree2) ? 8 : 15;
        device const packed_half3* sh = (device const packed_half3*)(shCoeffs + splatIndex * coeffsPerSplat * 3);

        // Degree 1: 3 basis functions
        result -= SH_C1 * y * float3(sh[0]);
        result += SH_C1 * z * float3(sh[1]);
        result -= SH_C1 * x * float3(sh[2]);

        if (shDegree >= SHDegree2) {
            float xx = x * x, yy = y * y, zz = z * z;
            float xy = x * y, yz = y * z, xz = x * z;
            float xxMinusYy = xx - yy;
            float xxPlusYy = xx + yy;

            // Degree 2: 5 basis functions
            result += SH_C2_0 * xy * float3(sh[3]);
            result += SH_C2_1 * yz * float3(sh[4]);
            result += SH_C2_2 * (2.0f * zz - xxPlusYy) * float3(sh[5]);
            result += SH_C2_3 * xz * float3(sh[6]);
            result += SH_C2_4 * xxMinusYy * float3(sh[7]);

            if (shDegree >= SHDegree3) {
                float zz4MinusXxYy = 4.0f * zz - xxPlusYy;

                // Degree 3: 7 basis functions
                result += SH_C3_0 * y * (3.0f * xx - yy) * float3(sh[8]);
                result += SH_C3_1 * xy * z * float3(sh[9]);
                result += SH_C3_2 * y * zz4MinusXxYy * float3(sh[10]);
                result += SH_C3_3 * z * (2.0f * zz - 3.0f * xxPlusYy) * float3(sh[11]);
                result += SH_C3_4 * x * zz4MinusXxYy * float3(sh[12]);
                result += SH_C3_5 * z * xxMinusYy * float3(sh[13]);
                result += SH_C3_6 * x * (xx - 3.0f * yy) * float3(sh[14]);
            }
        }
    }

    // Add 0.5 bias and clamp to non-negative (critical for correct colors)
    return half3(max(result + 0.5f, 0.0f));
}

// MARK: - Covariance Projection

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

FragmentIn splatVertex(Splat splat,
                       Uniforms uniforms,
                       uint relativeVertexIndex,
                       device const half* shCoefficients,
                       SHDegree shDegree,
                       uint splatIndex) {
    FragmentIn out;

    float4 viewPosition4 = uniforms.viewMatrix * float4(splat.position, 1);
    float3 viewPosition3 = viewPosition4.xyz;

    half3 srgbColor;
    if (shDegree == SHDegree0) {
        // Fast path for SH0
        srgbColor = half3(max(SH_C0 * float3(splat.color.rgb) + 0.5f, 0.0f));
    } else {
        float3 worldPosition = float3(splat.position);
        float3 viewDir = normalize(worldPosition - float3(uniforms.cameraPosition));
        srgbColor = evaluateSH(viewDir, splat.color.rgb, shCoefficients, shDegree, splatIndex);
    }

    float3 cov2D = calcCovariance2D(viewPosition3, splat.covA, splat.covB,
                                    uniforms.viewMatrix, uniforms.projectionMatrix, uniforms.screenSize);

    float2 axis1;
    float2 axis2;
    decomposeCovariance(cov2D, axis1, axis2);

    float4 projectedCenter = uniforms.projectionMatrix * viewPosition4;

    float bounds = 1.2 * projectedCenter.w;
    if (projectedCenter.z < 0.0 ||
        projectedCenter.z > projectedCenter.w ||
        projectedCenter.x < -bounds ||
        projectedCenter.x > bounds ||
        projectedCenter.y < -bounds ||
        projectedCenter.y > bounds) {
        out.position = float4(1, 1, 0, 1);
        return out;
    }

    const half2 relativeCoordinatesArray[] = { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } };
    half2 relativeCoordinates = relativeCoordinatesArray[relativeVertexIndex];
    half2 screenSizeFloat = half2(uniforms.screenSize.x, uniforms.screenSize.y);
    half2 projectedScreenDelta =
        (relativeCoordinates.x * half2(axis1) + relativeCoordinates.y * half2(axis2))
        * 2
        * kBoundsRadius
        / screenSizeFloat;

    out.position = float4(projectedCenter.x + projectedScreenDelta.x * projectedCenter.w,
                          projectedCenter.y + projectedScreenDelta.y * projectedCenter.w,
                          projectedCenter.z,
                          projectedCenter.w);
    out.relativePosition = kBoundsRadius * relativeCoordinates;

    // Convert from sRGB to linear to match Metal expectations for shader color output
    out.color = half4(sRGBToLinear(srgbColor), splat.color.a);
    return out;
}

half splatFragmentAlpha(half2 relativePosition, half splatAlpha) {
    half negativeMagnitudeSquared = -dot(relativePosition, relativePosition);
    return (negativeMagnitudeSquared < -kBoundsRadiusSquared) ? 0 : exp(0.5 * negativeMagnitudeSquared) * splatAlpha;
}
