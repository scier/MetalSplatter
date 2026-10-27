import XCTest
import Metal
import simd
@testable import MetalSplatter

/// Checks that `RenderStageCounterSampling` makes the splat render pass write two GPU timestamps into the
/// caller's counter sample buffer: start of the vertex stage and end of the fragment stage. Both render paths
/// are covered, the single-stage one and the multi-stage tile pipeline used on Apple silicon and visionOS.
final class RenderStageCounterSamplingTests: XCTestCase {
    private static let textureSize = 128

    func testTimestampsSingleStage() async throws {
        try await assertRenderWritesTimestamps(highQualityDepth: false)
    }

    func testTimestampsMultiStage() async throws {
        try await assertRenderWritesTimestamps(highQualityDepth: true)
    }

    func testNoSamplingByDefault() async throws {
        let device = try makeDevice()
        let commandQueue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try makeRenderer(device: device, highQualityDepth: true)
        await renderer.addChunk(try makeChunk(device: device))
        let colorTexture = try makeTexture(device: device, format: .rgba8Unorm, usage: [.renderTarget, .shaderRead], storage: .shared)
        let depthTexture = try makeTexture(device: device, format: .depth32Float, usage: [.renderTarget], storage: .private)

        // without counterSampling the call is the same as before, and still renders
        let rendered = try renderWithRetry(renderer, commandQueue: commandQueue,
                                           colorTexture: colorTexture, depthTexture: depthTexture,
                                           counterSampling: nil)
        XCTAssertTrue(rendered)
    }

    // MARK: - Helpers

    private func assertRenderWritesTimestamps(highQualityDepth: Bool,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) async throws {
        let device = try makeDevice()
        guard device.supportsCounterSampling(.atStageBoundary) else {
            throw XCTSkip("This GPU cannot sample counters at stage boundaries")
        }
        guard let timestampSet = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) else {
            throw XCTSkip("No timestamp counter set on this GPU")
        }
        let commandQueue = try XCTUnwrap(device.makeCommandQueue())

        let sampleDescriptor = MTLCounterSampleBufferDescriptor()
        sampleDescriptor.counterSet = timestampSet
        sampleDescriptor.sampleCount = 2
        sampleDescriptor.storageMode = .shared
        let sampleBuffer = try device.makeCounterSampleBuffer(descriptor: sampleDescriptor)

        let renderer = try makeRenderer(device: device, highQualityDepth: highQualityDepth)
        await renderer.addChunk(try makeChunk(device: device))
        let colorTexture = try makeTexture(device: device, format: .rgba8Unorm, usage: [.renderTarget, .shaderRead], storage: .shared)
        let depthTexture = try makeTexture(device: device, format: .depth32Float, usage: [.renderTarget], storage: .private)

        let sampling = SplatRenderer.RenderStageCounterSampling(sampleBuffer: sampleBuffer,
                                                                startOfVertexSampleIndex: 0,
                                                                endOfFragmentSampleIndex: 1)
        let rendered = try renderWithRetry(renderer, commandQueue: commandQueue,
                                           colorTexture: colorTexture, depthTexture: depthTexture,
                                           counterSampling: sampling)
        XCTAssertTrue(rendered, "render() never produced a frame", file: file, line: line)

        let data = try XCTUnwrap(sampleBuffer.resolveCounterRange(0..<2), file: file, line: line)
        let timestamps = data.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self)) }
        XCTAssertEqual(timestamps.count, 2, file: file, line: line)
        XCTAssertNotEqual(timestamps[0].timestamp, MTLCounterErrorValue, "No sample at the start of the vertex stage", file: file, line: line)
        XCTAssertNotEqual(timestamps[1].timestamp, MTLCounterErrorValue, "No sample at the end of the fragment stage", file: file, line: line)
        XCTAssertGreaterThan(timestamps[1].timestamp, timestamps[0].timestamp,
                             "The end of the fragment stage should come after the start of the vertex stage", file: file, line: line)
    }

    private func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        guard device.supportsFamily(.apple4) else {
            throw XCTSkip("The multi-stage pipeline needs an Apple4+ GPU family (Apple silicon)")
        }
        return device
    }

    private func makeRenderer(device: MTLDevice, highQualityDepth: Bool) throws -> SplatRenderer {
        try SplatRenderer(device: device,
                          colorFormat: .rgba8Unorm,
                          depthFormat: .depth32Float,
                          sampleCount: 1,
                          maxViewCount: 1,
                          maxSimultaneousRenders: 3,
                          highQualityDepth: highQualityDepth)
    }

    private func makeTexture(device: MTLDevice,
                             format: MTLPixelFormat,
                             usage: MTLTextureUsage,
                             storage: MTLStorageMode) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                  width: Self.textureSize,
                                                                  height: Self.textureSize,
                                                                  mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = storage
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Unable to create a \(format) texture")
        }
        return texture
    }

    /// A few large opaque splats in front of the camera, so the pass has real work to time.
    private func makeChunk(device: MTLDevice) throws -> SplatChunk {
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, -2),
            SIMD3(0.1, 0.1, -2),
            SIMD3(-0.1, 0.1, -2),
            SIMD3(0.1, -0.1, -2),
        ]
        let buffer = try MetalBuffer<EncodedSplatPoint>(device: device)
        try buffer.ensureCapacity(positions.count)
        for position in positions {
            buffer.append(EncodedSplatPoint(position: position,
                                            colorSH0: SIMD3<Float>(1, 1, 1),
                                            opacity: 1,
                                            scale: SIMD3<Float>(0.2, 0.2, 0.2),
                                            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)))
        }
        return SplatChunk(splats: buffer)
    }

    /// Camera at the origin looking down -Z, 60 degree vertical field of view, depth in [0, 1].
    private func makeViewport() -> SplatRenderer.ViewportDescriptor {
        let size = Self.textureSize
        let ys = 1 / tan(Float.pi / 6), near: Float = 0.1, far: Float = 100
        let zs = far / (near - far)
        let projection = simd_float4x4(columns: (SIMD4<Float>(ys, 0, 0, 0),
                                                 SIMD4<Float>(0, ys, 0, 0),
                                                 SIMD4<Float>(0, 0, zs, -1),
                                                 SIMD4<Float>(0, 0, zs * near, 0)))
        return SplatRenderer.ViewportDescriptor(viewport: MTLViewport(originX: 0, originY: 0,
                                                                      width: Double(size), height: Double(size),
                                                                      znear: 0, zfar: 1),
                                                projectionMatrix: projection,
                                                viewMatrix: matrix_identity_float4x4,
                                                screenSize: SIMD2(x: size, y: size))
    }

    /// The first sort runs in the background, so render() can return false at first. Retries with a fresh
    /// command buffer until it renders, for at most five seconds.
    private func renderWithRetry(_ renderer: SplatRenderer,
                                 commandQueue: MTLCommandQueue,
                                 colorTexture: MTLTexture,
                                 depthTexture: MTLTexture,
                                 counterSampling: SplatRenderer.RenderStageCounterSampling?) throws -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while true {
            let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
            let rendered = try renderer.render(viewports: [makeViewport()],
                                               colorTexture: colorTexture,
                                               colorStoreAction: .store,
                                               depthTexture: depthTexture,
                                               rasterizationRateMap: nil,
                                               renderTargetArrayLength: 1,
                                               counterSampling: counterSampling,
                                               to: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if rendered { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
