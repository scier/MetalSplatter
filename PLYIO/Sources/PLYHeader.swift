import Foundation

public struct PLYHeader: Equatable {
    enum Keyword: String {
        case ply = "ply"
        case format = "format"
        case comment = "comment"
        case element = "element"
        case property = "property"
        case endHeader = "end_header"
    }

    public enum Format: String, Equatable {
        case ascii
        case binaryLittleEndian = "binary_little_endian"
        case binaryBigEndian = "binary_big_endian"
    }

    public struct Element: Equatable {
        public var name: String
        public var count: UInt32
        public var properties: [Property]

        public init(name: String, count: UInt32, properties: [Property]) {
            self.name = name
            self.count = count
            self.properties = properties
        }

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

        var maxIntValue: UInt32 {
            switch self {
            case .int8   : UInt32(Int8.max  )
            case .uint8  : UInt32(UInt8.max )
            case .int16  : UInt32(Int16.max )
            case .uint16 : UInt32(UInt16.max)
            case .int32  : UInt32(Int32.max )
            case .uint32 : UInt32(UInt32.max)
            case .float32: 0
            case .float64: 0
            }
        }
    }

    public struct Property: Equatable {
        public var name: String
        public var type: PropertyType

        public init(name: String, type: PropertyType) {
            self.name = name
            self.type = type
        }
    }

    public var format: Format
    public var version: String
    public var elements: [Element]

    public init(format: Format, version: String, elements: [Element]) {
        self.format = format
        self.version = version
        self.elements = elements
    }

    public func index(forElementNamed name: String) -> Int? {
        elements.firstIndex { $0.name == name }
    }
}
