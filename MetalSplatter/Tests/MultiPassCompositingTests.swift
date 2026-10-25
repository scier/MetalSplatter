import XCTest
import Metal
import simd
@testable import MetalSplatter

/// Verifies that multiple SplatRenderer instances can render into the SAME color/depth
/// textures in one frame: the first pass uses loadAction .clear, subsequent passes use
/// .load, and the results must composite. This is the pattern used when an app renders
/// several independently-managed splat scenes per frame (one SplatRenderer each, all
/// targeting the frame's drawable textures).
///
/// On macOS (Apple silicon) the multi-stage tile pipeline is active (depth attached +
/// highQualityDepth), which is the same path used on visionOS — so this reproduces the
/// "only the last renderer's splats are visible" bug.
final class MultiPassCompositingTests: XCTestCase {
    private static let textureSize = 256

    func testTwoPassesComposite() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        guard device.supportsFamily(.apple4) else {
            throw XCTSkip("Tile shaders require an Apple4+ GPU family (Apple silicon)")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Unable to create command queue")
        }

        let colorTexture = try makeColorTexture(device: device)
        let depthTexture = try makeDepthTexture(device: device)

        // Two independent renderers, one splat cluster each:
        // renderer A on the left, renderer B on the right.
        let rendererA = try makeRenderer(device: device)
        let rendererB = try makeRenderer(device: device)
        await rendererA.addChunk(try makeChunk(device: device, center: SIMD3<Float>(-0.5, 0, -2)))
        await rendererB.addChunk(try makeChunk(device: device, center: SIMD3<Float>(0.5, 0, -2)))

        let viewports = [makeViewportDescriptor()]

        // Pass 1: renderer A clears the render targets and draws its splats.
        try renderWithRetry(rendererA,
                            commandQueue: commandQueue,
                            viewports: viewports,
                            colorTexture: colorTexture,
                            colorLoadAction: .clear,
                            depthTexture: depthTexture,
                            depthLoadAction: .clear)

        // Pass 2: renderer B loads the existing render target content and must
        // composite on top of it, preserving renderer A's output.
        try renderWithRetry(rendererB,
                            commandQueue: commandQueue,
                            viewports: viewports,
                            colorTexture: colorTexture,
                            colorLoadAction: .load,
                            depthTexture: depthTexture,
                            depthLoadAction: .load)

        let alpha = readbackAlpha(colorTexture)
        let size = Self.textureSize
        let thirdWidth = size / 3

        var leftThirdMaxAlpha: UInt8 = 0
        var rightThirdMaxAlpha: UInt8 = 0
        for y in 0..<size {
            for x in 0..<size {
                let a = alpha[y * size + x]
                if x < thirdWidth {
                    leftThirdMaxAlpha = max(leftThirdMaxAlpha, a)
                } else if x >= size - thirdWidth {
                    rightThirdMaxAlpha = max(rightThirdMaxAlpha, a)
                }
            }
        }

