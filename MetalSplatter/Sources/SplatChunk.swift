import Foundation
import Metal

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
    public let splats: MetalBuffer<EncodedSplat>

    /// Number of splats in this chunk
    public var splatCount: Int { splats.count }

    /// Creates a new splat chunk.
    /// - Parameter splats: The Metal buffer containing splat data
    public init(splats: MetalBuffer<EncodedSplat>) {
        self.splats = splats
    }
}

/// Index into the sorted splat list, identifying both the chunk and the local splat index.
/// Uses 8 bytes for alignment (6 bytes of meaningful data).
/// Keep in sync with ShaderCommon.h : ChunkedSplatIndex
public struct ChunkedSplatIndex: Sendable {
    /// Contiguous index into the chunk table (0..<enabledChunkCount), *not* the same as ``ChunkID``.
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
