import Metal
import simd

import Synchronization

/**
 SplatSorter creates a sorted list of splat indices. It is given a reference to an array of splats
 (a MetalBuffer<SplatRenderer.Splat>), which may be periodically replaced with a new array using the
 exclusive access mechanism described below. On each frame, a renderer provides the latest camera pose,
 and then obtains a reference to the latest sorted list of splat indices, which may be one or more frames
 out-of-date. After rendering is completed, it explicitly releases this reference. Between obtaining and
 releasing this reference, the buffer is guaranteed not to be modified.

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
 pose or splat array has changed since the last sort began. Each sort iteration:
 1. Updates an internal list with the depth to each splat
 2. Sorts that list by depth
 3. Writes the sorted indices to a buffer, which becomes valid and available for new frames

 When starting a new sort, the sorter selects any buffer with reference count zero. If no such buffer
 exists, the sort awaits until one becomes available.

 If invalidation is requested while a sort is in progress, the resulting buffer is pre-marked as invalid,
 effectively canceling that sort's usefulness without the complexity of actual cancellation.

 ## Exclusive Access for Splat Array Updates

 To safely update the splat array, callers use:

 ```swift
 func withExclusiveAccess(invalidateIndexBuffers: Bool = true, _ body: () async throws -> Void) async rethrows
 ```

 This method:
 1. Awaits until the sorter is not actively reading the splat array (not in phase 1 of a sort)
 2. While the body executes, blocks new sort iterations from starting and new buffer references from
    being obtained (callers await until exclusive access ends)
 3. If `invalidateIndexBuffers` is true (the default): awaits until all buffer references are released,
    then marks all buffers as invalid (preventing references until a new sort completes)
 4. If `invalidateIndexBuffers` is false: allows existing frames to continue using their (now potentially
    stale) buffer references—useful when merely appending new splats where existing indices remain valid

 Example - removing splats (requires invalidation, the default):
 ```swift
 await sorter.withExclusiveAccess {
     splatBuffer = newShorterBuffer
 }
 ```

 Example - appending splats (no invalidation needed):
 ```swift
 await sorter.withExclusiveAccess(invalidateIndexBuffers: false) {
     splatBuffer.append(contentsOf: newSplats)
 }
 ```

 ## Implementation Notes

 Swift Concurrency is used in the API, but primarily to protect class state. Callers rarely wait for sorts
 to complete. A Mutex is used rather than an actor for low-latency coordination—we don't want to risk
 blocking the render thread.
 */
class SplatSorter<SplatIndexType: BinaryInteger & Sendable>: @unchecked Sendable {

    // MARK: - Constants

    private static var bufferCount: Int { 3 }
    private static var pollIntervalNanoseconds: UInt64 { 1_000_000 } // 1ms

    // MARK: - Types

    private struct IndexBuffer {
        let buffer: MetalBuffer<SplatIndexType>
        var referenceCount: Int = 0
        var isValid: Bool = false
    }

    private struct State {
        var indexBuffers: [IndexBuffer]
        var sortingBufferIndex: Int? = nil
        var mostRecentValidBufferIndex: Int? = nil
        var hasExclusiveAccess: Bool = false
        var pendingInvalidation: Bool = false  // If true, in-progress sort result should be marked invalid
        var cameraPose: CameraPose? = nil
        var needsSort: Bool = false
        var splatBuffer: MetalBuffer<SplatRenderer.Splat>? = nil
        var isReadingSplatBuffer: Bool = false  // True during phase 1 of sort (reading splat positions)
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
    private var sortTempStorage: [SplatIndexAndDepth] = []

    private struct SplatIndexAndDepth {
        var index: SplatIndexType
        var depth: Float
    }

    // MARK: - Initialization

    init(device: MTLDevice) throws {
        self.device = device

        var indexBuffers: [IndexBuffer] = []
        for _ in 0..<Self.bufferCount {
            let buffer = try MetalBuffer<SplatIndexType>(device: device)
            indexBuffers.append(IndexBuffer(buffer: buffer))
        }

        self.state = Mutex(State(indexBuffers: indexBuffers))
    }

    // MARK: - Splat Buffer Management

    /// The current splat buffer. Update via `withExclusiveAccess` for thread safety.
    /// Can be read without exclusive access, but writes must use `withExclusiveAccess`.
    var splatBuffer: MetalBuffer<SplatRenderer.Splat>? {
        get { state.withLock { $0.splatBuffer } }
    }

