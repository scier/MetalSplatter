import Foundation

extension SplatScenePoint: CustomStringConvertible {
    public var description: String {
        var components: [String] = []

        // Position
        components += [ "position:(\(position.x), \(position.y), \(position.z))" ]

        components += [ "color:\(color.description)" ]
        components += [ "opacity:\(opacity.description)" ]
        components += [ "scale:\(scale.description)" ]
        components += [ "rotation:(ix = \(rotation.imag.x), iy = \(rotation.imag.y), iz = \(rotation.imag.z), r = \(rotation.real))" ]

        return components.joined(separator: " ")
    }
}

extension SplatScenePoint.Color: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sphericalHarmonic(let values):
            switch values.count {
            case 0: "sh(nil)"
            case 1: "sh(N=0; (\(values[0].x), \(values[0].y), \(values[0].z)))"
            case 1+3: "sh(N=1; (\(values[0].x), \(values[0].y), \(values[0].z)), ...)"
            case 1+3+5: "sh(N=2; (\(values[0].x), \(values[0].y), \(values[0].z)), ...)"
            case 1+3+5+7: "sh(N=3; (\(values[0].x), \(values[0].y), \(values[0].z)), ...)"
            default: "sh(N=?, \(values.count) triples)"
            }
        case .linearFloat(let values):
            "linear(\(values.x), \(values.y), \(values.z))"
        case .linearFloat256(let values):
            "linearFloat256(\(values.x), \(values.y), \(values.z))"
        case .linearUInt8(let values):
            "linearByte(\(values.x), \(values.y), \(values.z))"
        }
    }
}

extension SplatScenePoint.Opacity: CustomStringConvertible {
    public var description: String {
        switch self {
        case .logitFloat(let value):
            "logit(\(value))"
        case .linearFloat(let value):
            "linear(\(value))"
        case .linearUInt8(let value):
            "linearByte(\(value))"
        }
    }
}

extension SplatScenePoint.Scale: CustomStringConvertible {
    public var description: String {
        switch self {
        case .linearFloat(let values):
            "linear(\(values.x), \(values.y), \(values.z))"
        case .exponent(let values):
            "exponent(\(values.x), \(values.y), \(values.z))"
        }
    }
}
