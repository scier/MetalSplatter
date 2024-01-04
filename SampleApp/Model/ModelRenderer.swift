import Foundation
import Metal
import simd

public protocol ModelRenderer {
    typealias CameraMatrices = ( projection: simd_float4x4, view: simd_float4x4 )
    func willRender(viewportCameras: [CameraMatrices])
    func render(viewportCameras: [CameraMatrices], to renderEncoder: MTLRenderCommandEncoder)
}
