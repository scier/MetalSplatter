import XCTest
import Metal
import simd
@testable import MetalSplatter

final class ChunkTests: XCTestCase {
    var device: MTLDevice!

    override func setUp() {
        super.setUp()
        device = MTLCreateSystemDefaultDevice()
        XCTAssertNotNil(device, "Metal device required for tests")
    }

    // MARK: - ChunkID Tests

    func testChunkIDEquality() {
        let id1 = ChunkID(rawValue: 1)
        let id2 = ChunkID(rawValue: 1)
        let id3 = ChunkID(rawValue: 2)

        XCTAssertEqual(id1, id2)
        XCTAssertNotEqual(id1, id3)
    }

    func testChunkIDHashable() {
        let id1 = ChunkID(rawValue: 1)
        let id2 = ChunkID(rawValue: 2)

        var dict = [ChunkID: String]()
        dict[id1] = "chunk1"
        dict[id2] = "chunk2"

        XCTAssertEqual(dict[id1], "chunk1")
        XCTAssertEqual(dict[id2], "chunk2")
    }

    // MARK: - SplatChunk Tests

    func testSplatChunkCreation() throws {
        let buffer = try MetalBuffer<EncodedSplat>(device: device)
        let chunk = SplatChunk(splats: buffer)

        XCTAssertEqual(chunk.splatCount, 0)
    }

    func testSplatChunkSplatCount() throws {
        let buffer = try MetalBuffer<EncodedSplat>(device: device)
        try buffer.ensureCapacity(5)
        for i in 0..<5 {
            buffer.append(makeSplat(at: SIMD3<Float>(Float(i), 0, 0)))
        }

        let chunk = SplatChunk(splats: buffer)

        XCTAssertEqual(chunk.splatCount, 5)
    }

    // MARK: - ChunkedSplatIndex Tests

    func testChunkedSplatIndexCreation() {
        let index = ChunkedSplatIndex(chunkIndex: 5, splatIndex: 1000)

        XCTAssertEqual(index.chunkIndex, 5)
        XCTAssertEqual(index.splatIndex, 1000)
        XCTAssertEqual(index._padding, 0)
    }

    func testChunkedSplatIndexMaxValues() {
        let index = ChunkedSplatIndex(chunkIndex: UInt16.max, splatIndex: UInt32.max)

        XCTAssertEqual(index.chunkIndex, UInt16.max)
        XCTAssertEqual(index.splatIndex, UInt32.max)
    }

    // MARK: - Helper Functions

    func makeSplat(at position: SIMD3<Float>) -> EncodedSplat {
        EncodedSplat(position: position,
                            color: SIMD4<Float>(1, 1, 1, 1),
                            scale: SIMD3<Float>(0.1, 0.1, 0.1),
                            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }
}

// MARK: - SplatRenderer Chunk Management Tests

final class SplatRendererChunkTests: XCTestCase {
    var device: MTLDevice!

    override func setUp() {
        super.setUp()
        device = MTLCreateSystemDefaultDevice()
        XCTAssertNotNil(device, "Metal device required for tests")
    }

    func makeRenderer() throws -> SplatRenderer {
        try SplatRenderer(
            device: device,
            colorFormat: .bgra8Unorm,
            depthFormat: .depth32Float,
            sampleCount: 1,
            maxViewCount: 1,
            maxSimultaneousRenders: 3
        )
    }

    func makeChunk(splatCount: Int) throws -> SplatChunk {
        let buffer = try MetalBuffer<EncodedSplat>(device: device)
        try buffer.ensureCapacity(splatCount)
        for i in 0..<splatCount {
            buffer.append(makeSplat(at: SIMD3<Float>(Float(i), 0, 0)))
        }
        return SplatChunk(splats: buffer)
    }

    func makeSplat(at position: SIMD3<Float>) -> EncodedSplat {
        EncodedSplat(position: position,
                            color: SIMD4<Float>(1, 1, 1, 1),
                            scale: SIMD3<Float>(0.1, 0.1, 0.1),
                            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }

    // MARK: - Basic Chunk Management Tests

    func testAddChunk() async throws {
        let renderer = try makeRenderer()
        let chunk = try makeChunk(splatCount: 10)

        let id = await renderer.addChunk(chunk)

        XCTAssertEqual(id.rawValue, 0, "First chunk should have ID 0")
        XCTAssertEqual(renderer.splatCount, 10)
    }

    func testAddMultipleChunks() async throws {
        let renderer = try makeRenderer()
        let chunk1 = try makeChunk(splatCount: 10)
        let chunk2 = try makeChunk(splatCount: 20)

        let id1 = await renderer.addChunk(chunk1)
        let id2 = await renderer.addChunk(chunk2)

        XCTAssertEqual(id1.rawValue, 0)
        XCTAssertEqual(id2.rawValue, 1)
        XCTAssertEqual(renderer.splatCount, 30)
    }

    func testRemoveChunk() async throws {
        let renderer = try makeRenderer()
        let chunk = try makeChunk(splatCount: 10)

        let id = await renderer.addChunk(chunk)
        XCTAssertEqual(renderer.splatCount, 10)

        await renderer.removeChunk(id)
        XCTAssertEqual(renderer.splatCount, 0)
    }

    func testRemoveAllChunks() async throws {
        let renderer = try makeRenderer()

        _ = await renderer.addChunk(try makeChunk(splatCount: 10))
        _ = await renderer.addChunk(try makeChunk(splatCount: 20))
        XCTAssertEqual(renderer.splatCount, 30)

        await renderer.removeAllChunks()
        XCTAssertEqual(renderer.splatCount, 0)
    }

    // MARK: - Enable/Disable Tests

    func testSetChunkEnabled() async throws {
        let renderer = try makeRenderer()
        let chunk = try makeChunk(splatCount: 10)

        let id = await renderer.addChunk(chunk)
        XCTAssertTrue(renderer.isChunkEnabled(id))
        XCTAssertEqual(renderer.splatCount, 10)

        await renderer.setChunkEnabled(id, enabled: false)
        XCTAssertFalse(renderer.isChunkEnabled(id))
        XCTAssertEqual(renderer.splatCount, 0, "Disabled chunks should not count toward splatCount")

        await renderer.setChunkEnabled(id, enabled: true)
        XCTAssertTrue(renderer.isChunkEnabled(id))
        XCTAssertEqual(renderer.splatCount, 10)
    }

    func testDisabledChunkNotCounted() async throws {
        let renderer = try makeRenderer()
        let chunk1 = try makeChunk(splatCount: 10)
        let chunk2 = try makeChunk(splatCount: 20)

        let id1 = await renderer.addChunk(chunk1)
        _ = await renderer.addChunk(chunk2)
        XCTAssertEqual(renderer.splatCount, 30)

        await renderer.setChunkEnabled(id1, enabled: false)
        XCTAssertEqual(renderer.splatCount, 20, "Only enabled chunk should count")
    }

    // MARK: - Edge Cases

    func testIsChunkEnabledForNonexistentChunk() throws {
        let renderer = try makeRenderer()
        let fakeID = ChunkID(rawValue: 999)

        XCTAssertFalse(renderer.isChunkEnabled(fakeID))
    }

    func testRemoveNonexistentChunk() async throws {
        let renderer = try makeRenderer()
        let fakeID = ChunkID(rawValue: 999)

        // Should not crash
        await renderer.removeChunk(fakeID)
    }
}
