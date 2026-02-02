import Foundation
import Metal
import SplatIO

/// Deprecated convenience methods and type aliases for backwards compatibility.
extension SplatRenderer {
    @available(*, deprecated, renamed: "EncodedSplatPoint")
    public typealias Splat = EncodedSplatPoint
}

/// Deprecated convenience methods for backwards compatibility.
/// These methods create a single chunk from the provided data.
extension SplatRenderer {
    /// Reads splat data from a URL and adds it as a chunk.
    /// - Parameter url: The URL to read splat data from
    /// - Note: This method creates a single chunk containing all splats from the file.
    @available(*, deprecated, message: "Use SplatChunk and addChunk(_:) instead. Load splats using SplatIO, create a MetalBuffer, wrap in SplatChunk, then call addChunk.")
    public func read(from url: URL) async throws {
        let points = try await AutodetectSceneReader(url).readAll()
        try await add(points)
    }

    /// Adds splat points as a new chunk.
    /// - Parameter points: The splat points to add
    /// - Note: This method creates a single chunk containing all provided splats.
    @available(*, deprecated, message: "Use SplatChunk and addChunk(_:) instead. Create a MetalBuffer<EncodedSplatPoint>, wrap in SplatChunk, then call addChunk.")
    public func add(_ points: [SplatPoint]) async throws {
        let buffer = try MetalBuffer<EncodedSplatPoint>(device: device)
        try buffer.ensureCapacity(points.count)
        buffer.append(points.map { EncodedSplatPoint($0) })

        let chunk = SplatChunk(splats: buffer, shCoefficients: nil, shDegree: .sh0)
        await addChunk(chunk)
    }

    /// Adds a single splat point as a new chunk.
    /// - Parameter point: The splat point to add
    /// - Note: This method creates a single chunk containing the provided splat.
    @available(*, deprecated, message: "Use SplatChunk and addChunk(_:) instead.")
    public func add(_ point: SplatPoint) async throws {
        try await add([point])
    }

    /// Removes all chunks from the renderer.
    /// - Note: This is equivalent to `removeAllChunks()`.
    @available(*, deprecated, message: "Use removeAllChunks() instead")
    public func reset() async {
        await removeAllChunks()
    }
}
