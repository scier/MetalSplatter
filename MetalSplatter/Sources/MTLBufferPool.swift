import Metal
import Foundation

/// A thread-safe pool for recycling MTLBuffers, generic over tag type.
///
/// Usage:
/// ```
/// enum MyBufferTag { case vertices, uniforms }
/// let pool = MTLBufferPool<MyBufferTag>()
///
/// // Acquire (may return nil or wrong size)
/// var buffer = pool.acquire(tag: .vertices)
/// if buffer == nil || buffer!.length < requiredSize {
///     buffer = device.makeBuffer(length: requiredSize, options: .storageModeShared)
/// }
///
/// // Release when GPU is done (in command buffer completion handler)
/// pool.release(buffer!, tag: .vertices)
/// ```
final class MTLBufferPool<Tag: Hashable>: @unchecked Sendable {
    private var pools: [Tag: [MTLBuffer]] = [:]
    private let lock = NSLock()

    /// Acquire a recycled buffer. May return nil (pool empty) or a buffer
    /// that's the wrong size - caller must check and allocate if needed.
    func acquire(tag: Tag) -> MTLBuffer? {
        lock.withLock { pools[tag]?.popLast() }
    }

    /// Return a buffer to the pool after the GPU is done with it.
    /// Call this from the command buffer's completion handler.
    func release(_ buffer: MTLBuffer, tag: Tag) {
        lock.withLock { pools[tag, default: []].append(buffer) }
    }

    /// Clear all buffers for a specific tag.
    func clear(tag: Tag) {
        lock.withLock { _ = pools.removeValue(forKey: tag) }
    }

    /// Clear all buffers from all pools.
    func clearAll() {
        lock.withLock { pools.removeAll() }
    }
}
