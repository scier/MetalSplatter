import Foundation

extension PLYElement {
    enum BinaryEncodeError: Swift.Error {
        case propertyCountMismatch(expected: PLYHeader.Element, actual: PLYElement)
        case typeMismatch(expected: PLYHeader.PropertyType, actual: PLYElement.Property)
        case listCountTypeOverflow(PLYHeader.PrimitivePropertyType, actualListCount: Int)
        case invalidListCountType(PLYHeader.PrimitivePropertyType)
    }

    // Parse the given element type from the next bytes in the body of a binary PLY file.
    // If sufficient bytes are available, returns the number of bytes consumed and self contains the element decoded.
    // Otherwise returns nil and self is left in an indeterminate state.
    mutating func tryDecodeBinary(type elementHeader: PLYHeader.Element,
                                  from body: UnsafeRawPointer,
                                  at offset: Int,
                                  bodySize: Int,
                                  bigEndian: Bool) throws -> Int? {
        if properties.count != elementHeader.properties.count {
            properties = Array(repeating: .uint8(0), count: elementHeader.properties.count)
        }

        var offset = offset
        let originalOffset = offset
        for (i, propertyHeader) in elementHeader.properties.enumerated() {
            let remainingBytes = bodySize - (offset - originalOffset)
            switch propertyHeader.type {
            case .primitive(let primitiveType):
                guard remainingBytes >= primitiveType.byteWidth else {
                    return nil
                }
                let value = PLYElement.Property.decodeBinaryPrimitive(type: primitiveType, from: body, at: offset, bigEndian: bigEndian)
                properties[i] = value
                offset += primitiveType.byteWidth
            case .list(countType: let countType, valueType: let valueType):
                guard remainingBytes >= countType.byteWidth else {
                    return nil
                }
                let count = Int(PLYElement.Property.decodeBinaryPrimitive(type: countType, from: body, at: offset, bigEndian: bigEndian).uint64Value!)
                guard remainingBytes >= countType.byteWidth + count * valueType.byteWidth else {
                    return nil
                }

                offset += countType.byteWidth
                let value = PLYElement.Property.decodeBinaryList(valueType: valueType, from: body, at: offset, count: count, bigEndian: bigEndian)
                properties[i] = value
                offset += count * valueType.byteWidth
            }
        }

        return offset - originalOffset
    }

    func encodeBinary(type elementHeader: PLYHeader.Element,
                      to data: UnsafeMutableRawPointer,
                      at offset: Int,
                      bigEndian: Bool) throws -> Int {
        guard properties.count == elementHeader.properties.count else {
            throw BinaryEncodeError.propertyCountMismatch(expected: elementHeader, actual: self)
        }
        var sizeSoFar = 0
        for (property, propertyType) in zip(properties, elementHeader.properties) {
            sizeSoFar += try property.encodeBinary(type: propertyType.type, to: data, at: offset + sizeSoFar, bigEndian: bigEndian)
        }
        return sizeSoFar
    }

    func encodedBinaryByteWidth(type elementHeader: PLYHeader.Element) throws -> Int {
        guard properties.count == elementHeader.properties.count else {
            throw BinaryEncodeError.propertyCountMismatch(expected: elementHeader, actual: self)
        }
        var total = 0
        for i in 0..<properties.count {
            total += properties[i].encodedBinaryByteWidth(type: elementHeader.properties[i].type)
        }
        return total
    }
}

