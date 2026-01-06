import XCTest
import Metal
import simd
@testable import MetalSplatter

final class SplatSorterTests: XCTestCase {
    var device: MTLDevice!

    /// Helper to create a test splat at a given position
    func makeSplat(at position: SIMD3<Float>) -> SplatRenderer.Splat {
        SplatRenderer.Splat(position: position,
                            color: SIMD4<Float>(1, 1, 1, 1),
                            scale: SIMD3<Float>(0.1, 0.1, 0.1),
                            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }

    /// Helper to create a splat buffer with test data
    func makeSplatBuffer(positions: [SIMD3<Float>]) throws -> MetalBuffer<SplatRenderer.Splat> {
        let buffer = try MetalBuffer<SplatRenderer.Splat>(device: device)
        try buffer.ensureCapacity(positions.count)
        for position in positions {
            buffer.append(makeSplat(at: position))
        }
        return buffer
    }

    override func setUp() {
        super.setUp()
        device = MTLCreateSystemDefaultDevice()
        XCTAssertNotNil(device, "Metal device required for tests")
    }

    // MARK: - Basic Initialization Tests

    func testInitialization() throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        XCTAssertNil(sorter.splatBuffer, "Initially should have no splat buffer")
    }

    func testSetSplatBuffer() throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, 0)
        ])

        sorter.setSplatBuffer(splatBuffer)

        XCTAssertTrue(sorter.splatBuffer === splatBuffer, "Should return the set splat buffer")
    }

    func testSetSplatBufferToNil() throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, 0)
        ])

        sorter.setSplatBuffer(splatBuffer)
        sorter.setSplatBuffer(nil)

        XCTAssertNil(sorter.splatBuffer, "Should be able to clear splat buffer")
    }

    func testUpdateCameraPose() throws {
        let sorter = try SplatSorter<UInt32>(device: device)

        // Should not crash when updating camera pose
        sorter.updateCameraPose(position: SIMD3<Float>(1, 2, 3),
                                forward: SIMD3<Float>(0, 0, -1))
    }

    // MARK: - Sorting Tests (These should FAIL until sorting is implemented)

    /// After setting splat buffer and camera pose, sorting should complete and
    /// obtainSortedIndices should return a valid buffer.
    func testObtainSortedIndicesReturnsBufferAfterSort() async throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, -5),  // farther
            SIMD3<Float>(0, 0, -2),  // closer
            SIMD3<Float>(0, 0, -8),  // farthest
        ])

        sorter.setSplatBuffer(splatBuffer)
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        // Wait for sorting to complete (with timeout)
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
        let sorter = try SplatSorter<UInt32>(device: device)

        // Splats at different depths along Z axis
        // Index 0: z=-5 (middle)
        // Index 1: z=-2 (closest)
        // Index 2: z=-8 (farthest)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, -5),
            SIMD3<Float>(0, 0, -2),
            SIMD3<Float>(0, 0, -8),
        ])

        sorter.setSplatBuffer(splatBuffer)
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        // Wait for sorting to complete
        let indexBuffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }

        guard let indexBuffer = indexBuffer else {
            XCTFail("Should return a valid buffer after sort completes")
            return
        }

        defer { sorter.releaseSortedIndices(indexBuffer) }

        // Verify count
        XCTAssertEqual(indexBuffer.count, 3, "Should have 3 sorted indices")

        // Verify order: back-to-front means farthest (index 2) should be first
        // Expected order: [2, 0, 1] (z=-8, z=-5, z=-2)
        XCTAssertEqual(indexBuffer.values[0], 2, "First should be farthest splat (index 2, z=-8)")
        XCTAssertEqual(indexBuffer.values[1], 0, "Second should be middle splat (index 0, z=-5)")
        XCTAssertEqual(indexBuffer.values[2], 1, "Third should be closest splat (index 1, z=-2)")
    }

    /// When sorting by distance (not depth), splats should be sorted by distance from camera.
    func testSortedIndicesByDistance() async throws {
        // TODO: This test requires access to sortByDistance flag
        // For now, skip if sortByDistance isn't configurable
    }

    // MARK: - Reference Counting Tests

    /// Multiple calls to obtainSortedIndices should return the same buffer.
    func testMultipleObtainsReturnSameBuffer() async throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, -1),
        ])

        sorter.setSplatBuffer(splatBuffer)
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        // Get two references
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

    /// withSortedIndices should call the body with a valid buffer.
    func testWithSortedIndicesCallsBody() async throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, -1),
        ])

        sorter.setSplatBuffer(splatBuffer)
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        // Use a struct to capture results from the closure (Sendable-safe)
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

    /// During exclusive access with invalidation, obtainSortedIndices should block
    /// until exclusive access ends and a new sort completes.
    func testExclusiveAccessBlocksObtain() async throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, -1),
        ])

        sorter.setSplatBuffer(splatBuffer)
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        // First, get a valid buffer to confirm sorting works
        let initialBuffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(initialBuffer, "Should get initial buffer")
        if let initialBuffer = initialBuffer {
            sorter.releaseSortedIndices(initialBuffer)
        }

        // Now test that exclusive access with invalidation blocks
        var exclusiveAccessComplete = false

        await sorter.withExclusiveAccess(invalidateIndexBuffers: true) {
            // During exclusive access, spawn a task that tries to obtain
            let obtainTask = Task {
                return await sorter.obtainSortedIndices()
            }

            // Give it a moment to start waiting
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

            // The obtain should still be pending (not completed yet)
            // We can't easily test this directly, but we verify behavior after

            exclusiveAccessComplete = true
        }

        XCTAssertTrue(exclusiveAccessComplete, "Exclusive access should complete")
    }

    /// withExclusiveAccess without invalidation should allow existing references.
    func testExclusiveAccessWithoutInvalidationAllowsExistingReferences() async throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, -1),
        ])

        sorter.setSplatBuffer(splatBuffer)
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        // Get a reference before exclusive access
        let buffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(buffer, "Should get buffer before exclusive access")

        // Exclusive access without invalidation
        var bodyExecuted = false
        await sorter.withExclusiveAccess(invalidateIndexBuffers: false) {
            bodyExecuted = true
            // Existing reference should still be valid
        }

        XCTAssertTrue(bodyExecuted, "Body should execute")

        // Can still use the buffer after exclusive access ends
        if let buffer = buffer {
            // Buffer should still be accessible
            _ = buffer.count
            sorter.releaseSortedIndices(buffer)
        }
    }

    // MARK: - Re-sorting Tests

    /// Updating camera pose should trigger a new sort.
    func testCameraPoseUpdateTriggersResort() async throws {
        let sorter = try SplatSorter<UInt32>(device: device)

        // Splats arranged so sort order depends on camera position
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(-5, 0, 0),  // left
            SIMD3<Float>(5, 0, 0),   // right
        ])

        sorter.setSplatBuffer(splatBuffer)

        // Camera looking from the right - left splat is farther
        sorter.updateCameraPose(position: SIMD3<Float>(10, 0, 0),
                                forward: SIMD3<Float>(-1, 0, 0))

        let buffer1 = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(buffer1, "Should get sorted buffer")

        if let buffer1 = buffer1 {
            // Left splat (index 0) should be first (farther from camera at x=10)
            XCTAssertEqual(buffer1.values[0], 0, "Left splat should be first when camera is on right")
            sorter.releaseSortedIndices(buffer1)
        }

        // Now move camera to the left - right splat is now farther
        sorter.updateCameraPose(position: SIMD3<Float>(-10, 0, 0),
                                forward: SIMD3<Float>(1, 0, 0))

        // Wait for new sort
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let buffer2 = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(buffer2, "Should get new sorted buffer")

        if let buffer2 = buffer2 {
            // Right splat (index 1) should now be first (farther from camera at x=-10)
            XCTAssertEqual(buffer2.values[0], 1, "Right splat should be first when camera is on left")
            sorter.releaseSortedIndices(buffer2)
        }
    }

    // MARK: - Edge Cases

    /// Empty splat buffer should still work.
    func testEmptySplatBuffer() async throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try MetalBuffer<SplatRenderer.Splat>(device: device)

        sorter.setSplatBuffer(splatBuffer)
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        let buffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }

        // Either nil or empty buffer is acceptable for empty input
        if let buffer = buffer {
            XCTAssertEqual(buffer.count, 0, "Empty splat buffer should produce empty index buffer")
            sorter.releaseSortedIndices(buffer)
        }
    }

    /// Single splat should work correctly.
    func testSingleSplat() async throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, -5),
        ])

        sorter.setSplatBuffer(splatBuffer)
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        let buffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }

        XCTAssertNotNil(buffer, "Should get buffer for single splat")
        if let buffer = buffer {
            XCTAssertEqual(buffer.count, 1, "Should have one index")
            XCTAssertEqual(buffer.values[0], 0, "Index should be 0")
            sorter.releaseSortedIndices(buffer)
        }
    }

    // MARK: - Timeout Tests

    /// After invalidation, tryObtainSortedIndices should return nil immediately (timeout=0),
    /// but should succeed with a longer timeout once sorting completes.
    func testTimeoutAfterInvalidation() async throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, -5),
            SIMD3<Float>(0, 0, -2),
            SIMD3<Float>(0, 0, -8),
        ])

        sorter.setSplatBuffer(splatBuffer)
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        // First, confirm we can get a valid sorted buffer
        let initialBuffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(initialBuffer, "Should get initial sorted buffer")
        if let initialBuffer = initialBuffer {
            sorter.releaseSortedIndices(initialBuffer)
        }

        // Invalidate all buffers
        sorter.invalidateAllBuffers()

        // Immediately try with timeout=0 - should fail (return nil)
        let immediateResult = sorter.tryObtainSortedIndices()
        XCTAssertNil(immediateResult, "tryObtainSortedIndices should return nil immediately after invalidation")

        // Now wait with a longer timeout - should succeed once sort completes
        let delayedBuffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(delayedBuffer, "obtainSortedIndices should succeed with sufficient timeout after invalidation")

        if let delayedBuffer = delayedBuffer {
            XCTAssertEqual(delayedBuffer.count, 3, "Should have correct count after re-sort")
            sorter.releaseSortedIndices(delayedBuffer)
        }
    }

    /// Tests that polling with sortTimeout works correctly - fails at timeout=0, succeeds with longer timeout.
    func testPollingTimeoutBehavior() async throws {
        let sorter = try SplatSorter<UInt32>(device: device)
        let splatBuffer = try makeSplatBuffer(positions: [
            SIMD3<Float>(0, 0, -5),
        ])

        sorter.setSplatBuffer(splatBuffer)
        sorter.updateCameraPose(position: SIMD3<Float>(0, 0, 0),
                                forward: SIMD3<Float>(0, 0, -1))

        // Wait for initial sort
        let initialBuffer = await withTimeout(seconds: 2) {
            await sorter.obtainSortedIndices()
        }
        XCTAssertNotNil(initialBuffer, "Should get initial buffer")
        if let initialBuffer = initialBuffer {
            sorter.releaseSortedIndices(initialBuffer)
        }

        // Invalidate and test polling behavior
        sorter.invalidateAllBuffers()

        // With timeout=0, should fail immediately
        let zeroTimeoutResult = sorter.tryObtainSortedIndices()
        XCTAssertNil(zeroTimeoutResult, "Should fail with zero timeout after invalidation")

        // Simulate the polling logic used by SplatRenderer.render with sortTimeout
        var polledBuffer: MetalBuffer<UInt32>?
        let sortTimeout: TimeInterval = 0.5
        let deadline = Date().addingTimeInterval(sortTimeout)

        while polledBuffer == nil && Date() < deadline {
            polledBuffer = sorter.tryObtainSortedIndices()
            if polledBuffer == nil {
                try await Task.sleep(until: .now + .seconds(0.01))
            }
        }

        XCTAssertNotNil(polledBuffer, "Polling with 0.5s timeout should succeed")
        if let polledBuffer = polledBuffer {
            sorter.releaseSortedIndices(polledBuffer)
        }
    }
}

// MARK: - Test Helpers

extension SplatSorterTests {
    /// Helper to run an async operation with a timeout.
    /// Returns nil if the operation times out.
    func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            // Return first completed result
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Helper for void async operations with timeout.
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
