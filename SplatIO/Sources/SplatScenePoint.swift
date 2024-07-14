import Foundation
import simd

public struct SplatScenePoint {
    public enum Color {
        case sphericalHarmonic(Float, Float, Float, [Float])
        case firstOrderSphericalHarmonic(Float, Float, Float)
        case linearFloat256(Float, Float, Float)
        case linearUInt8(UInt8, UInt8, UInt8)

        var nonFirstOrderSphericalHarmonics: [Float]? {
            switch self {
            case .sphericalHarmonic(_, _, _, let nonFirstOrderSphericalHarmonics):
                nonFirstOrderSphericalHarmonics
            case .firstOrderSphericalHarmonic, .linearFloat256, .linearUInt8:
                nil
            }
        }
    }

    public enum Opacity {
        case logitFloat(Float)
        case linearFloat(Float)
        case linearUInt8(UInt8)
    }

    public enum Scale {
        case exponent(Float, Float, Float)
        case linearFloat(Float, Float, Float)
    }

    public var position: SIMD3<Float>
    public var color: Color
    public var opacity: Opacity
    public var scale: Scale
    public var rotation: simd_quatf

    public init(position: SIMD3<Float>,
                color: Color,
                opacity: Opacity,
                scale: Scale,
                rotation: simd_quatf) {
        self.position = position
        self.color = color
        self.opacity = opacity
        self.scale = scale
        self.rotation = rotation
    }
}
