import Metal
import simd

import Synchronization

/**
 SplatSorter creates a sorted list of splat indices across multiple chunks. It is given a reference to
 an array of chunk buffers (each a MetalBuffer<EncodedSplatPoint>), which may be periodically updated
 using the exclusive access mechanism described below. On each frame, a renderer provides the latest camera
 pose, and then obtains a reference to the latest sorted list of chunked splat indices, which may be one or
 more frames out-of-date. After rendering is completed, it explicitly releases this reference. Between
 obtaining and releasing this reference, the buffer is guaranteed not to be modified.

 ## Buffer Management

 The splat sorter maintains N index buffers (where N=3). Each buffer has:
 - A reference count tracking how many frames currently hold references to it
 - A validity flag indicating whether it can be provided to new frames

 Initially, all buffers are invalid until the first sort completes. Multiple frames may hold references to
 the same buffer simultaneously; the buffer count N is independent of maxSimultaneousRenders.

 ## Obtaining Index Buffers

 Two APIs are provided for obtaining sorted index buffers. The scoped version is preferred:

 ```swift
 // Preferred: scoped access, automatically releases when done
 await sorter.withSortedIndices { buffer in
     renderEncoder.setVertexBuffer(buffer.buffer, offset: 0, index: .splatIndex)
     // ... render ...
 }

 // Alternative: explicit obtain/release (use when scoped access isn't practical)
 if let buffer = await sorter.obtainSortedIndices() {
     defer { sorter.releaseSortedIndices(buffer) }
     // ... render ...
 }
 ```

 When a frame requests a buffer reference:
 - If a valid buffer exists, its reference count is incremented and the buffer is returned
 - If no valid buffer exists, the call awaits (Swift Concurrency-friendly) until one becomes available

 When a frame releases its reference (explicitly or when the scoped closure exits), the buffer's
 reference count is decremented. Buffers are identified by object identity.

 ## Sorting

 The splat sorter maintains an asynchronous sorting loop on a secondary thread, running whenever the camera
 pose or chunk data has changed since the last sort began. Each sort iteration:
 1. Iterates over all enabled chunks and computes depth for each splat
 2. Sorts that list by depth
 3. Writes the sorted indices (chunk index + local splat index) to a buffer, which becomes valid

 When starting a new sort, the sorter selects any buffer with reference count zero. If no such buffer
 exists, the sort awaits until one becomes available.

 If invalidation is requested while a sort is in progress, the resulting buffer is pre-marked as invalid,
 effectively canceling that sort's usefulness without the complexity of actual cancellation.

 ## Exclusive Access for Chunk Updates

 To safely update chunks, callers use:

 ```swift
 func withExclusiveAccess(invalidateIndexBuffers: Bool = true, _ body: () async throws -> Void) async rethrows
 ```

 This method:
 1. Awaits until the sorter is not actively reading chunk data (not in phase 1 of a sort)
 2. While the body executes, blocks new sort iterations from starting and new buffer references from
    being obtained (callers await until exclusive access ends)
 3. If `invalidateIndexBuffers` is true (the default): awaits until all buffer references are released,
    then marks all buffers as invalid (preventing references until a new sort completes)
 4. If `invalidateIndexBuffers` is false: allows existing frames to continue using their (now potentially
    stale) buffer references—useful when merely appending new splats where existing indices remain valid
 */
class SplatSorter: @unchecked Sendable {

    // MARK: - Constants

    private static var bufferCount: Int { 3 }
    private static var pollIntervalNanoseconds: UInt64 { 1_000_000 } // 1ms

    // MARK: - Types

    /// Represents a chunk for sorting purposes
    struct ChunkReference {
        var chunkIndex: UInt16
        let buffer: MetalBuffer<EncodedSplatPoint>
    }

    private struct IndexBuffer {
        let buffer: MetalBuffer<ChunkedSplatIndex>
        var referenceCount: Int = 0
        var isValid: Bool = false
    }

