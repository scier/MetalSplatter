# MetalSplatter
Render 3D Gaussian Splats using Metal on Apple platforms (iOS/iPhone/iPad, macOS, and visionOS/Vision Pro)

![A greek-style bust of a woman made of metal, wearing aviator-style goggles while gazing toward colorful abstract metallic blobs floating in space](http://metalsplatter.com/hero.640.jpg)

This is a Swift/Metal library for rendering scenes captured via the techniques described in [3D Gaussian Splatting for Real-Time Radiance Field Rendering](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/). It will let you load up a PLY/SPZ/.splat and visualize it on iOS, macOS, and visionOS (using amplification for rendering in stereo on Vision Pro).

## Modules

| Module | Description |
|--------|-------------|
| **MetalSplatter** | Core GPU renderer for 3D Gaussian Splats |
| **SplatIO** | Readers/writers for splat scene formats (PLY, .splat, SPZ) |
| **PLYIO** | Standalone async PLY file reader/writer (binary and ASCII) |
| **SampleApp** | Minimal demo app for iOS, macOS, and visionOS |
| **SampleBoxRenderer** | Drop-in replacement for MetalSplatter for debugging (renders Apple Metal template cube) |
| **SplatConverter** | CLI tool for converting between splat file formats |

## Requirements

- Swift 6.1+ (Swift Language Mode: v6)
- iOS 18+ / macOS 15+ / visionOS 2+
- Metal-capable GPU (ARM only; x86_64 is unsupported at runtime)

## Installation

Add MetalSplatter as a Swift Package dependency:

```swift
dependencies: [
    .package(url: "https://github.com/scier/MetalSplatter.git", from: "1.0.0")
]
```

Then add the libraries you need to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        "MetalSplatter",  // Core renderer
        "SplatIO",         // File format I/O
        // "PLYIO",        // Only if you need raw PLY access
    ]
)
```

## Getting Started

### Running the Sample App

1. Get a gaussian splat file in PLY, SPZ, or .splat format (see [Resources](#resources) below)
2. Clone the repo and open `SampleApp/MetalSplatter_SampleApp.xcodeproj`
3. For iOS/visionOS: set your development team and bundle ID in Signing & Capabilities
4. Set your scheme to **Release** mode — loading large files in Debug is more than an order of magnitude slower
5. Run. Framerate is better without the debugger attached (stop in Xcode, then launch from the Home screen)

### Using MetalSplatter in Your App

#### 1. Load splat data

Use `SplatIO` to read a splat scene file. The `AutodetectSceneReader` picks the right parser based on file extension:

```swift
import SplatIO

let reader = try AutodetectSceneReader(url)
let stream = try await reader.read()

var allPoints: [SplatPoint] = []
for try await batch in stream {
    allPoints.append(contentsOf: batch)
}
```

Or read specific formats directly:

```swift
let reader = try SplatPLYSceneReader(url)  // PLY files
let reader = try DotSplatSceneReader(url)  // .splat files
let reader = try SPZSceneReader(url)       // .spz files
```

#### 2. Create a SplatChunk

A `SplatChunk` holds GPU-ready splat data in a Metal buffer:

```swift
import MetalSplatter

let chunk = try SplatChunk(device: metalDevice, from: allPoints)
```

For large scenes or streaming, build chunks manually:

```swift
let splatBuffer = try MetalBuffer<EncodedSplatPoint>(device: metalDevice)
for point in points {
    splatBuffer.append(EncodedSplatPoint(point))
}
let chunk = SplatChunk(splats: splatBuffer, shDegree: .sh0)
```

#### 3. Create the renderer

```swift
let renderer = try SplatRenderer(
    device: metalDevice,
    colorFormat: .bgra8Unorm,
    depthFormat: .depth32Float,
    sampleCount: 1,
    maxViewCount: 1,        // 2 for stereo on visionOS
    maxSimultaneousRenders: 3
)
```

Key init parameters:

| Parameter | Description |
|-----------|-------------|
| `maxViewCount` | 1 for mono, 2 for stereo (visionOS). Clamped to 2. |
| `maxSimultaneousRenders` | Number of in-flight frames (typically 3) |
| `highQualityDepth` | Enables multi-stage pipeline with imageblock tile memory for continuous depth. Useful for Vision Pro reprojection. Default: `true` |
| `clearColor` | Background color. Default: transparent black |

#### 4. Add chunks and render

```swift
// Add chunk (async — acquires exclusive access, triggers sort)
let chunkID = await renderer.addChunk(chunk)

// In your render loop:
let viewport = SplatRenderer.ViewportDescriptor(
    viewport: metalViewport,
    projectionMatrix: projectionMatrix,
    viewMatrix: viewMatrix,
    screenSize: SIMD2<Int>(width, height)
)

