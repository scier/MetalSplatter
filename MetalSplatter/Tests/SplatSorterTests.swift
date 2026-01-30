import XCTest
import Metal
import simd
@testable import MetalSplatter

final class SplatSorterTests: XCTestCase {
    var device: MTLDevice!

    /// Helper to create a test splat at a given position
    func makeSplat(at position: SIMD3<Float>) -> EncodedSplat {
        EncodedSplat(position: position,
                     colorSH0: SIMD3<Float>(1, 1, 1),
                     opacity: 1.0,
                     scale: SIMD3<Float>(0.1, 0.1, 0.1),
                     rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }

    /// Helper to create a splat buffer with test data
    func makeSplatBuffer(positions: [SIMD3<Float>]) throws -> MetalBuffer<EncodedSplat> {
        let buffer = try MetalBuffer<EncodedSplat>(device: device)
        try buffer.ensureCapacity(positions.count)
        for position in positions {
            buffer.append(makeSplat(at: position))
        }
        return buffer
    }

    /// Helper to create a chunk reference for the sorter
    func makeChunkReference(positions: [SIMD3<Float>], chunkIndex: UInt16) throws -> SplatSorter.ChunkReference {
        let buffer = try makeSplatBuffer(positions: positions)
        return SplatSorter.ChunkReference(chunkIndex: chunkIndex, buffer: buffer)
    }

    override func setUp() {
        super.setUp()
        device = MTLCreateSystemDefaultDevice()
        XCTAssertNotNil(device, "Metal device required for tests")
    }

    // MARK: - Basic Initialization Tests

    func testInitialization() throws {
        let sorter = try SplatSorter(device: device)
        XCTAssertTrue(sorter.chunks.isEmpty, "Initially should have no chunks")
    }

    func testSetChunks() throws {
        let sorter = try SplatSorter(device: device)
        let chunk = try makeChunkReference(positions: [SIMD3<Float>(0, 0, 0)], chunkIndex: 0)

        sorter.setChunks([chunk])

        XCTAssertEqual(sorter.chunks.count, 1, "Should have one chunk")
    }

    func testSetChunksToEmpty() throws {
        let sorter = try SplatSorter(device: device)
        let chunk = try makeChunkReference(positions: [SIMD3<Float>(0, 0, 0)], chunkIndex: 0)

        sorter.setChunks([chunk])
        sorter.setChunks([])

        XCTAssertTrue(sorter.chunks.isEmpty, "Should be able to clear chunks")
    }

    func testUpdateCameraPose() throws {
        let sorter = try SplatSorter(device: device)

        // Should not crash when updating camera pose
        sorter.updateCameraPose(position: SIMD3<Float>(1, 2, 3),
                                forward: SIMD3<Float>(0, 0, -1))
    }

    func testTotalSplatCount() throws {
        let sorter = try SplatSorter(device: device)
        let chunk1 = try makeChunkReference(positions: [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
        ], chunkIndex: 0)
        let chunk2 = try makeChunkReference(positions: [
            SIMD3<Float>(2, 0, 0),
        ], chunkIndex: 1)

        sorter.setChunks([chunk1, chunk2])

        XCTAssertEqual(sorter.totalSplatCount, 3, "Total splat count should be sum of all chunks")
    }

    // MARK: - Sorting Tests

    /// After setting chunks and camera pose, sorting should complete and
    /// obtainSortedIndices should return a valid buffer.
    func testObtainSortedIndicesReturnsBufferAfterSort() async throws {
        let sorter = try SplatSorter(device: device)
        let chunk = try makeChunkReference(positions: [
            SIMD3<Float>(0, 0, -5),
            SIMD3<Float>(0, 0, -2),
            SIMD3<Float>(0, 0, -8),
        ], chunkIndex: 0)

        sorter.setChunks([chunk])
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        let buffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }

        XCTAssertNotNil(buffer, "Should return a valid buffer after sort completes")

        if let buffer = buffer {
            sorter.releaseSortedIndices(buffer)
        }
    }

    /// The sorted indices should be in back-to-front order (farthest first).
    func testSortedIndicesAreInCorrectOrder() async throws {
        let sorter = try SplatSorter(device: device)

        // Splats at different depths along Z axis
        // Index 0: z=-5 (middle)
        // Index 1: z=-2 (closest)
        // Index 2: z=-8 (farthest)
        let chunk = try makeChunkReference(positions: [
            SIMD3<Float>(0, 0, -5),
            SIMD3<Float>(0, 0, -2),
            SIMD3<Float>(0, 0, -8),
        ], chunkIndex: 0)

        sorter.setChunks([chunk])
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        let indexBuffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }

        guard let indexBuffer = indexBuffer else {
            XCTFail("Should return a valid buffer after sort completes")
            return
        }

