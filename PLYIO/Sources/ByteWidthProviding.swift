public protocol ByteWidthProviding {
    static var byteWidth: Int { get }
}

public extension BinaryInteger {
    static var byteWidth: Int { MemoryLayout<Self>.size }
}

public extension BinaryFloatingPoint {
    static var byteWidth: Int { MemoryLayout<Self>.size }
}

extension Int8: ByteWidthProviding {}
extension UInt8: ByteWidthProviding {}
extension Int16: ByteWidthProviding {}
extension UInt16: ByteWidthProviding {}
extension Int32: ByteWidthProviding {}
extension UInt32: ByteWidthProviding {}
extension Int64: ByteWidthProviding {}
extension UInt64: ByteWidthProviding {}
extension Float: ByteWidthProviding {}
extension Double: ByteWidthProviding {}
