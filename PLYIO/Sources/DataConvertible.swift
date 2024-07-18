import Foundation

public protocol DataConvertible {
    // MARK: Reading from DataProtocol

    // Assumes that data.count - offset >= byteWidth
    init<D: DataProtocol>(_ data: D, from offset: D.Index, bigEndian: Bool)
    // Assumes that data.count >= byteWidth
    init<D: DataProtocol>(_ data: D, bigEndian: Bool)

    // Assumes that data.count - offset >= count * byteWidth
    static func array<D: DataProtocol>(_ data: D, from offset: D.Index, count: Int, bigEndian: Bool) -> [Self]
    // Assumes that data.count >= count * byteWidth
    static func array<D: DataProtocol>(_ data: D, count: Int, bigEndian: Bool) -> [Self]

    // MARK: Writing to MutableDataProtocol

    func append<D: MutableDataProtocol>(to data: inout D, bigEndian: Bool)

    static func append<D: MutableDataProtocol>(_ values: [Self], to data: inout D, bigEndian: Bool)
}

fileprivate enum DataConvertibleConstants {
    fileprivate static let isBigEndian = 42 == 42.bigEndian
}

public extension BinaryInteger
where Self: DataConvertible, Self: EndianConvertible {
    // MARK: Reading from DataProtocol

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

    // MARK: Writing to MutableDataProtocol

    func append<D: MutableDataProtocol>(to data: inout D, bigEndian: Bool) {
        let value = (bigEndian == DataConvertibleConstants.isBigEndian) ? self : byteSwapped
        withUnsafeBytes(of: value) {
            data.append(contentsOf: $0)
        }
    }

    static func append<D: MutableDataProtocol>(_ values: [Self], to data: inout D, bigEndian: Bool) {
        if bigEndian == DataConvertibleConstants.isBigEndian {
            withUnsafeBytes(of: values) {
                data.append(contentsOf: $0)
            }
        } else {
            for value in values {
                let byteSwapped = value.byteSwapped
                withUnsafeBytes(of: byteSwapped) {
                    data.append(contentsOf: $0)
                }
            }
        }
    }
}

public extension BinaryFloatingPoint
where Self: DataConvertible, Self: BitPatternConvertible, Self.BitPattern: ZeroProviding, Self.BitPattern: EndianConvertible {
    // MARK: Reading from DataProtocol
    
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
    
    // MARK: Writing to MutableDataProtocol
    
    func append<D: MutableDataProtocol>(to data: inout D, bigEndian: Bool) {
        let value = (bigEndian == DataConvertibleConstants.isBigEndian) ? bitPattern : bitPattern.byteSwapped
        withUnsafeBytes(of: value) {
            data.append(contentsOf: $0)
        }
    }
    
    static func append<D: MutableDataProtocol>(_ values: [Self], to data: inout D, bigEndian: Bool) {
        if bigEndian == DataConvertibleConstants.isBigEndian {
            withUnsafeBytes(of: values) {
                data.append(contentsOf: $0)
            }
        } else {
            for value in values {
                let byteSwapped = value.bitPattern.byteSwapped
                withUnsafeBytes(of: byteSwapped) {
                    data.append(contentsOf: $0)
                }
            }
        }
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
