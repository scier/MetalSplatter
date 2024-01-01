public protocol EndianConvertible {
    var byteSwapped: Self { get }
}

extension Int8: EndianConvertible {}
extension UInt8: EndianConvertible {}
extension Int16: EndianConvertible {}
extension UInt16: EndianConvertible {}
extension Int32: EndianConvertible {}
extension UInt32: EndianConvertible {}
extension Int64: EndianConvertible {}
extension UInt64: EndianConvertible {}
