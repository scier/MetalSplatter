import Foundation

public protocol UnsafeRawPointerConvertible {
    // MARK: Reading from UnsafeRawPointer

    // Assumes that data size - offset >= byteWidth
    init(_ data: UnsafeRawPointer, from offset: Int, bigEndian: Bool)
    // Assumes that data size >= byteWidth
    init(_ data: UnsafeRawPointer, bigEndian: Bool)

    // Assumes that data size - offset >= count * byteWidth
    static func array(_ data: UnsafeRawPointer, from offset: Int, count: Int, bigEndian: Bool) -> [Self]
    // Assumes that data size >= count * byteWidth
    static func array(_ data: UnsafeRawPointer, count: Int, bigEndian: Bool) -> [Self]

    // MARK: Writing to UnsafeMutableRawPointer

    // Assumes that data size - offset >= byteWidth
    // Returns number of bytes stored
    @discardableResult
    func store(to data: UnsafeMutableRawPointer, at offset: Int, bigEndian: Bool) -> Int
    // Assumes that data size >= byteWidth
    // Returns number of bytes stored
    @discardableResult
    func store(to data: UnsafeMutableRawPointer, bigEndian: Bool) -> Int

    // Assumes that data size - offset >= count * byteWidth
    // Returns number of bytes stored
    @discardableResult
    static func store(_ values: [Self], to data: UnsafeMutableRawPointer, at offset: Int, bigEndian: Bool) -> Int
    // Assumes that data size >= count * byteWidth
    // Returns number of bytes stored
    @discardableResult
    static func store(_ values: [Self], to data: UnsafeMutableRawPointer, bigEndian: Bool) -> Int
}

fileprivate enum UnsafeRawPointerConvertibleConstants {
    fileprivate static let isBigEndian = 42 == 42.bigEndian
}

public extension FixedWidthInteger where Self: UnsafeRawPointerConvertible {
    // MARK: Reading from UnsafeRawPointer

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

    // MARK: Writing to UnsafeMutableRawPointer

    @discardableResult
    func store(to data: UnsafeMutableRawPointer, at offset: Int, bigEndian: Bool) -> Int {
        let value = (bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian) ? self : byteSwapped
        data.storeBytes(of: value, toByteOffset: offset, as: Self.self)
        return Self.byteWidth
    }

    @discardableResult
    func store(to data: UnsafeMutableRawPointer, bigEndian: Bool) -> Int {
        let value = (bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian) ? self : byteSwapped
        data.storeBytes(of: value, as: Self.self)
        return Self.byteWidth
    }

    @discardableResult
    static func store(_ values: [Self], to data: UnsafeMutableRawPointer, at offset: Int, bigEndian: Bool) -> Int {
        if bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian {
            values.withUnsafeBytes {
                (data + offset).copyMemory(from: $0.baseAddress!, byteCount: values.count * byteWidth)
            }
        } else {
            for (index, value) in values.enumerated() {
                let byteSwapped = value.byteSwapped
                data.storeBytes(of: byteSwapped, toByteOffset: offset + index * byteWidth, as: Self.self)
            }
        }
        return values.count * byteWidth
    }

    @discardableResult
    static func store(_ values: [Self], to data: UnsafeMutableRawPointer, bigEndian: Bool) -> Int {
        if bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian {
            values.withUnsafeBytes {
                data.copyMemory(from: $0.baseAddress!, byteCount: values.count * byteWidth)
            }
        } else {
            for (index, value) in values.enumerated() {
                let byteSwapped = value.byteSwapped
                data.storeBytes(of: byteSwapped, toByteOffset: index * byteWidth, as: Self.self)
            }
        }
        return values.count * byteWidth
    }
}

public extension BinaryFloatingPoint where Self: UnsafeRawPointerConvertible, Self: BitPatternConvertible, Self.BitPattern: FixedWidthInteger {
    // MARK: Reading from UnsafeRawPointer

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

    // MARK: Writing to UnsafeMutableRawPointer

    @discardableResult
    func store(to data: UnsafeMutableRawPointer, at offset: Int, bigEndian: Bool) -> Int {
        let value = (bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian) ? bitPattern : bitPattern.byteSwapped
        data.storeBytes(of: value, toByteOffset: offset, as: BitPattern.self)
        return Self.byteWidth
    }

    @discardableResult
    func store(to data: UnsafeMutableRawPointer, bigEndian: Bool) -> Int {
        let value = (bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian) ? bitPattern : bitPattern.byteSwapped
        data.storeBytes(of: value, as: BitPattern.self)
        return Self.byteWidth
    }

    @discardableResult
    static func store(_ values: [Self], to data: UnsafeMutableRawPointer, at offset: Int, bigEndian: Bool) -> Int {
        if bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian {
            values.withUnsafeBytes {
                (data + offset).copyMemory(from: $0.baseAddress!, byteCount: values.count * byteWidth)
            }
        } else {
            for (index, value) in values.enumerated() {
                let byteSwapped = value.bitPattern.byteSwapped
                data.storeBytes(of: byteSwapped, toByteOffset: offset + index * byteWidth, as: BitPattern.self)
            }
        }
        return values.count * byteWidth
    }

    @discardableResult
    static func store(_ values: [Self], to data: UnsafeMutableRawPointer, bigEndian: Bool) -> Int {
        if bigEndian == UnsafeRawPointerConvertibleConstants.isBigEndian {
            values.withUnsafeBytes {
                data.copyMemory(from: $0.baseAddress!, byteCount: values.count * byteWidth)
            }
        } else {
            for (index, value) in values.enumerated() {
                let byteSwapped = value.bitPattern.byteSwapped
                data.storeBytes(of: byteSwapped, toByteOffset: index * byteWidth, as: BitPattern.self)
            }
        }
        return values.count * byteWidth
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