        XCTAssertGreaterThan(rightThirdMaxAlpha, 0,
                             "Renderer B's splat (second pass) should be visible in the right third")
        XCTAssertGreaterThan(leftThirdMaxAlpha, 0,
                             "Renderer A's splat (first pass) was wiped out by the second pass — .load must composite, not overwrite")
        XCTAssertGreaterThan(Float(leftThirdMaxAlpha) / 255, 0.2,
                             "Renderer A's splat should survive the second pass at healthy alpha, not as a faint artifact")
    }

    // MARK: - Helpers

    private func makeRenderer(device: MTLDevice) throws -> SplatRenderer {
        // depthFormat + highQualityDepth forces the multi-stage tile pipeline on macOS,
        // matching the path used on Vision Pro.
        try SplatRenderer(device: device,
                          colorFormat: .rgba8Unorm,
                          depthFormat: .depth32Float,
                          sampleCount: 1,
                          maxViewCount: 1,
                          maxSimultaneousRenders: 3,
                          highQualityDepth: true)
    }

    private func makeColorTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: Self.textureSize,
                                                                  height: Self.textureSize,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Unable to create color texture")
        }
        return texture
    }

    private func makeDepthTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: Self.textureSize,
                                                                  height: Self.textureSize,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("Unable to create depth texture")
        }
        return texture
    }

    /// A handful of large opaque gaussians clustered around `center`, big enough to cover many pixels.
    private func makeChunk(device: MTLDevice, center: SIMD3<Float>) throws -> SplatChunk {
        let offsets: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(0.05, 0.05, 0),
            SIMD3(-0.05, 0.05, 0),
            SIMD3(0.05, -0.05, 0),
            SIMD3(-0.05, -0.05, 0),
        ]
        let buffer = try MetalBuffer<EncodedSplatPoint>(device: device)
        try buffer.ensureCapacity(offsets.count)
        for offset in offsets {
            buffer.append(EncodedSplatPoint(position: center + offset,
                                            colorSH0: SIMD3<Float>(1.77, 1.77, 1.77),
                                            opacity: 1.0,
                                            scale: SIMD3<Float>(0.2, 0.2, 0.2),
                                            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)))
        }
        return SplatChunk(splats: buffer)
    }

    /// Camera at the origin looking down -Z (identity view matrix), standard perspective projection.
    private func makeViewportDescriptor() -> SplatRenderer.ViewportDescriptor {
        let size = Self.textureSize
        let viewport = MTLViewport(originX: 0, originY: 0,
                                   width: Double(size), height: Double(size),
                                   znear: 0, zfar: 1)
        return SplatRenderer.ViewportDescriptor(viewport: viewport,
                                                projectionMatrix: Self.perspectiveProjection(fovyRadians: .pi / 3,
                                                                                             aspect: 1,
                                                                                             near: 0.1,
                                                                                             far: 100),
                                                viewMatrix: matrix_identity_float4x4,
                                                screenSize: SIMD2(x: size, y: size))
    }

    /// Right-handed perspective projection (camera looks down -Z), NDC depth in [0, 1].
    private static func perspectiveProjection(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovyRadians * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    /// Calls render() until it returns true (the async sort may not be ready yet),
    /// using a fresh command buffer for each attempt.
    private func renderWithRetry(_ renderer: SplatRenderer,
                                 commandQueue: MTLCommandQueue,
                                 viewports: [SplatRenderer.ViewportDescriptor],
                                 colorTexture: MTLTexture,
                                 colorLoadAction: MTLLoadAction,
                                 depthTexture: MTLTexture,
                                 depthLoadAction: MTLLoadAction,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                XCTFail("Unable to create command buffer", file: file, line: line)
                return
            }
            let rendered = try renderer.render(viewports: viewports,
                                               colorTexture: colorTexture,
                                               colorLoadAction: colorLoadAction,
                                               colorStoreAction: .store,
                                               depthTexture: depthTexture,
                                               depthLoadAction: depthLoadAction,
                                               rasterizationRateMap: nil,
                                               renderTargetArrayLength: 1,
                                               to: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if rendered { return }
            if Date() >= deadline {
                XCTFail("render() did not succeed within the timeout (sorted indices never became available)",
                        file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Reads back the alpha channel of an .rgba8Unorm shared texture, one byte per pixel.
    private func readbackAlpha(_ texture: MTLTexture) -> [UInt8] {
        let size = Self.textureSize
        let bytesPerRow = size * 4
        var rgba = [UInt8](repeating: 0, count: size * bytesPerRow)
        rgba.withUnsafeMutableBytes { pointer in
            texture.getBytes(pointer.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, size, size),
                             mipmapLevel: 0)
        }
        var alpha = [UInt8](repeating: 0, count: size * size)
        for i in 0..<(size * size) {
            alpha[i] = rgba[i * 4 + 3]
        }
        return alpha
    }
}