try renderer.render(
    viewports: [viewport],
    colorTexture: drawable.texture,
    colorStoreAction: .store,
    depthTexture: depthTexture,
    rasterizationRateMap: nil,
    renderTargetArrayLength: 0,
    to: commandBuffer
)
```

#### 5. Manage chunks at runtime

```swift
// Disable a chunk (instant — takes effect next frame)
await renderer.setChunkEnabled(chunkID, enabled: false)

// Remove a chunk
await renderer.removeChunk(chunkID)

// Atomically swap chunks (within exclusive access)
await renderer.withChunkAccess {
    await renderer.removeChunk(oldChunkID)
    await renderer.addChunk(newChunk)
}

// Wait for sort to complete before enabling (avoids visual glitch)
let id = await renderer.addChunk(chunk, enabled: false)
renderer.afterNextSort {
    Task { await renderer.setChunkEnabled(id, enabled: true) }
}
```

## API Reference

### MetalSplatter Module

#### `SplatRenderer`

The main rendering class. Thread-safe (`Sendable`) with internal synchronization.

**Rendering pipeline**: Two shader paths are available:
- **Single-stage**: Standard vertex + fragment pipeline. Produces nearest-splat depth.
- **Multi-stage**: Uses Metal imageblock tile memory (initialization → draw splats → postprocess). Produces blended depth weighted by alpha, better for Vision Pro reprojection. Activated when `highQualityDepth` is `true` and the device supports tile shading.

**Sorting**: Splats are sorted by distance from camera on a background CPU thread. The renderer uses triple-buffered sort index arrays with reference counting so sorting never blocks rendering. Chunk additions/removals patch the existing sorted index buffer to avoid visual glitches while a new sort completes.

**Instanced indexed drawing**: To balance memory and performance, the renderer indexes only 1024 splats and uses GPU instancing for the remainder. This avoids a large index buffer while outperforming pure instancing.

#### `SplatChunk`

A batch of splats with optional spherical harmonics coefficients. Chunks can be independently enabled/disabled and added/removed at runtime.

| Property | Type | Description |
|----------|------|-------------|
| `splats` | `MetalBuffer<EncodedSplatPoint>` | GPU buffer of encoded splat data |
| `shCoefficients` | `MetalBuffer<Float16>?` | Higher-order SH coefficients (nil for SH0-only) |
| `shDegree` | `SHDegree` | SH degree for this chunk (.sh0 through .sh3) |
| `splatCount` | `Int` | Number of splats |

When added to the renderer, splats are reordered by Morton code (Z-order curve) to improve GPU cache locality during rendering. Disable with `sortByLocality: false` if you need to preserve ordering.

#### `MetalBuffer<T>`

Generic, growable Metal buffer with typed CPU access.

```swift
let buffer = try MetalBuffer<EncodedSplatPoint>(device: device)
buffer.append(encodedSplat)
buffer.ensureCapacity(10000)
// Direct access: buffer.values[i], buffer.count, buffer.buffer (MTLBuffer)
```

### SplatIO Module

#### File Format Support

| Format | Read | Write | SH Support | Description |
|--------|------|-------|------------|-------------|
| PLY (binary) | Yes | Yes | SH0–SH3 | Standard 3DGS format, binary little/big endian |
| PLY (ASCII) | Yes | Yes | SH0–SH3 | Human-readable PLY variant |
| .splat | Yes | Yes | SH0 only | Compact binary format (antimatter15) |
| SPZ | Yes | Yes | SH0–SH3 | Compressed gaussian cloud format |

#### `SplatPoint`

High-level representation of a single Gaussian splat. Uses flexible enums for color, opacity, and scale that support multiple representations and auto-convert between them:

```swift
SplatPoint(
    position: SIMD3<Float>(0, 1, 0),
    color: .sRGBUInt8(SIMD3<UInt8>(255, 128, 0)),   // or .sphericalHarmonicFloat([...])
    opacity: .linearFloat(0.95),                      // or .logitFloat(...), .linearUInt8(...)
    scale: .linearFloat(SIMD3<Float>(0.1, 0.1, 0.1)), // or .exponent(...)
    rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
)
```

#### `SHDegree`

| Degree | Coefficients per channel | Total RGB coefficients | View-dependence |
|--------|--------------------------|----------------------|-----------------|
| `.sh0` | 1 | 3 | None (constant color) |
| `.sh1` | 4 | 12 | Low-frequency |
| `.sh2` | 9 | 27 | Medium-frequency |
| `.sh3` | 16 | 48 | High-frequency |

#### Writing splat files

```swift
// Write to PLY
let writer = try SplatPLYSceneWriter(toFileAtPath: "output.ply")
try await writer.start(sphericalHarmonicDegree: 3, binary: true, pointCount: points.count)
try await writer.write(points)
try await writer.close()

