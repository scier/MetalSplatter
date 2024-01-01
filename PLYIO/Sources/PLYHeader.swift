import Foundation

public struct PLYHeader: Equatable {
    public enum Format: String, Equatable {
        case ascii
        case binaryLittleEndian = "binary_little_endian"
        case binaryBigEndian = "binary_big_endian"
    }

    public struct Element: Equatable {
        public var name: String
        public var count: UInt32
        public var properties: [Property]

        public func index(forPropertyNamed name: String) -> Int? {
            properties.firstIndex { $0.name == name }
        }
    }

    public enum PropertyType: Equatable {
        case primitive(PrimitivePropertyType)
        case list(countType: PrimitivePropertyType, valueType: PrimitivePropertyType)
    }

    public enum PrimitivePropertyType: Equatable {
        case int8 // aka char
        case uint8 // aka uchar
        case int16 // aka short
        case uint16 // aka ushort
        case int32 // aka int
        case uint32 // aka uint
        case float32 // aka float
        case float64 // aka double

        static func fromString(_ string: String) -> PrimitivePropertyType? {
            switch string {
            case "int8",    "char"  : .int8
            case "uint8",   "uchar" : .uint8
            case "int16",   "short" : .int16
            case "uint16",  "ushort": .uint16
            case "int32",   "int"   : .int32
            case "uint32",  "uint"  : .uint32
            case "float32", "float" : .float32
            case "float64", "double": .float64
            default: nil
            }
        }

        var isInteger: Bool {
            switch self {
            case .int8, .uint8, .int16, .uint16, .int32, .uint32: true
            case .float32, .float64: false
            }
        }

        var byteWidth: Int {
            switch self {
            case .int8: Int8.byteWidth
            case .uint8: UInt8.byteWidth
            case .int16: Int16.byteWidth
            case .uint16: UInt16.byteWidth
            case .int32: Int32.byteWidth
            case .uint32: UInt32.byteWidth
            case .float32: Float.byteWidth
            case .float64: Double.byteWidth
            }
        }

        func decodePrimitive(_ body: UnsafeRawPointer, offset: Int, bigEndian: Bool) -> PLYElement.Property {
            switch self {
            case .int8   : .int8   (Int8  (body, from: offset, bigEndian: bigEndian))
            case .uint8  : .uint8  (UInt8 (body, from: offset, bigEndian: bigEndian))
            case .int16  : .int16  (Int16 (body, from: offset, bigEndian: bigEndian))
            case .uint16 : .uint16 (UInt16(body, from: offset, bigEndian: bigEndian))
            case .int32  : .int32  (Int32 (body, from: offset, bigEndian: bigEndian))
            case .uint32 : .uint32 (UInt32(body, from: offset, bigEndian: bigEndian))
            case .float32: .float32(Float (body, from: offset, bigEndian: bigEndian))
            case .float64: .float64(Double(body, from: offset, bigEndian: bigEndian))
            }
        }

        func decodeList(_ body: UnsafeRawPointer, offset: Int, count: Int, bigEndian: Bool) -> PLYElement.Property {
            switch self {
            case .int8   : .listInt8   (Int8.array  (body, from: offset, count: count, bigEndian: bigEndian))
            case .uint8  : .listUInt8  (UInt8.array (body, from: offset, count: count, bigEndian: bigEndian))
            case .int16  : .listInt16  (Int16.array (body, from: offset, count: count, bigEndian: bigEndian))
            case .uint16 : .listUInt16 (UInt16.array(body, from: offset, count: count, bigEndian: bigEndian))
            case .int32  : .listInt32  (Int32.array (body, from: offset, count: count, bigEndian: bigEndian))
            case .uint32 : .listUInt32 (UInt32.array(body, from: offset, count: count, bigEndian: bigEndian))
            case .float32: .listFloat32(Float.array (body, from: offset, count: count, bigEndian: bigEndian))
            case .float64: .listFloat64(Double.array(body, from: offset, count: count, bigEndian: bigEndian))
            }
        }
    }

    public struct Property: Equatable {
        public var name: String
        public var type: PropertyType
    }

    public var format: Format
    public var version: String
    public var elements: [Element]

    public func index(forElementNamed name: String) -> Int? {
        elements.firstIndex { $0.name == name }
    }
}

extension PLYHeader: CustomStringConvertible {
    public var description: String {
        "ply\n" +
        "format \(format.rawValue) \(version)\n" +
        elements.map(\.description).reduce("", +)
    }
}

extension PLYHeader.Element: CustomStringConvertible {
    public var description: String {
        "element \(name) \(count)\n" +
        properties.map(\.description).reduce("", +)
    }
}

extension PLYHeader.Property: CustomStringConvertible {
    public var description: String {
        "property \(type) \(name)\n"
    }
}

extension PLYHeader.PropertyType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .primitive(let primitiveType): primitiveType.description
        case .list(let countType, let valueType): "\(countType) \(valueType)"
        }
    }
}

extension PLYHeader.PrimitivePropertyType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .int8: "char"
        case .uint8: "uchar"
        case .int16: "short"
        case .uint16: "ushort"
        case .int32: "int"
        case .uint32: "uint"
        case .float32: "float"
        case .float64: "double"
        }
    }
}