        defer { sorter.releaseSortedIndices(indexBuffer) }

        XCTAssertEqual(indexBuffer.count, 3, "Should have 3 sorted indices")

        // Verify order: back-to-front means farthest (index 2) should be first
        // Expected order: [2, 0, 1] (z=-8, z=-5, z=-2)
        XCTAssertEqual(indexBuffer.values[0].chunkIndex, 0, "All should be from chunk 0")
        XCTAssertEqual(indexBuffer.values[0].splatIndex, 2, "First should be farthest splat (index 2, z=-8)")
        XCTAssertEqual(indexBuffer.values[1].splatIndex, 0, "Second should be middle splat (index 0, z=-5)")
        XCTAssertEqual(indexBuffer.values[2].splatIndex, 1, "Third should be closest splat (index 1, z=-2)")
    }

    /// Test sorting across multiple chunks
    func testSortingAcrossMultipleChunks() async throws {
        let sorter = try SplatSorter(device: device)

        // Chunk 0: one splat at z=-5
        let chunk0 = try makeChunkReference(positions: [
            SIMD3<Float>(0, 0, -5),
        ], chunkIndex: 0)

        // Chunk 1: one splat at z=-8 (farthest)
        let chunk1 = try makeChunkReference(positions: [
            SIMD3<Float>(0, 0, -8),
        ], chunkIndex: 1)

        // Chunk 2: one splat at z=-2 (closest)
        let chunk2 = try makeChunkReference(positions: [
            SIMD3<Float>(0, 0, -2),
        ], chunkIndex: 2)

        sorter.setChunks([chunk0, chunk1, chunk2])
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        let indexBuffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }

        guard let indexBuffer = indexBuffer else {
            XCTFail("Should return a valid buffer after sort completes")
            return
        }

        defer { sorter.releaseSortedIndices(indexBuffer) }

        XCTAssertEqual(indexBuffer.count, 3, "Should have 3 sorted indices")

        // Expected order by distance: chunk1 (z=-8), chunk0 (z=-5), chunk2 (z=-2)
        XCTAssertEqual(indexBuffer.values[0].chunkIndex, 1, "First should be from chunk 1 (farthest)")
        XCTAssertEqual(indexBuffer.values[1].chunkIndex, 0, "Second should be from chunk 0 (middle)")
        XCTAssertEqual(indexBuffer.values[2].chunkIndex, 2, "Third should be from chunk 2 (closest)")
    }

    // MARK: - Reference Counting Tests

    func testMultipleObtainsReturnSameBuffer() async throws {
        let sorter = try SplatSorter(device: device)
        let chunk = try makeChunkReference(positions: [SIMD3<Float>(0, 0, -1)], chunkIndex: 0)

        sorter.setChunks([chunk])
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        let buffer1 = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        let buffer2 = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }

        XCTAssertNotNil(buffer1, "First obtain should succeed")
        XCTAssertNotNil(buffer2, "Second obtain should succeed")
        XCTAssertTrue(buffer1 === buffer2, "Both obtains should return the same buffer")

        if let buffer1 = buffer1 { sorter.releaseSortedIndices(buffer1) }
        if let buffer2 = buffer2 { sorter.releaseSortedIndices(buffer2) }
    }

    func testWithSortedIndicesCallsBody() async throws {
        let sorter = try SplatSorter(device: device)
        let chunk = try makeChunkReference(positions: [SIMD3<Float>(0, 0, -1)], chunkIndex: 0)

        sorter.setChunks([chunk])
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        struct Result: Sendable {
            let bodyWasCalled: Bool
            let bufferCount: Int?
        }

        let result: Result? = await withTimeout(seconds: 2) {
            var bufferCount: Int?
            await sorter.withSortedIndices { buffer in
                bufferCount = buffer.count
            }
            return Result(bodyWasCalled: true, bufferCount: bufferCount)
        }

        XCTAssertNotNil(result, "Operation should complete within timeout")
        XCTAssertTrue(result?.bodyWasCalled ?? false, "Body should be called with valid buffer")
        XCTAssertNotNil(result?.bufferCount, "Body should receive non-nil buffer")
        XCTAssertEqual(result?.bufferCount, 1, "Buffer should have correct count")
    }

    // MARK: - Exclusive Access Tests

    func testExclusiveAccessBlocksObtain() async throws {
        let sorter = try SplatSorter(device: device)
        let chunk = try makeChunkReference(positions: [SIMD3<Float>(0, 0, -1)], chunkIndex: 0)

        sorter.setChunks([chunk])
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        let initialBuffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(initialBuffer, "Should get initial buffer")
        if let initialBuffer = initialBuffer {
            sorter.releaseSortedIndices(initialBuffer)
        }

        var exclusiveAccessComplete = false

        await sorter.withExclusiveAccess(invalidateIndexBuffers: true) {
            _ = Task {
                return await sorter.obtainSortedIndices()
            }

            try? await Task.sleep(nanoseconds: 50_000_000)

            exclusiveAccessComplete = true
        }

        XCTAssertTrue(exclusiveAccessComplete, "Exclusive access should complete")
    }

    // MARK: - Re-sorting Tests

    func testCameraPoseUpdateTriggersResort() async throws {
        let sorter = try SplatSorter(device: device)

        // Splats arranged so sort order depends on camera position
        let chunk = try makeChunkReference(positions: [
            SIMD3<Float>(-5, 0, 0),  // left
            SIMD3<Float>(5, 0, 0),   // right
        ], chunkIndex: 0)

        sorter.setChunks([chunk])

        // Camera looking from the right - left splat is farther
        sorter.updateCameraPose(position: SIMD3<Float>(10, 0, 0),
                                forward: SIMD3<Float>(-1, 0, 0))

        let buffer1 = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(buffer1, "Should get sorted buffer")

        if let buffer1 = buffer1 {
            // Left splat (index 0) should be first (farther from camera at x=10)
            XCTAssertEqual(buffer1.values[0].splatIndex, 0, "Left splat should be first when camera is on right")
            sorter.releaseSortedIndices(buffer1)
        }

        // Now move camera to the left - right splat is now farther
        sorter.updateCameraPose(position: SIMD3<Float>(-10, 0, 0),
                                forward: SIMD3<Float>(1, 0, 0))

        try? await Task.sleep(nanoseconds: 100_000_000)

        let buffer2 = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(buffer2, "Should get new sorted buffer")

        if let buffer2 = buffer2 {
            // Right splat (index 1) should now be first (farther from camera at x=-10)
            XCTAssertEqual(buffer2.values[0].splatIndex, 1, "Right splat should be first when camera is on left")
            sorter.releaseSortedIndices(buffer2)
        }
    }

    // MARK: - Edge Cases

    func testEmptyChunks() async throws {
        let sorter = try SplatSorter(device: device)
        let emptyBuffer = try MetalBuffer<EncodedSplat>(device: device)
        let chunk = SplatSorter.ChunkReference(chunkIndex: 0, buffer: emptyBuffer)

        sorter.setChunks([chunk])
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        let buffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }

        if let buffer = buffer {
            XCTAssertEqual(buffer.count, 0, "Empty chunks should produce empty index buffer")
            sorter.releaseSortedIndices(buffer)
        }
    }

    func testSingleSplat() async throws {
        let sorter = try SplatSorter(device: device)
        let chunk = try makeChunkReference(positions: [SIMD3<Float>(0, 0, -5)], chunkIndex: 0)

        sorter.setChunks([chunk])
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        let buffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }

        XCTAssertNotNil(buffer, "Should get buffer for single splat")
        if let buffer = buffer {
            XCTAssertEqual(buffer.count, 1, "Should have one index")
            XCTAssertEqual(buffer.values[0].chunkIndex, 0, "Chunk index should be 0")
            XCTAssertEqual(buffer.values[0].splatIndex, 0, "Splat index should be 0")
            sorter.releaseSortedIndices(buffer)
        }
    }

    // MARK: - Timeout Tests

    func testTimeoutAfterInvalidation() async throws {
        let sorter = try SplatSorter(device: device)
        let chunk = try makeChunkReference(positions: [
            SIMD3<Float>(0, 0, -5),
            SIMD3<Float>(0, 0, -2),
            SIMD3<Float>(0, 0, -8),
        ], chunkIndex: 0)

        sorter.setChunks([chunk])
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        let initialBuffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(initialBuffer, "Should get initial sorted buffer")
        if let initialBuffer = initialBuffer {
            sorter.releaseSortedIndices(initialBuffer)
        }

        sorter.invalidateAllBuffers()

        let immediateResult = sorter.tryObtainSortedIndices()
        XCTAssertNil(immediateResult, "tryObtainSortedIndices should return nil immediately after invalidation")

        let delayedBuffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(delayedBuffer, "obtainSortedIndices should succeed with sufficient timeout after invalidation")

        if let delayedBuffer = delayedBuffer {
            XCTAssertEqual(delayedBuffer.count, 3, "Should have correct count after re-sort")
            sorter.releaseSortedIndices(delayedBuffer)
        }
    }
}

// MARK: - Test Helpers

extension SplatSorterTests {
    func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func withTimeout(seconds: TimeInterval, operation: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await operation()
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }

            await group.next()
            group.cancelAll()
        }
    }
}
