import Foundation
import simd

/// Represents the degree of spherical harmonics stored for a splat.
/// Higher degrees provide more accurate view-dependent color at the cost of memory.
public enum SHDegree: UInt8, Sendable, Comparable {
    case sh0 = 0  // 1 coefficient per channel (DC only, view-independent)
    case sh1 = 1  // 4 coefficients per channel
    case sh2 = 2  // 9 coefficients per channel
    case sh3 = 3  // 16 coefficients per channel

    /// Number of coefficients per color channel for this SH degree
    public var coefficientsPerChannel: Int {
        let d = Int(rawValue)
        return (d + 1) * (d + 1)
    }

    /// Total number of RGB coefficient triplets (SIMD3<Float>) for this degree
    public var coefficientCount: Int {
        coefficientsPerChannel
    }

    /// Number of extra coefficients beyond SH0 (for the SH buffer)
    public var extraCoefficientCount: Int {
        coefficientCount - 1
    }

    /// Detect SH degree from coefficient count
    public static func from(coefficientCount: Int) -> SHDegree {
        switch coefficientCount {
        case 0...1: return .sh0
        case 2...4: return .sh1
        case 5...9: return .sh2
        default: return .sh3
        }
    }

    public static func < (lhs: SHDegree, rhs: SHDegree) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SplatPoint: Sendable {
    public enum Color: Sendable {
        public static let SH_C0: Float = 0.28209479177387814
        public static let INV_SH_C0: Float = 1.0 / SH_C0

        /// Raw spherical harmonic coefficients (1-16 RGB triplets for degrees 0-3).
        /// SH0 encodes base color via: sRGB = clamp(0.5 + SH_C0 * sh0, 0, 1)
        /// Should have 1 value (for degree 0), 4 (for degree 1), 9 (for degree 2), or 16 (for degree 3).
        case sphericalHarmonicFloat([SIMD3<Float>])

        /// sRGB color as unsigned bytes (0-255)
        case sRGBUInt8(SIMD3<UInt8>)

        /// Convert raw SH0 coefficients to sRGB (0-1), clamped
        private static func sh0ToSRGB(_ sh0: SIMD3<Float>) -> SIMD3<Float> {
            simd_clamp(0.5 + SH_C0 * sh0, .zero, .one)
        }

        /// Convert sRGB (0-1) to raw SH0 coefficients
        private static func sRGBToSH0(_ srgb: SIMD3<Float>) -> SIMD3<Float> {
            (srgb - 0.5) * INV_SH_C0
        }

        /// Returns the color as spherical harmonic float coefficients.
        public var asSphericalHarmonicFloat: [SIMD3<Float>] {
            switch self {
            case let .sphericalHarmonicFloat(values):
                values
            case let .sRGBUInt8(values):
                [Self.sRGBToSH0(SIMD3<Float>(values) / 255.0)]
            }
        }

        /// Returns the color as sRGB float (0-1 range).
        public var asSRGBFloat: SIMD3<Float> {
            switch self {
            case let .sphericalHarmonicFloat(sh):
                Self.sh0ToSRGB(sh[0])
            case let .sRGBUInt8(value):
                SIMD3<Float>(value) / 255.0
            }
        }

        /// Returns the color as sRGB unsigned bytes (0-255).
        public var asSRGBUInt8: SIMD3<UInt8> {
            switch self {
            case let .sphericalHarmonicFloat(sh):
                (Self.sh0ToSRGB(sh[0]) * 255.0).asUInt8
            case let .sRGBUInt8(value):
                value
            }
        }

        // MARK: - Spherical Harmonics Access

        /// Returns the SH degree based on how many coefficients are stored
        public var shDegree: SHDegree {
            switch self {
            case let .sphericalHarmonicFloat(sh):
                return SHDegree.from(coefficientCount: sh.count)
            case .sRGBUInt8:
                return .sh0
            }
        }

        /// Returns the raw SH DC (degree 0) coefficients without any transformation.
        public var sh0: SIMD3<Float> {
            switch self {
            case let .sphericalHarmonicFloat(sh):
                return sh[0]
            case let .sRGBUInt8(value):
                return Self.sRGBToSH0(SIMD3<Float>(value) / 255.0)
            }
        }

        /// Returns the higher-order SH coefficients (bands 1-3) as a flat array of floats.
        /// The array is empty for SH degree 0 or for sRGBUInt8 colors.
        /// For degree 1: 9 floats (3 coefficients × 3 RGB)
        /// For degree 2: 24 floats (8 coefficients × 3 RGB, cumulative from band 1)
        /// For degree 3: 45 floats (15 coefficients × 3 RGB, cumulative from band 1)
        public var higherOrderSHCoefficients: [Float] {
            guard case let .sphericalHarmonicFloat(sh) = self, sh.count > 1 else {
                return []
            }
            // Skip sh[0] (DC term), flatten the rest to interleaved RGB
            var result: [Float] = []
            result.reserveCapacity((sh.count - 1) * 3)
            for i in 1..<sh.count {
                result.append(sh[i].x)
                result.append(sh[i].y)
                result.append(sh[i].z)
            }
            return result
        }
    }

    public enum Opacity: Sendable {
        case logitFloat(Float)
        case linearFloat(Float)
        case linearUInt8(UInt8)

        static func sigmoid(_ value: Float) -> Float {
            1 / (1 + exp(-value))
        }

        // Inverse sigmoid
        static func logit(_ value: Float) -> Float {
            log(value / (1 - value))
        }

        public var asLogitFloat: Float {
            switch self {
            case let .logitFloat(value):
                value
            case let .linearFloat(value):
                Self.logit(value)
            case let .linearUInt8(value):
                Self.logit((Float(value) + 0.5) / 256) // logit(0) and logit(1) are undefined; so map them to >0 and <1
            }
        }

        public var asLinearFloat: Float {
            switch self {
            case let .logitFloat(value):
                Self.sigmoid(value)
            case let .linearFloat(value):
                value
            case let .linearUInt8(value):
                Float(value) / 255.0
            }
        }

        public var asLinearUInt8: UInt8 {
            switch self {
            case let .logitFloat(value):
                (Self.sigmoid(value) * 256).asUInt8
            case let .linearFloat(value):
                (value * 256).asUInt8
            case let .linearUInt8(value):
                value
            }
        }
    }

    public enum Scale: Sendable {
        case exponent(SIMD3<Float>)
        case linearFloat(SIMD3<Float>)

        public var asExponent: SIMD3<Float> {
            switch self {
            case let .exponent(value):
                value
            case let .linearFloat(value):
                log(value)
            }
        }

        public var asLinearFloat: SIMD3<Float> {
            switch self {
            case let .exponent(value):
                exp(value)
            case let .linearFloat(value):
                value
            }
        }
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

    /// Returns a normalized version with all values converted to their float representations.
    /// Color becomes sphericalHarmonicFloat with a single SH0 coefficient.
    var normalized: SplatPoint {
        SplatPoint(position: position,
                        color: .sphericalHarmonicFloat([color.sh0]),
                        opacity: .linearFloat(opacity.asLinearFloat),
                        scale: .linearFloat(scale.asLinearFloat),
                        rotation: rotation.normalized)
    }
}

fileprivate extension SIMD3 where Scalar == Float {
    var asUInt8: SIMD3<UInt8> {
        SIMD3<UInt8>(x: x.asUInt8, y: y.asUInt8, z: z.asUInt8)
    }
}

fileprivate extension SIMD3 where Scalar == UInt8 {
    var asFloat: SIMD3<Float> {
        SIMD3<Float>(x: Float(x), y: Float(y), z: Float(z))
    }
}

fileprivate extension Float {
    var asUInt8: UInt8 {
        UInt8(clamped(to: 0.0...255.0))
    }
}

// MARK: - Deprecated

@available(*, deprecated, renamed: "SplatPoint")
public typealias SplatScenePoint = SplatPoint