    /// Sets the splat buffer. Must be called within `withExclusiveAccess` for thread safety,
    /// or during initial setup before any sorting begins.
    func setSplatBuffer(_ buffer: MetalBuffer<SplatRenderer.Splat>?) {
        state.withLock { state in
            state.splatBuffer = buffer
            state.needsSort = buffer != nil
        }
        ensureSortLoopRunning()
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
    func withSortedIndices(_ body: (MetalBuffer<SplatIndexType>) throws -> Void) async rethrows {
        guard let buffer = await obtainSortedIndices() else { return }
        defer { releaseSortedIndices(buffer) }
        try body(buffer)
    }

    // MARK: - Index Buffer Access (Explicit)

    /// Obtains a reference to the current sorted index buffer.
    /// Suspends until a buffer is available. Returns nil if the task is cancelled.
    /// Caller must call `releaseSortedIndices` when done if a buffer is returned.
    func obtainSortedIndices() async -> MetalBuffer<SplatIndexType>? {
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
    func tryObtainSortedIndices() -> MetalBuffer<SplatIndexType>? {
        state.withLock { state -> MetalBuffer<SplatIndexType>? in
            // Don't provide buffers during exclusive access
            guard !state.hasExclusiveAccess else { return nil }

            // Find a valid buffer
            guard let validIndex = state.mostRecentValidBufferIndex,
                  state.indexBuffers[validIndex].isValid else {
                return nil
            }

            // Increment reference count and return
            state.indexBuffers[validIndex].referenceCount += 1
            return state.indexBuffers[validIndex].buffer
        }
    }

    /// Releases a previously obtained index buffer reference.
    /// - Parameter buffer: The buffer returned from `obtainSortedIndices`
    func releaseSortedIndices(_ buffer: MetalBuffer<SplatIndexType>) {
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
    /// Use this when the splat buffer contents have been reordered in place.
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

    // MARK: - Exclusive Access for Splat Array Updates

    /// Provides exclusive access to update the splat array.
    /// - Parameter invalidateIndexBuffers: If true (default), waits for all buffer references to be
    ///   released and marks all buffers invalid. If false, allows existing references to continue.
    /// - Parameter body: Closure to execute with exclusive access
    func withExclusiveAccess(invalidateIndexBuffers: Bool = true,
                             _ body: () async throws -> Void) async rethrows {
        // 1. Wait until not reading splat buffer (phase 1 of sort)
        while !Task.isCancelled {
            let canProceed = state.withLock { state -> Bool in
                if state.isReadingSplatBuffer {
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

        // 4. Trigger sort if splat buffer exists
        let shouldTriggerSort = state.withLock { state -> Bool in
            state.needsSort = state.splatBuffer != nil
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
            let sortParams = state.withLock { state -> (splatBuffer: MetalBuffer<SplatRenderer.Splat>, pose: CameraPose, bufferIndex: Int)? in
                // Don't sort during exclusive access
                guard !state.hasExclusiveAccess else { return nil }

                // Check if sort is needed
                guard state.needsSort,
                      let splatBuffer = state.splatBuffer,
                      let pose = state.cameraPose else {
                    return nil
                }

                // Find a buffer with refcount 0
                guard let bufferIndex = state.indexBuffers.firstIndex(where: { $0.referenceCount == 0 }) else {
                    return nil
                }

                // Mark that we're starting a sort
                state.sortingBufferIndex = bufferIndex
                state.isReadingSplatBuffer = true
                state.needsSort = false

                return (splatBuffer, pose, bufferIndex)
            }

            guard let params = sortParams else {
                // Nothing to sort or no buffer available, check if we should exit or wait
                let shouldExit = state.withLock { state -> Bool in
                    !state.needsSort && state.splatBuffer == nil
                }

                if shouldExit {
                    return
                }

                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
                continue
            }

            // Perform the sort
            await performSort(
                splatBuffer: params.splatBuffer,
                cameraPose: params.pose,
                targetBufferIndex: params.bufferIndex
            )
        }
    }

    private func performSort(
        splatBuffer: MetalBuffer<SplatRenderer.Splat>,
        cameraPose: CameraPose,
        targetBufferIndex: Int
    ) async {
        let startTime = Date()
        onSortStart?()

        let splatCount = splatBuffer.count
        let targetBuffer = state.withLock { $0.indexBuffers[targetBufferIndex].buffer }

        // Phase 1: Read splat positions and compute depths
        // Ensure temp storage is sized correctly
        if sortTempStorage.count != splatCount {
            sortTempStorage = Array(repeating: SplatIndexAndDepth(index: 0, depth: 0), count: splatCount)
        }

        // Compute depth for each splat
        if SplatRenderer.Constants.sortByDistance {
            for i in 0..<splatCount {
                let splatPosition = splatBuffer.values[i].position.simd
                sortTempStorage[i].index = SplatIndexType(i)
                sortTempStorage[i].depth = (splatPosition - cameraPose.position).lengthSquared
            }
        } else {
            for i in 0..<splatCount {
                let splatPosition = splatBuffer.values[i].position.simd
                sortTempStorage[i].index = SplatIndexType(i)
                sortTempStorage[i].depth = dot(splatPosition, cameraPose.forward)
            }
        }

        // Done reading splat buffer
        state.withLock { state in
            state.isReadingSplatBuffer = false
        }

        // Phase 2: Sort by depth (back to front, so larger depth first)
        sortTempStorage.sort { $0.depth > $1.depth }

        // Phase 3: Write sorted indices to buffer
        do {
            try targetBuffer.ensureCapacity(splatCount)
            targetBuffer.count = splatCount
            for i in 0..<splatCount {
                targetBuffer.values[i] = sortTempStorage[i].index
            }
        } catch {
            // Buffer allocation failed, abort this sort
            state.withLock { state in
                state.sortingBufferIndex = nil
            }
            return
        }

        // Phase 4: Mark buffer as valid (unless invalidation was requested)
        let wasInvalidated = state.withLock { state -> Bool in
            state.sortingBufferIndex = nil

            // If invalidation was requested during sort, don't mark as valid
            if state.pendingInvalidation {
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
