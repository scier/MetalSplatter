import Metal
import MetalSplatter

extension SplatRenderer: ModelRenderer {
    public func willRender(viewportCameras: [CameraMatrices]) {
        willRender(viewportCameras: viewportCameras.map {
            CameraDescriptor(projectionMatrix: $0.projection, viewMatrix: $0.view, screenSize: $0.screenSize)
        })
    }

    public func render(viewportCameras: [CameraMatrices], to renderEncoder: MTLRenderCommandEncoder) {
        render(viewportCameras: viewportCameras.map {
            CameraDescriptor(projectionMatrix: $0.projection, viewMatrix: $0.view, screenSize: $0.screenSize)
        }, to: renderEncoder)
    }
}