    private struct State {
        var indexBuffers: [IndexBuffer]
        var sortingBufferIndex: Int? = nil
        var mostRecentValidBufferIndex: Int? = nil
        var hasExclusiveAccess: Bool = false
        var pendingInvalidation: Bool = false  // If true, in-progress sort result should be marked invalid
        var cameraPose = CameraPose(position: .zero, forward: SIMD3(0, 0, -1))
        var needsSort: Bool = false
        var chunks: [ChunkReference] = []
        var chunkGeneration: UInt64 = 0  // Incremented on chunk changes; prevents stale sorts from overwriting patched buffers
        var isReadingChunks: Bool = false  // True during phase 1 of sort (reading splat positions)
        var sortLoopRunning: Bool = false
    }

    struct CameraPose: Equatable {
        var position: SIMD3<Float>
        var forward: SIMD3<Float>
    }

    // MARK: - State

    private let state: Mutex<State>
    private let device: MTLDevice

    /// Called when a sort starts.
    /// Called from a background thread.
    var onSortStart: (@Sendable () -> Void)?
    /// Called when a sort completes. The TimeInterval is the duration of the sort.
    /// Called from a background thread.
    var onSortComplete: (@Sendable (TimeInterval) -> Void)?

    // Temporary storage for sorting (reused across iterations, only accessed from sort task)
    private var sortTempStorage: [SplatReferenceAndDepth] = []

    private struct SplatReferenceAndDepth {
        var chunkIndex: UInt16
        var splatIndex: UInt32
        var depth: Float
    }

    // MARK: - Initialization

    init(device: MTLDevice) throws {
        self.device = device

        var indexBuffers: [IndexBuffer] = []
        for _ in 0..<Self.bufferCount {
            let buffer = try MetalBuffer<ChunkedSplatIndex>(device: device)
            indexBuffers.append(IndexBuffer(buffer: buffer))
        }

        self.state = Mutex(State(indexBuffers: indexBuffers))
    }

    // MARK: - Chunk Management

    /// The current chunks being sorted. Update via `withExclusiveAccess` for thread safety.
    var chunks: [ChunkReference] {
        get { state.withLock { $0.chunks } }
    }

    /// Total splat count across all chunks
    var totalSplatCount: Int {
        state.withLock { state in
            state.chunks.reduce(0) { $0 + $1.buffer.count }
        }
    }

    /// Sets the chunks to sort. Must be called within `withExclusiveAccess` for thread safety,
    /// or during initial setup before any sorting begins.
    func setChunks(_ chunks: [ChunkReference]) {
        state.withLock { state in
            state.chunks = chunks
            state.needsSort = !chunks.isEmpty
        }
        ensureSortLoopRunning()
    }

    /// Adds a chunk to the sort and patches the valid index buffer to include its splats.
    /// The new chunk's splats are appended unsorted; the background sort will re-sort on the next cycle.
    ///
    /// Must be called when no render references are held (i.e., inside withChunkAccess).
    func addChunkToSort(_ chunk: ChunkReference) throws {
        try state.withLock { state in
            state.chunks.append(chunk)
            state.chunkGeneration &+= 1
            state.needsSort = true
            try extendValidBufferWithNewChunk(chunk, state: &state)
        }
        ensureSortLoopRunning()
    }

