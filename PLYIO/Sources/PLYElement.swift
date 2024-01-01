import Foundation

public struct PLYElement {
    public enum Property {
        case int8(Int8)
        case uint8(UInt8)
        case int16(Int16)
        case uint16(UInt16)
        case int32(Int32)
        case uint32(UInt32)
        case float32(Float)
        case float64(Double)
        case listInt8([Int8])
        case listUInt8([UInt8])
        case listInt16([Int16])
        case listUInt16([UInt16])
        case listInt32([Int32])
        case listUInt32([UInt32])
        case listFloat32([Float])
        case listFloat64([Double])

        var uint64Value: UInt64? {
            switch self {
            case .int8(let value): UInt64(value)
            case .uint8(let value): UInt64(value)
            case .int16(let value): UInt64(value)
            case .uint16(let value): UInt64(value)
            case .int32(let value): UInt64(value)
            case .uint32(let value): UInt64(value)
            case .float32, .float64, .listInt8, .listUInt8, .listInt16, .listUInt16, .listInt32, .listUInt32, .listFloat32, .listFloat64: nil
            }
        }
    }

    public var properties: [Property]
}
