import Foundation
import Metal
import simd
import SplatIO

/// Stable, opaque handle identifying a chunk within a SplatRenderer.
/// ChunkIDs are assigned monotonically and never reused; they are *not* the same as the contiguous
/// chunk indices used internally by the sorter and shaders (see ``ChunkedSplatIndex``).
public struct ChunkID: Hashable, Sendable, Equatable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
}

/// A chunk of gaussian splats.
/// Created externally and added to a SplatRenderer via `addChunk(_:)`.
public struct SplatChunk: @unchecked Sendable {
    /// The splat data buffer
    public let splats: MetalBuffer<EncodedSplatPoint>

    /// Optional buffer containing higher-order spherical harmonics coefficients.
    /// This is nil for SH degree 0 (view-independent color).
    /// For SH1: 9 Float16 values per splat (3 coefficients × 3 RGB)
    /// For SH2: 24 Float16 values per splat (8 coefficients × 3 RGB, cumulative)
    /// For SH3: 45 Float16 values per splat (15 coefficients × 3 RGB, cumulative)
    public let shCoefficients: MetalBuffer<Float16>?

    /// The spherical harmonics degree for this chunk.
    /// All splats in a chunk share the same SH degree.
    public let shDegree: SHDegree

    /// Number of splats in this chunk
    public var splatCount: Int { splats.count }

    /// Creates a new splat chunk with spherical harmonics support.
    /// - Parameters:
    ///   - splats: The Metal buffer containing splat data (with raw SH0 in color field)
    ///   - shCoefficients: Optional buffer with higher-order SH coefficients (nil for SH0)
    ///   - shDegree: The spherical harmonics degree for this chunk
    public init(splats: MetalBuffer<EncodedSplatPoint>,
                shCoefficients: MetalBuffer<Float16>? = nil,
                shDegree: SHDegree = .sh0) {
        self.splats = splats
        self.shCoefficients = shCoefficients
        self.shDegree = shDegree
    }

    /// Creates a chunk from scene points, extracting and preserving spherical harmonics data.
    /// - Parameters:
    ///   - device: Metal device for buffer allocation
    ///   - points: Array of scene points with SH data
    public init(device: MTLDevice,
                from points: [SplatPoint]) throws {
        // Determine the SH degree from the data
        let shDegree = points.first?.color.shDegree ?? .sh0

        // Create splat buffer - always stores raw SH0 coefficients
        let splatBuffer = try MetalBuffer<EncodedSplatPoint>(device: device, capacity: points.count)
        splatBuffer.count = points.count

        for (i, point) in points.enumerated() {
            splatBuffer.values[i] = EncodedSplatPoint(point)
        }

        // Create SH coefficient buffer if we have higher-order SH
        if shDegree > .sh0 {
            let coeffsPerSplat = shDegree.extraCoefficientCount * 3  // RGB per coefficient
            let totalCoeffs = points.count * coeffsPerSplat
            let shBuffer = try MetalBuffer<Float16>(device: device, capacity: totalCoeffs)
            shBuffer.count = totalCoeffs

            // Copy SH coefficients to buffer
            for (i, point) in points.enumerated() {
                let higherOrderCoeffs = point.color.higherOrderSHCoefficients
                let offset = i * coeffsPerSplat
                for (j, coeff) in higherOrderCoeffs.enumerated() {
                    shBuffer.values[offset + j] = Float16(coeff)
                }
            }

            self.shCoefficients = shBuffer
            self.shDegree = shDegree
        } else {
            self.shCoefficients = nil
            self.shDegree = .sh0
        }

        self.splats = splatBuffer
    }
}

/// Index into the sorted splat list, identifying both the chunk and the local splat index.
/// Uses 8 bytes for alignment (6 bytes of meaningful data).
/// Keep in sync with ShaderCommon.h : ChunkedSplatIndex
public struct ChunkedSplatIndex: Sendable {
    /// Contiguous index into the chunks array (0..<chunkCount), *not* the same as ``ChunkID``.
    public var chunkIndex: UInt16

    /// Padding for alignment
    public var _padding: UInt16

    /// Index of the splat within its chunk
    public var splatIndex: UInt32

    public init(chunkIndex: UInt16, splatIndex: UInt32) {
        self.chunkIndex = chunkIndex
        self._padding = 0
        self.splatIndex = splatIndex
    }
}