    /// Removes a chunk from the sort and patches the valid index buffer to exclude its splats.
    /// Surviving entries are remapped to their new contiguous chunk indices.
    ///
    /// Must be called when no render references are held (i.e., inside withChunkAccess).
    ///
    /// - Parameters:
    ///   - removedChunkIndex: The chunk index being removed
    ///   - indexMapping: Maps old chunk index → new chunk index for all surviving chunks.
    func removeChunkFromSort(removedChunkIndex: UInt16,
                             indexMapping: [UInt16: UInt16]) throws {
        try state.withLock { state in
            state.chunks.removeAll { $0.chunkIndex == removedChunkIndex }
            // Remap surviving chunks' indices to match new contiguous layout
            for i in 0..<state.chunks.count {
                if let newIndex = indexMapping[state.chunks[i].chunkIndex] {
                    state.chunks[i].chunkIndex = newIndex
                }
            }
            state.chunkGeneration &+= 1
            state.needsSort = !state.chunks.isEmpty
            try removeChunkFromValidBuffer(removedChunkIndex: removedChunkIndex,
                                           indexMapping: indexMapping, state: &state)
        }
        ensureSortLoopRunning()
    }

    // MARK: - Index Buffer Patching (requires caller to hold state lock)

    /// Writes sequential (unsorted) indices for the given chunks into a free buffer and marks it valid.
    /// Used as a fallback when no existing valid buffer can be patched.
    ///
    /// Requires: caller holds the state lock.
    private func writeSequentialIndicesToFreeBuffer(for chunks: [ChunkReference],
                                                    state: inout State) throws {
        let totalSplatCount = chunks.reduce(0) { $0 + $1.buffer.count }
        guard totalSplatCount > 0 else { return }

        // Find a free buffer (not being sorted, refcount 0)
        guard let freeIndex = (0..<state.indexBuffers.count).first(where: {
            state.indexBuffers[$0].referenceCount == 0 && state.sortingBufferIndex != $0
        }) else { return }

        let buffer = state.indexBuffers[freeIndex].buffer
        try buffer.ensureCapacity(totalSplatCount)
        buffer.count = totalSplatCount

        var writePos = 0
        for chunk in chunks {
            for splatIndex in 0..<chunk.buffer.count {
                buffer.values[writePos] = ChunkedSplatIndex(
                    chunkIndex: chunk.chunkIndex,
                    splatIndex: UInt32(splatIndex)
                )
                writePos += 1
            }
        }

        state.indexBuffers[freeIndex].isValid = true
        state.mostRecentValidBufferIndex = freeIndex
    }

    /// Extends the current valid index buffer with unsorted entries for a newly-added chunk.
    /// Falls back to writing sequential indices for all chunks if no valid buffer exists.
    ///
    /// Requires: caller holds the state lock.
    private func extendValidBufferWithNewChunk(_ chunk: ChunkReference,
                                               state: inout State) throws {
        guard let validIndex = state.mostRecentValidBufferIndex,
              state.indexBuffers[validIndex].isValid,
              state.sortingBufferIndex != validIndex else {
            try writeSequentialIndicesToFreeBuffer(for: state.chunks, state: &state)
            return
        }

        let buffer = state.indexBuffers[validIndex].buffer
        let existingCount = buffer.count
        let newTotal = existingCount + chunk.buffer.count

        try buffer.ensureCapacity(newTotal)

        for splatIndex in 0..<chunk.buffer.count {
            buffer.values[existingCount + splatIndex] = ChunkedSplatIndex(
                chunkIndex: chunk.chunkIndex,
                splatIndex: UInt32(splatIndex)
            )
        }
        buffer.count = newTotal
    }

    /// Removes entries for a deleted chunk from the valid index buffer and remaps surviving
    /// chunk indices to their new contiguous values. Single pass, O(n).
    /// Falls back to writing sequential indices for remaining chunks if no valid buffer exists.
    ///
    /// Requires: caller holds the state lock.
    private func removeChunkFromValidBuffer(removedChunkIndex: UInt16,
                                            indexMapping: [UInt16: UInt16],
                                            state: inout State) throws {
        guard let validIndex = state.mostRecentValidBufferIndex,
              state.indexBuffers[validIndex].isValid,
              state.sortingBufferIndex != validIndex else {
            if !state.chunks.isEmpty {
                try writeSequentialIndicesToFreeBuffer(for: state.chunks, state: &state)
            }
            return
        }

        let buffer = state.indexBuffers[validIndex].buffer

        var writePos = 0
        for readPos in 0..<buffer.count {
            let entry = buffer.values[readPos]
            if entry.chunkIndex != removedChunkIndex,
               let newIndex = indexMapping[entry.chunkIndex] {
                buffer.values[writePos] = ChunkedSplatIndex(
                    chunkIndex: newIndex,
                    splatIndex: entry.splatIndex
                )
                writePos += 1
            }
        }
        buffer.count = writePos

        if writePos == 0 {
            state.indexBuffers[validIndex].isValid = false
            state.mostRecentValidBufferIndex = nil
        }
    }

