import Foundation
import simd

public struct SplatScenePoint {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var color: SIMD3<Float> // Linear R, G, B
    public var sphericalHarmonics: [Float]? // 45 values
    public var opacity: Float
    public var scale: SIMD3<Float>
    public var rotation: simd_quatf

    public init(position: SIMD3<Float>,
                normal: SIMD3<Float>,
                color: SIMD3<Float>,
                sphericalHarmonics: [Float]? = nil,
                opacity: Float,
                scale: SIMD3<Float>,
                rotation: simd_quatf) {
        self.position = position
        self.normal = normal
        self.color = color
        self.sphericalHarmonics = sphericalHarmonics
        self.opacity = opacity
        self.scale = scale
        self.rotation = rotation
    }
}