fileprivate extension PLYElement.Property {
    static func decodeBinaryPrimitive(type: PLYHeader.PrimitivePropertyType,
                                      from body: UnsafeRawPointer,
                                      at offset: Int,
                                      bigEndian: Bool) -> PLYElement.Property {
        switch type {
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

    static func decodeBinaryList(valueType: PLYHeader.PrimitivePropertyType,
                                 from body: UnsafeRawPointer,
                                 at offset: Int,
                                 count: Int,
                                 bigEndian: Bool) -> PLYElement.Property {
        switch valueType {
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

    func encodeBinary(type: PLYHeader.PropertyType,
                      to data: UnsafeMutableRawPointer,
                      at offset: Int,
                      bigEndian: Bool) throws -> Int {
        switch type {
        case .primitive(let valueType):
            try encodeBinaryPrimitive(type: valueType, to: data, at: offset, bigEndian: bigEndian)
        case .list(countType: let countType, valueType: let valueType):
            try encodeBinaryList(countType: countType,
                                 valueType: valueType,
                                 to: data,
                                 at: offset,
                                 bigEndian: bigEndian)
        }
    }

    func encodeBinaryPrimitive(type: PLYHeader.PrimitivePropertyType,
                               to data: UnsafeMutableRawPointer,
                               at offset: Int,
                               bigEndian: Bool) throws -> Int {
        switch (type, self) {
        case (.int8,    .int8(   let value )): value.store(to: data, at: offset, bigEndian: bigEndian)
        case (.uint8,   .uint8(  let value )): value.store(to: data, at: offset, bigEndian: bigEndian)
        case (.int16,   .int16(  let value )): value.store(to: data, at: offset, bigEndian: bigEndian)
        case (.uint16,  .uint16( let value )): value.store(to: data, at: offset, bigEndian: bigEndian)
        case (.int32,   .int32(  let value )): value.store(to: data, at: offset, bigEndian: bigEndian)
        case (.uint32,  .uint32( let value )): value.store(to: data, at: offset, bigEndian: bigEndian)
        case (.float32, .float32(let value )): value.store(to: data, at: offset, bigEndian: bigEndian)
        case (.float64, .float64(let value )): value.store(to: data, at: offset, bigEndian: bigEndian)
        default: throw PLYElement.BinaryEncodeError.typeMismatch(expected: .primitive(type), actual: self)
        }
    }

    func encodeBinaryList(countType: PLYHeader.PrimitivePropertyType,
                          valueType: PLYHeader.PrimitivePropertyType,
                          to data: UnsafeMutableRawPointer,
                          at offset: Int,
                          bigEndian: Bool) throws -> Int {
        guard let listCount else {
            throw PLYElement.BinaryEncodeError.typeMismatch(expected: .list(countType: countType, valueType: valueType),
                                                            actual: self)
        }

        guard listCount < countType.maxIntValue else {
            throw PLYElement.BinaryEncodeError.listCountTypeOverflow(countType, actualListCount: listCount)
        }
        guard countType.isInteger else {
            throw PLYElement.BinaryEncodeError.invalidListCountType(countType)
        }

        let countSize: Int
        switch countType {
        case .int8  : countSize = Int8(  listCount).store(to: data, at: offset, bigEndian: bigEndian)
        case .uint8 : countSize = UInt8( listCount).store(to: data, at: offset, bigEndian: bigEndian)
        case .int16 : countSize = Int16( listCount).store(to: data, at: offset, bigEndian: bigEndian)
        case .uint16: countSize = UInt16(listCount).store(to: data, at: offset, bigEndian: bigEndian)
        case .int32 : countSize = Int32( listCount).store(to: data, at: offset, bigEndian: bigEndian)
        case .uint32: countSize = UInt32(listCount).store(to: data, at: offset, bigEndian: bigEndian)
        case .float32, .float64:
            fatalError("Internal error: unhandled list count type during encode: \(countType)")
        }

        let offset = offset + countSize

        let valuesSize: Int
        switch (valueType, self) {
        case (.int8,    .listInt8(   let values)): valuesSize = Int8   .store(values, to: data, at: offset, bigEndian: bigEndian)
        case (.uint8,   .listUInt8(  let values)): valuesSize = UInt8  .store(values, to: data, at: offset, bigEndian: bigEndian)
        case (.int16,   .listInt16(  let values)): valuesSize = Int16  .store(values, to: data, at: offset, bigEndian: bigEndian)
        case (.uint16,  .listUInt16( let values)): valuesSize = UInt16 .store(values, to: data, at: offset, bigEndian: bigEndian)
        case (.int32,   .listInt32(  let values)): valuesSize = Int32  .store(values, to: data, at: offset, bigEndian: bigEndian)
        case (.uint32,  .listUInt32( let values)): valuesSize = UInt32 .store(values, to: data, at: offset, bigEndian: bigEndian)
        case (.float32, .listFloat32(let values)): valuesSize = Float32.store(values, to: data, at: offset, bigEndian: bigEndian)
        case (.float64, .listFloat64(let values)): valuesSize = Float64.store(values, to: data, at: offset, bigEndian: bigEndian)
        default:
            throw PLYElement.BinaryEncodeError.typeMismatch(expected: .list(countType: countType, valueType: valueType),
                                                            actual: self)
        }

        return countSize + valuesSize
    }

    func encodedBinaryByteWidth(type: PLYHeader.PropertyType) -> Int {
        switch (type, self) {
        case (.primitive(let primitiveType), _):
            primitiveType.byteWidth
        case (.list(countType: let countType, valueType: let valueType), _):
            countType.byteWidth + (listCount ?? 0) * valueType.byteWidth
        }
    }
}