    // MARK: - Camera Pose Updates

    /// Updates the camera pose, triggering a new sort if needed.
    func updateCameraPose(position: SIMD3<Float>, forward: SIMD3<Float>) {
        state.withLock { state in
            state.cameraPose = CameraPose(position: position, forward: forward)
            state.needsSort = true
        }
        ensureSortLoopRunning()
    }

    // MARK: - Index Buffer Access (Scoped - Preferred)

    /// Provides scoped access to sorted index buffer. Preferred over explicit obtain/release.
    /// Suspends until a buffer is available. Does nothing if the task is cancelled.
    /// - Parameter body: Closure that receives the sorted index buffer
    func withSortedIndices(_ body: (MetalBuffer<ChunkedSplatIndex>) throws -> Void) async rethrows {
        guard let buffer = await obtainSortedIndices() else { return }
        defer { releaseSortedIndices(buffer) }
        try body(buffer)
    }

    // MARK: - Index Buffer Access (Explicit)

    /// Obtains a reference to the current sorted index buffer.
    /// Suspends until a buffer is available. Returns nil if the task is cancelled.
    /// Caller must call `releaseSortedIndices` when done if a buffer is returned.
    func obtainSortedIndices() async -> MetalBuffer<ChunkedSplatIndex>? {
        while !Task.isCancelled {
            if let buffer = tryObtainSortedIndices() {
                return buffer
            }

            // No valid buffer available, wait and try again
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
        return nil
    }

    /// Attempts to obtain a reference to the current sorted index buffer without waiting.
    /// Returns nil immediately if no valid buffer is available.
    /// Caller must call `releaseSortedIndices` when done if a buffer is returned.
    func tryObtainSortedIndices() -> MetalBuffer<ChunkedSplatIndex>? {
        state.withLock { state -> MetalBuffer<ChunkedSplatIndex>? in
            // Don't provide buffers during exclusive access
            guard !state.hasExclusiveAccess else { return nil }

            // Find a valid buffer
            guard let validIndex = state.mostRecentValidBufferIndex,
                  state.indexBuffers[validIndex].isValid else {
                return nil
            }

            // Never hand out a buffer while a sort pass is writing into it.
            guard state.sortingBufferIndex != validIndex else {
                return nil
            }

            // Increment reference count and return
            state.indexBuffers[validIndex].referenceCount += 1
            return state.indexBuffers[validIndex].buffer
        }
    }

    /// Releases a previously obtained index buffer reference.
    /// - Parameter buffer: The buffer returned from `obtainSortedIndices`
    func releaseSortedIndices(_ buffer: MetalBuffer<ChunkedSplatIndex>) {
        state.withLock { state in
            guard let index = state.indexBuffers.firstIndex(where: { $0.buffer === buffer }) else {
                assertionFailure("Released buffer not found in index buffers")
                return
            }
            assert(state.indexBuffers[index].referenceCount > 0, "Reference count underflow")
            state.indexBuffers[index].referenceCount -= 1
        }
    }

    /// Invalidates all index buffers synchronously.
    /// Use this when chunk contents have been reordered in place.
    /// Any unreleased references become stale - callers should release them promptly.
    func invalidateAllBuffers() {
        state.withLock { state in
            for i in 0..<state.indexBuffers.count {
                state.indexBuffers[i].isValid = false
            }
            state.mostRecentValidBufferIndex = nil
            state.needsSort = true
        }
    }

    // MARK: - Exclusive Access for Chunk Updates

    /// Provides exclusive access to update chunks.
    /// - Parameter invalidateIndexBuffers: If true (default), waits for all buffer references to be
    ///   released and marks all buffers invalid. If false, allows existing references to continue.
    /// - Parameter body: Closure to execute with exclusive access
    func withExclusiveAccess(invalidateIndexBuffers: Bool = true,
                             _ body: () async throws -> Void) async rethrows {
        // 1. Wait until not reading chunks (phase 1 of sort)
        while !Task.isCancelled {
            let canProceed = state.withLock { state -> Bool in
                if state.isReadingChunks {
                    return false
                }
                // Mark exclusive access
                state.hasExclusiveAccess = true
                if invalidateIndexBuffers {
                    state.pendingInvalidation = true
                }
                return true
            }

            if canProceed {
                break
            }

            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }

        defer {
            state.withLock { state in
                state.hasExclusiveAccess = false
                state.pendingInvalidation = false
            }
        }

        // 2. If invalidating, wait for all references to be released
        if invalidateIndexBuffers {
            while !Task.isCancelled {
                let allReleased = state.withLock { state -> Bool in
                    state.indexBuffers.allSatisfy { $0.referenceCount == 0 }
                }

                if allReleased {
                    // Mark all buffers invalid
                    state.withLock { state in
                        for i in 0..<state.indexBuffers.count {
                            state.indexBuffers[i].isValid = false
                        }
                        state.mostRecentValidBufferIndex = nil
                    }
                    break
                }

                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }

        // 3. Execute body
        try await body()

        // 4. Trigger sort if chunks exist
        let shouldTriggerSort = state.withLock { state -> Bool in
            state.needsSort = !state.chunks.isEmpty
            return state.needsSort
        }

        if shouldTriggerSort {
            ensureSortLoopRunning()
        }
    }

    // MARK: - Sort Loop

    private func ensureSortLoopRunning() {
        let shouldStart = state.withLock { state -> Bool in
            if state.sortLoopRunning {
                return false
            }
            state.sortLoopRunning = true
            return true
        }

        if shouldStart {
            Task.detached(priority: .high) { [weak self] in
                await self?.sortLoop()
            }
        }
    }

    private func sortLoop() async {
        defer {
            state.withLock { state in
                state.sortLoopRunning = false
            }
        }

        while !Task.isCancelled {
            // Check if we need to sort
            let sortParams = state.withLock { state -> (chunks: [ChunkReference], pose: CameraPose, bufferIndex: Int, chunkGeneration: UInt64)? in
                // Don't sort during exclusive access
                guard !state.hasExclusiveAccess else { return nil }

                // Check if sort is needed
                guard state.needsSort,
                      !state.chunks.isEmpty else {
                    return nil
                }
                let pose = state.cameraPose

                // Use a free staging buffer with refcount 0 that is not the currently
                // published valid buffer.
                guard let bufferIndex = state.indexBuffers.indices.first(where: { index in
                    guard state.indexBuffers[index].referenceCount == 0 else {
                        return false
                    }
                    if let mostRecent = state.mostRecentValidBufferIndex, index == mostRecent {
                        return false
                    }
                    return true
                }) else {
                    return nil
                }

                // Mark that we're starting a sort
                state.sortingBufferIndex = bufferIndex
                state.isReadingChunks = true
                state.needsSort = false

                return (state.chunks, pose, bufferIndex, state.chunkGeneration)
            }

            guard let params = sortParams else {
                // Nothing to sort or no buffer available, check if we should exit or wait
                let shouldExit = state.withLock { state -> Bool in
                    !state.needsSort && state.chunks.isEmpty
                }

                if shouldExit {
                    return
                }

                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
                continue
            }

            // Perform the sort
            await performSort(
                chunks: params.chunks,
                cameraPose: params.pose,
                targetBufferIndex: params.bufferIndex,
                chunkGeneration: params.chunkGeneration
            )
        }
    }

    private func performSort(
        chunks: [ChunkReference],
        cameraPose: CameraPose,
        targetBufferIndex: Int,
        chunkGeneration: UInt64
    ) async {
        let startTime = Date()
        onSortStart?()

        // Calculate total splat count across all chunks
        let totalSplatCount = chunks.reduce(0) { $0 + $1.buffer.count }
        let targetBuffer = state.withLock { $0.indexBuffers[targetBufferIndex].buffer }

        // Phase 1: Read splat positions from all chunks and compute depths
        // Ensure temp storage is sized correctly
        if sortTempStorage.count != totalSplatCount {
            sortTempStorage = Array(repeating: SplatReferenceAndDepth(chunkIndex: 0, splatIndex: 0, depth: 0), count: totalSplatCount)
        }

        // Compute depth for each splat across all chunks
        var tempIndex = 0
        if SplatRenderer.Constants.sortByDistance {
            for chunk in chunks {
                for i in 0..<chunk.buffer.count {
                    let position = chunk.buffer.values[i].position.simd
                    sortTempStorage[tempIndex].chunkIndex = chunk.chunkIndex
                    sortTempStorage[tempIndex].splatIndex = UInt32(i)
                    sortTempStorage[tempIndex].depth = (position - cameraPose.position).lengthSquared
                    tempIndex += 1
                }
            }
        } else {
            for chunk in chunks {
                for i in 0..<chunk.buffer.count {
                    let position = chunk.buffer.values[i].position.simd
                    sortTempStorage[tempIndex].chunkIndex = chunk.chunkIndex
                    sortTempStorage[tempIndex].splatIndex = UInt32(i)
                    sortTempStorage[tempIndex].depth = dot(position, cameraPose.forward)
                    tempIndex += 1
                }
            }
        }

        // Done reading chunks
        state.withLock { state in
            state.isReadingChunks = false
        }

        // Phase 2: Sort by depth (back to front, so larger depth first)
        sortTempStorage.sort { $0.depth > $1.depth }

        // Phase 3: Write sorted indices to buffer
        do {
            try targetBuffer.ensureCapacity(totalSplatCount)
            targetBuffer.count = totalSplatCount
            for i in 0..<totalSplatCount {
                let ref = sortTempStorage[i]
                targetBuffer.values[i] = ChunkedSplatIndex(
                    chunkIndex: ref.chunkIndex,
                    splatIndex: ref.splatIndex
                )
            }
        } catch {
            // Buffer allocation failed, abort this sort
            state.withLock { state in
                state.sortingBufferIndex = nil
            }
            return
        }

        // Phase 4: Mark buffer as valid (unless invalidation was requested or chunks changed)
        let wasInvalidated = state.withLock { state -> Bool in
            state.sortingBufferIndex = nil

            // If invalidation was requested during sort, or chunks changed since we started,
            // don't mark as valid — a patched buffer may already exist
            if state.pendingInvalidation || state.chunkGeneration != chunkGeneration {
                return true
            }

            state.indexBuffers[targetBufferIndex].isValid = true
            state.mostRecentValidBufferIndex = targetBufferIndex
            return false
        }

        // Notify completion (even if invalidated, the sort work was done)
        if !wasInvalidated {
            let duration = -startTime.timeIntervalSinceNow
            onSortComplete?(duration)
        }
    }
}

// MARK: - Private Extensions

private extension MTLPackedFloat3 {
    var simd: SIMD3<Float> {
        SIMD3(x: x, y: y, z: z)
    }
}

private extension SIMD3 where Scalar == Float {
    var lengthSquared: Float {
        x * x + y * y + z * z
    }
}
