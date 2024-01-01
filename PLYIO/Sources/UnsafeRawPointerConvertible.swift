import Foundation

public protocol UnsafeRawPointerConvertible {
    // Assumes that data size - offset >= byteWidth
    init(_ data: UnsafeRawPointer, from offset: Int, bigEndian: Bool)
    // Assumes that data size >= byteWidth
    init(_ data: UnsafeRawPointer, bigEndian: Bool)

    // Assumes that data size - offset >= count * byteWidth
    static func array(_ data: UnsafeRawPointer, from offset: Int, count: Int, bigEndian: Bool) -> [Self]
    // Assumes that data size >= count * byteWidth
    static func array(_ data: UnsafeRawPointer, count: Int, bigEndian: Bool) -> [Self]
}

fileprivate enum UnsafeRawPointerConvertibleConstants {
    fileprivate static let isBigEndian = 42 == 42.bigEndian
}

public extension BinaryInteger where Self: UnsafeRawPointerConvertible, Self: EndianConvertible {
    init(_ data: UnsafeRawPointer, from offset: Int, bigEndian: Bool) {
        let value = (data + offset).loadUnaligned(as: Self.self)
        self = (bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian) ? value : value.byteSwapped
    }

    init(_ data: UnsafeRawPointer, bigEndian: Bool) {
        let value = data.loadUnaligned(as: Self.self)
        self = (bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian) ? value : value.byteSwapped
    }

    static func array(_ data: UnsafeRawPointer, from offset: Int, count: Int, bigEndian: Bool) -> [Self] {
        let size = MemoryLayout<Self>.size
        var values: [Self] = Array(repeating: .zero, count: count)
        if bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian {
            for i in 0..<count {
                values[i] = (data + offset + size*i).loadUnaligned(as: Self.self)
            }
        } else {
            for i in 0..<count {
                values[i] = (data + offset + size*i).loadUnaligned(as: Self.self).byteSwapped
            }
        }
        return values
    }

    static func array(_ data: UnsafeRawPointer, count: Int, bigEndian: Bool) -> [Self] {
        array(data, from: 0, count: count, bigEndian: bigEndian)
    }
}

public extension BinaryFloatingPoint where Self: UnsafeRawPointerConvertible, Self: BitPatternRepresentible, Self.BitPattern: EndianConvertible {
    init(_ data: UnsafeRawPointer, from offset: Int, bigEndian: Bool) {
        self = if bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian {
            (data + offset).loadUnaligned(as: Self.self)
        } else {
            Self(bitPattern: (data + offset).loadUnaligned(as: BitPattern.self).byteSwapped)
        }
    }

    init(_ data: UnsafeRawPointer, bigEndian: Bool) {
        self = if bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian {
            data.loadUnaligned(as: Self.self)
        } else {
            Self(bitPattern: data.loadUnaligned(as: BitPattern.self).byteSwapped)
        }
    }

    static func array(_ data: UnsafeRawPointer, from offset: Int, count: Int, bigEndian: Bool) -> [Self] {
        let size = MemoryLayout<Self>.size
        var values: [Self] = Array(repeating: .zero, count: count)
        if bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian {
            for i in 0..<count {
                values[i] = (data + offset + size*i).loadUnaligned(as: Self.self)
            }
        } else {
            for i in 0..<count {
                values[i] = Self(bitPattern: (data + offset + size*i).loadUnaligned(as: BitPattern.self).byteSwapped)
            }
        }
        return values
    }

    static func array(_ data: UnsafeRawPointer, count: Int, bigEndian: Bool) -> [Self] {
        array(data, from: 0, count: count, bigEndian: bigEndian)
    }
}

extension Int8: UnsafeRawPointerConvertible {}
extension UInt8: UnsafeRawPointerConvertible {}
extension Int16: UnsafeRawPointerConvertible {}
extension UInt16: UnsafeRawPointerConvertible {}
extension Int32: UnsafeRawPointerConvertible {}
extension UInt32: UnsafeRawPointerConvertible {}
extension Int64: UnsafeRawPointerConvertible {}
extension UInt64: UnsafeRawPointerConvertible {}
extension Float: UnsafeRawPointerConvertible {}
extension Double: UnsafeRawPointerConvertible {}
