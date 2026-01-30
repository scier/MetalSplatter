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
        case .sphericalHarmonicFloat(let values):
            switch values.count {
            case 0: "shFloat(nil)"
            case 1: "shFloat(N=0; (\(values[0].x), \(values[0].y), \(values[0].z)))"
            case 1+3: "shFloat(N=1; (\(values[0].x), \(values[0].y), \(values[0].z)), ...)"
            case 1+3+5: "shFloat(N=2; (\(values[0].x), \(values[0].y), \(values[0].z)), ...)"
            case 1+3+5+7: "shFloat(N=3; (\(values[0].x), \(values[0].y), \(values[0].z)), ...)"
            default: "shFloat(N=?, \(values.count) triples)"
            }
        case .sRGBUInt8(let values):
            "sRGB(\(values.x), \(values.y), \(values.z))"
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
