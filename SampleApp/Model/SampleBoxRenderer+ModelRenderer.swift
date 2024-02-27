import Metal
import SampleBoxRenderer

extension SampleBoxRenderer: ModelRenderer {
    public func render(viewports: [ModelRendererViewportDescriptor],
                       colorTexture: MTLTexture,
                       colorStoreAction: MTLStoreAction,
                       depthTexture: MTLTexture?,
                       stencilTexture: MTLTexture?,
                       rasterizationRateMap: MTLRasterizationRateMap?,
                       renderTargetArrayLength: Int,
                       to commandBuffer: MTLCommandBuffer) {
        let remappedViewports = viewports.map { viewport -> ViewportDescriptor in
            ViewportDescriptor(viewport: viewport.viewport,
                               projectionMatrix: viewport.projectionMatrix,
                               viewMatrix: viewport.viewMatrix,
                               screenSize: viewport.screenSize)
        }
        render(viewports: remappedViewports,
               colorTexture: colorTexture,
               colorStoreAction: colorStoreAction,
               depthTexture: depthTexture,
               stencilTexture: stencilTexture,
               rasterizationRateMap: rasterizationRateMap,
               renderTargetArrayLength: renderTargetArrayLength,
               to: commandBuffer)
    }
}
