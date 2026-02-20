import Foundation
import Metal
import MetalSplatter
import simd
import SplatIO

/// Controller that procedurally generates colored splat cubes and cycles through LOD levels.
/// Demonstrates adding/removing/enabling/disabling chunks on a live SplatRenderer.
final class ProceduralSplatController: @unchecked Sendable {
    let splatRenderer: SplatRenderer

    // 3 colors × 3 LOD levels
    private let chunks: [[SplatChunk]]  // [colorIndex][lodIndex]
    private var activeChunkIDs: [ChunkID]  // One per color (3 total)

    // Swap cycle state
    private var cycleStep = 0
    private var cycleTask: Task<Void, Never>?

    private static let colors: [SIMD3<UInt8>] = [
        SIMD3(255, 0, 0),    // Red
        SIMD3(0, 255, 0),    // Green
        SIMD3(0, 0, 255),    // Blue
    ]

    init(device: MTLDevice,
         colorFormat: MTLPixelFormat,
         depthFormat: MTLPixelFormat,
         sampleCount: Int,
         maxViewCount: Int,
         maxSimultaneousRenders: Int) async throws {
        splatRenderer = try SplatRenderer(device: device,
                                          colorFormat: colorFormat,
                                          depthFormat: depthFormat,
                                          sampleCount: sampleCount,
                                          maxViewCount: maxViewCount,
                                          maxSimultaneousRenders: maxSimultaneousRenders)

        // Generate cube centers at 120° intervals in the XZ plane
        let centers: [SIMD3<Float>] = (0..<3).map { i in
            let angle = Float(i) * (2 * .pi / 3)
            return SIMD3(
                cos(angle) * Constants.proceduralCubeDistance,
                0,
                sin(angle) * Constants.proceduralCubeDistance
            )
        }

        // Generate 3 colors × 3 LOD grid sizes
        var allChunks: [[SplatChunk]] = []
        for colorIndex in 0..<3 {
            var lodChunks: [SplatChunk] = []
            for gridSize in Constants.proceduralCubeGridSizes {
                let chunk = try Self.generateCubeChunk(
                    device: device,
                    center: centers[colorIndex],
                    size: Constants.proceduralCubeSize,
                    gridSize: gridSize,
                    color: Self.colors[colorIndex]
                )
                lodChunks.append(chunk)
            }
            allChunks.append(lodChunks)
        }
        chunks = allChunks

        // Add initial chunks (LOD 0) as enabled
        var initialIDs: [ChunkID] = []
        for colorIndex in 0..<3 {
            let id = await splatRenderer.addChunk(chunks[colorIndex][0], enabled: true)
            initialIDs.append(id)
        }
        activeChunkIDs = initialIDs
    }

    /// Generate a cube of splats arranged in a uniform grid.
    private static func generateCubeChunk(
        device: MTLDevice,
        center: SIMD3<Float>,
        size: Float,
        gridSize: Int,
        color: SIMD3<UInt8>
    ) throws -> SplatChunk {
        let count = gridSize * gridSize * gridSize
        let spacing = size / Float(gridSize)
        let splatScale = spacing * Constants.proceduralCubeSplatRelativeRadius
        let halfSize = size / 2

        var points: [SplatPoint] = []
        points.reserveCapacity(count)

        for ix in 0..<gridSize {
            for iy in 0..<gridSize {
                for iz in 0..<gridSize {
                    let position = center + SIMD3(
                        -halfSize + (Float(ix) + 0.5) * spacing,
                        -halfSize + (Float(iy) + 0.5) * spacing,
                        -halfSize + (Float(iz) + 0.5) * spacing
                    )
                    let point = SplatPoint(
                        position: position,
                        color: .sRGBUInt8(color),
                        opacity: .linearFloat(1.0),
                        scale: .linearFloat(SIMD3(repeating: splatScale)),
                        rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                    )
                    points.append(point)
                }
            }
        }

        return try SplatChunk(device: device, from: points)
    }

    /// Called each frame to advance the LOD swap cycle.
    func update() {
        guard cycleTask == nil else { return }

        let colorIndex = cycleStep % 3
        let targetLOD = (cycleStep / 3 + 1) % 3
        let oldChunkID = activeChunkIDs[colorIndex]
        let newChunk = chunks[colorIndex][targetLOD]
        let renderer = splatRenderer

        cycleTask = Task {
            // Phase 1: Add new chunk (disabled), then wait for a sort that includes it
            let newID = await renderer.addChunk(newChunk, enabled: false)
            await withCheckedContinuation { continuation in
                renderer.afterNextSort {
                    continuation.resume()
                }
            }

            // Phase 2: Enable new chunk and remove old chunk atomically
            await renderer.withChunkAccess {
                await renderer.setChunkEnabled(newID, enabled: true)
                await renderer.removeChunk(oldChunkID)
            }
            self.activeChunkIDs[colorIndex] = newID

            try? await Task.sleep(for: .seconds(Constants.proceduralCubeSwapDelay))

            // Advance to next step
            self.cycleStep = (self.cycleStep + 1) % 9
            self.cycleTask = nil
        }
    }

}
