import Foundation

public protocol DataConvertible {
    // Assumes that data.count - offset >= byteWidth
    init<D: DataProtocol>(_ data: D, from offset: D.Index, bigEndian: Bool)
    // Assumes that data.count >= byteWidth
    init<D: DataProtocol>(_ data: D, bigEndian: Bool)

    // Assumes that data.count - offset >= count * byteWidth
    static func array<D: DataProtocol>(_ data: D, from offset: D.Index, count: Int, bigEndian: Bool) -> [Self]
    // Assumes that data.count >= count * byteWidth
    static func array<D: DataProtocol>(_ data: D, count: Int, bigEndian: Bool) -> [Self]
}

public protocol ZeroProviding {
    static var zero: Self { get }
}

fileprivate enum DataConvertibleConstants {
    fileprivate static let isBigEndian = 42 == 42.bigEndian
}

public extension BinaryInteger
where Self: DataConvertible, Self: EndianConvertible {
    init<D: DataProtocol>(_ data: D, from offset: D.Index, bigEndian: Bool) {
        var value: Self = .zero
        withUnsafeMutableBytes(of: &value) {
            let bytesCopied = data.copyBytes(to: $0, from: offset...)
            assert(bytesCopied == MemoryLayout<Self>.size)
        }
        self = (bigEndian == DataConvertibleConstants.isBigEndian) ? value : value.byteSwapped
    }

    init<D: DataProtocol>(_ data: D, bigEndian: Bool) {
        var value: Self = .zero
        withUnsafeMutableBytes(of: &value) {
            let bytesCopied = data.copyBytes(to: $0)
            assert(bytesCopied == MemoryLayout<Self>.size)
        }
        self = (bigEndian == DataConvertibleConstants.isBigEndian) ? value : value.byteSwapped
    }

    static func array<D: DataProtocol>(_ data: D, from offset: D.Index, count: Int, bigEndian: Bool) -> [Self] {
        var values: [Self] = Array(repeating: .zero, count: count)
        values.withUnsafeMutableBytes {
            let bytesCopied = data.copyBytes(to: $0, from: offset...)
            assert(bytesCopied == MemoryLayout<Self>.size * count)
        }
        if bigEndian != DataConvertibleConstants.isBigEndian {
            for i in 0..<count {
                values[i] = values[i].byteSwapped
            }
        }
        return values
    }

    static func array<D: DataProtocol>(_ data: D, count: Int, bigEndian: Bool) -> [Self] {
        var values: [Self] = Array(repeating: .zero, count: count)
        values.withUnsafeMutableBytes {
            let bytesCopied = data.copyBytes(to: $0)
            assert(bytesCopied == MemoryLayout<Self>.size * count)
        }
        if bigEndian != DataConvertibleConstants.isBigEndian {
            for i in 0..<count {
                values[i] = values[i].byteSwapped
            }
        }
        return values
    }
}

public extension BinaryFloatingPoint
where Self: DataConvertible, Self: BitPatternRepresentible, Self.BitPattern: ZeroProviding, Self.BitPattern: EndianConvertible {
    init<D: DataProtocol>(_ data: D, from offset: D.Index, bigEndian: Bool) {
        if bigEndian == DataConvertibleConstants.isBigEndian {
            self = .zero
            withUnsafeMutableBytes(of: &self) {
                let bytesCopied = data.copyBytes(to: $0, from: offset...)
                assert(bytesCopied == MemoryLayout<Self>.size)
            }
        } else {
            var value: BitPattern = .zero
            withUnsafeMutableBytes(of: &value) {
                let bytesCopied = data.copyBytes(to: $0, from: offset...)
                assert(bytesCopied == MemoryLayout<BitPattern>.size)
            }
            self = Self(bitPattern: value.byteSwapped)
        }
    }

    init<D: DataProtocol>(_ data: D, bigEndian: Bool) {
        if bigEndian == DataConvertibleConstants.isBigEndian {
            self = .zero
            withUnsafeMutableBytes(of: &self) {
                let bytesCopied = data.copyBytes(to: $0)
                assert(bytesCopied == MemoryLayout<Self>.size)
            }
        } else {
            var value: BitPattern = .zero
            withUnsafeMutableBytes(of: &value) {
                let bytesCopied = data.copyBytes(to: $0)
                assert(bytesCopied == MemoryLayout<BitPattern>.size)
            }
            self = Self(bitPattern: value.byteSwapped)
        }
    }

    static func array<D: DataProtocol>(_ data: D, from offset: D.Index, count: Int, bigEndian: Bool) -> [Self] {
        var values: [Self] = Array(repeating: .zero, count: count)
        values.withUnsafeMutableBytes {
            let bytesCopied = data.copyBytes(to: $0, from: offset...)
            assert(bytesCopied == MemoryLayout<Self>.size * count)
        }
        if bigEndian != DataConvertibleConstants.isBigEndian {
            for i in 0..<count {
                values[i] = Self(bitPattern: values[i].bitPattern.byteSwapped)
            }
        }
        return values
    }

    static func array<D: DataProtocol>(_ data: D, count: Int, bigEndian: Bool) -> [Self] {
        var values: [Self] = Array(repeating: .zero, count: count)
        values.withUnsafeMutableBytes {
            let bytesCopied = data.copyBytes(to: $0)
            assert(bytesCopied == MemoryLayout<Self>.size * count)
        }
        if bigEndian != DataConvertibleConstants.isBigEndian {
            for i in 0..<count {
                values[i] = Self(bitPattern: values[i].bitPattern.byteSwapped)
            }
        }
        return values
    }
}

extension Int8: DataConvertible {}
extension UInt8: DataConvertible {}
extension Int16: DataConvertible {}
extension UInt16: DataConvertible {}
extension Int32: DataConvertible {}
extension UInt32: DataConvertible, ZeroProviding {}
extension Int64: DataConvertible {}
extension UInt64: DataConvertible, ZeroProviding {}
extension Float: DataConvertible {}
extension Double: DataConvertible {}
