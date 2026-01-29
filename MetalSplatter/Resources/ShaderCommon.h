#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

constant const int kMaxViewCount = 2;
constant static const half kBoundsRadius = 3;
constant static const half kBoundsRadiusSquared = kBoundsRadius*kBoundsRadius;

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
    uint32_t splatCount;
    uint32_t _padding;
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
