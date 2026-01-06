import Metal
import SampleBoxRenderer

extension SampleBoxRenderer: ModelRenderer {
    @discardableResult
    public func render(viewports: [ModelRendererViewportDescriptor],
                       colorTexture: MTLTexture,
                       colorStoreAction: MTLStoreAction,
                       depthTexture: MTLTexture?,
                       rasterizationRateMap: MTLRasterizationRateMap?,
                       renderTargetArrayLength: Int,
                       to commandBuffer: MTLCommandBuffer) throws -> Bool {
        let remappedViewports = viewports.map { viewport -> ViewportDescriptor in
            ViewportDescriptor(viewport: viewport.viewport,
                               projectionMatrix: viewport.projectionMatrix,
                               viewMatrix: viewport.viewMatrix,
                               screenSize: viewport.screenSize)
        }
        try render(viewports: remappedViewports,
                   colorTexture: colorTexture,
                   colorStoreAction: colorStoreAction,
                   depthTexture: depthTexture,
                   rasterizationRateMap: rasterizationRateMap,
                   renderTargetArrayLength: renderTargetArrayLength,
                   to: commandBuffer)
        return true  // SampleBoxRenderer always renders successfully
    }
}
