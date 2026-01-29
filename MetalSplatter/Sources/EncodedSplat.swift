import Foundation
import Metal
import simd
import SplatIO

#if arch(x86_64)
#warning("x86_64 targets are unsupported by MetalSplatter and will fail at runtime. MetalSplatter builds on x86_64 only because Xcode builds Swift Packages as universal binaries and provides no way to override this. When Swift supports Float16 on x86_64, this may be revisited.")
typealias Float16 = Float
#endif

struct PackedHalf3 {
    var x: Float16
    var y: Float16
    var z: Float16
}

struct PackedRGBHalf4 {
    var r: Float16
    var g: Float16
    var b: Float16
    var a: Float16
}

// Keep in sync with Shaders.metal : Splat
public struct EncodedSplat {
    var position: MTLPackedFloat3
    var color: PackedRGBHalf4
    var covA: PackedHalf3
    var covB: PackedHalf3
}

// MARK: - Splat Conversion

extension EncodedSplat {
    public init(_ splat: SplatScenePoint) {
        self.init(position: splat.position,
                  color: SIMD4<Float>(splat.color.asLinearFloat.sRGBToLinear, splat.opacity.asLinearFloat),
                  scale: splat.scale.asLinearFloat,
                  rotation: splat.rotation.normalized)
    }

    public init(position: SIMD3<Float>,
                color: SIMD4<Float>,
                scale: SIMD3<Float>,
                rotation: simd_quatf) {
        let transform = simd_float3x3(rotation) * simd_float3x3(diagonal: scale)
        let cov3D = transform * transform.transpose
        self.init(position: MTLPackedFloat3Make(position.x, position.y, position.z),
                  color: PackedRGBHalf4(r: Float16(color.x), g: Float16(color.y), b: Float16(color.z), a: Float16(color.w)),
                  covA: PackedHalf3(x: Float16(cov3D[0, 0]), y: Float16(cov3D[0, 1]), z: Float16(cov3D[0, 2])),
                  covB: PackedHalf3(x: Float16(cov3D[1, 1]), y: Float16(cov3D[1, 2]), z: Float16(cov3D[2, 2])))
    }
}

// MARK: - Helper Extensions

private extension SIMD3<Float> {
    var sRGBToLinear: SIMD3<Float> {
        SIMD3(x: pow(x, 2.2), y: pow(y, 2.2), z: pow(z, 2.2))
    }
}