// Write to .splat
let writer = try DotSplatSceneWriter(toFileAtPath: "output.splat")
try await writer.write(points)
try await writer.close()

// Write to SPZ
let writer = try SPZSceneWriter(toFileAtPath: "output.spz")
try await writer.start(numPoints: points.count)
try await writer.write(points)
try await writer.close()

// Write to memory instead of file
let writer = try SplatPLYSceneWriter(to: .memory)
// ... write points ...
let data: Data? = await writer.writtenData
```

### PLYIO Module

Standalone async PLY file reader/writer. Use this directly if you need generic PLY access beyond splat scenes.

```swift
import PLYIO

// Read
let reader = try PLYReader(url)
let (header, elements) = try await reader.read()
for try await batch in elements {
    for element in batch.elements {
        let x = element.properties[0]  // PLYElement.Property enum
    }
}

// Write
let writer = try PLYWriter(toFileAtPath: "output.ply")
let header = PLYHeader(
    format: .binaryLittleEndian,
    version: "1.0",
    elements: [
        PLYHeader.Element(name: "vertex", count: 100, properties: [
            PLYHeader.Property(name: "x", type: .primitive(.float32)),
            PLYHeader.Property(name: "y", type: .primitive(.float32)),
            PLYHeader.Property(name: "z", type: .primitive(.float32)),
        ])
    ]
)
try await writer.write(header)
try await writer.write(elements)
try await writer.close()
```

## SplatConverter CLI

Convert between splat file formats from the command line:

```bash
# Convert PLY to SPZ
swift run SplatConverter input.ply --output-file output.spz

# Convert to .splat format
swift run SplatConverter input.ply --output-file output.splat -f dotSplat

# Describe splats (inspect data)
swift run SplatConverter input.ply --describe --start 0 --count 10

# Subset conversion
swift run SplatConverter input.ply --output-file output.ply --start 1000 --count 500
```

Supported output formats: `ply` (binary), `ply-ascii`, `dotSplat`/`splat`, `spz`

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Your Application                      │
├─────────────────────────────────────────────────────────┤
│  SplatRenderer                                           │
│  ├── Chunk management (add/remove/enable/disable)        │
│  ├── CPU sort (background thread, triple-buffered)       │
│  ├── Metal render pipeline (single-stage or multi-stage) │
│  └── Morton code locality optimization                   │
├─────────────────────────────────────────────────────────┤
│  SplatIO                                                 │
│  ├── SplatPLYSceneReader/Writer                          │
│  ├── DotSplatSceneReader/Writer                          │
│  ├── SPZSceneReader/Writer                               │
│  └── AutodetectSceneReader                               │
├─────────────────────────────────────────────────────────┤
│  PLYIO                         │  spz-swift (external)   │
│  ├── PLYReader / PLYWriter     │                         │
│  ├── PLYHeader / PLYElement    │                         │
│  └── Async streaming I/O       │                         │
└─────────────────────────────────────────────────────────┘
```

## Showcase: apps and projects using MetalSplatter

* The [MetalSplatter viewer](https://apps.apple.com/us/app/metalsplatter/id6476895334) is a simple, official Vision Pro app based on this library. This is different from the minimal included sample app (for instance, it has camera controls and a splat gallery). Confusingly, both the (open source) library and (non-open-source) app are called MetalSplatter, and both are by [scier](https://github.com/scier).

* [OverSoul](https://apps.apple.com/app/id6475262918) for Vision Pro: "Capture, share, and interact with spatial photos, 3D models and immersive spaces in a vibrant social ecosystem designed for the next generation of spatial computing"

* Know of another project using MetalSplatter? Let us know!

## Resources

* Looking for 3DGS files? Here are a few suggestions:
   * Capture your own by using a camera or drone, then use [Nerfstudio](https://docs.nerf.studio/nerfology/methods/splat.html) to train the splat
   * Use the [scene data from the original paper](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/)
* [RadianceFields.com](https://radiancefields.com) is a great source to track news and articles about 3DGS, NeRFs, and related technology and tools (for instance [news about MetalSplatter](https://radiancefields.com/platforms/metalsplatter])), and the community surrounding it
* [MrNeRF's Awesome 3D Gaussian Splatting Resources](https://github.com/MrNeRF/awesome-3D-gaussian-splatting) is exactly what it says on the label - in particular, an exhaustive and frequently-updated list of 3DGS-related research
