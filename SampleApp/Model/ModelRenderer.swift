import Foundation
import Metal
import simd

public protocol ModelRenderer {
    typealias CameraMatrices = ( projection: simd_float4x4, view: simd_float4x4, screenSize: SIMD2<Int> )
    func willRender(viewportCameras: [CameraMatrices])
    func render(viewportCameras: [CameraMatrices], to renderEncoder: MTLRenderCommandEncoder)
}
