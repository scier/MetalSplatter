import Metal
import simd

public struct ModelRendererViewportDescriptor {
    var viewport: MTLViewport
    var projectionMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
    var screenSize: SIMD2<Int>
}

public protocol ModelRenderer: Sendable {
    /// Returns true if the renderer is likely ready to render successfully.
    /// Check this before acquiring a drawable to avoid wasting frames.
    var isReadyToRender: Bool { get }

    /// Renders to the given command buffer.
    /// - Returns: `true` if rendering was performed, `false` if the frame should be dropped.
    @discardableResult
    func render(viewports: [ModelRendererViewportDescriptor],
                colorTexture: MTLTexture,
                colorStoreAction: MTLStoreAction,
                depthTexture: MTLTexture?,
                rasterizationRateMap: MTLRasterizationRateMap?,
                renderTargetArrayLength: Int,
                to commandBuffer: MTLCommandBuffer) throws -> Bool
}
