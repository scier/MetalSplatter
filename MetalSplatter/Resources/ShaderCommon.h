#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

constant const int kMaxViewCount = 2;
constant static const half kBoundsRadius = 3;
constant static const half kBoundsRadiusSquared = kBoundsRadius*kBoundsRadius;

// Spherical Harmonics constants
// These are normalization factors for SH basis functions
constant const float SH_C0 = 0.28209479177387814f;  // 1/(2*sqrt(pi))
constant const float SH_C1 = 0.4886025119029199f;   // sqrt(3/(4*pi))

constant const float SH_C2_0 =  1.0925484305920792f;  //  0.5 * sqrt(15/pi)
constant const float SH_C2_1 = -1.0925484305920792f;  // -0.5 * sqrt(15/pi)
constant const float SH_C2_2 =  0.31539156525252005f; //  0.25 * sqrt(5/pi)
constant const float SH_C2_3 = -1.0925484305920792f;  // -0.5 * sqrt(15/pi)
constant const float SH_C2_4 =  0.5462742152960396f;  //  0.25 * sqrt(15/pi)

constant const float SH_C3_0 = -0.5900435899266435f;  // -0.25 * sqrt(35/(2*pi))
constant const float SH_C3_1 =  2.890611442640554f;   //  0.5 * sqrt(105/pi)
constant const float SH_C3_2 = -0.4570457994644658f;  // -0.25 * sqrt(21/(2*pi))
constant const float SH_C3_3 =  0.3731763325901154f;  //  0.25 * sqrt(7/pi)
constant const float SH_C3_4 = -0.4570457994644658f;  // -0.25 * sqrt(21/(2*pi))
constant const float SH_C3_5 =  1.445305721320277f;   //  0.25 * sqrt(105/pi)
constant const float SH_C3_6 = -0.5900435899266435f;  // -0.25 * sqrt(35/(2*pi))

// Spherical harmonics degree enum - must match Swift SHDegree
enum SHDegree: uint8_t
{
    SHDegree0 = 0,  // 1 coefficient (DC only)
    SHDegree1 = 1,  // 4 coefficients
    SHDegree2 = 2,  // 9 coefficients
    SHDegree3 = 3   // 16 coefficients
};

enum BufferIndex: int32_t
{
    BufferIndexUniforms    = 0,
    BufferIndexChunkTable  = 1,
    BufferIndexSplatIndex  = 2,
};

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 viewMatrix;
    packed_float3 cameraPosition;  // World-space camera position for SH evaluation
    uint _padding0;                // Padding for alignment
    uint2 screenSize;

    /*
     The first N splats are represented as 2N primitives and 4N vertex indices. The remainder are represented
     as instances of these first N. This allows us to limit the size of the indexed array (and associated memory),
     but also avoid the performance penalty of a very large number of instances.
     */
    uint splatCount;
    uint indexedSplatCount;
} Uniforms;

typedef struct
{
    Uniforms uniforms[kMaxViewCount];
} UniformsArray;

// Keep in sync with EncodedSplat
typedef struct
{
    packed_float3 position;
    packed_half4 color;
    packed_half3 covA;
    packed_half3 covB;
} Splat;

// Keep in sync with Swift: ChunkedSplatIndex
typedef struct
{
    uint16_t chunkIndex;
    uint16_t _padding;
    uint32_t splatIndex;
} ChunkedSplatIndex;

// Information about a single chunk, used in the chunk table
typedef struct
{
    device Splat* splats;
    device half* shCoefficients;   // Null for SH degree 0, otherwise higher-order SH coefficients
    uint32_t splatCount;
    SHDegree shDegree;             // Spherical harmonics degree for this chunk
    uint8_t _shPadding[3];         // Padding for alignment
} ChunkInfo;

// Table of all enabled chunks, passed to shaders
// Layout: header (16 bytes) followed by variable-length chunks array
typedef struct
{
    device ChunkInfo* chunks;      // Pointer to chunks array
    uint16_t enabledChunkCount;
    uint16_t _padding;
    uint32_t _padding2;            // Pad to 16 bytes for alignment
} ChunkTable;

typedef struct
{
    float4 position [[position]];
    half2 relativePosition; // Ranges from -kBoundsRadius to +kBoundsRadius
    half4 color;
} FragmentIn;
