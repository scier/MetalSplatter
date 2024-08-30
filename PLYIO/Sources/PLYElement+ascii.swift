import Foundation

extension PLYElement {
    public enum ASCIIDecodeError: LocalizedError {
        case bodyInvalidStringForPropertyType(PLYHeader.Element, Int, PLYHeader.Property)
        case bodyMissingPropertyValuesInElement(PLYHeader.Element, Int, PLYHeader.Property)
        case bodyUnexpectedValuesInElement(PLYHeader.Element, Int)

        public var errorDescription: String? {
            switch self {
            case .bodyInvalidStringForPropertyType(let headerElement, let elementIndex, let headerProperty):
                "Invalid type string for property \(headerProperty.name) in element \(headerElement.name), index \(elementIndex)"
            case .bodyMissingPropertyValuesInElement(let headerElement, let elementIndex, let headerProperty):
                "Missing values for property \(headerProperty.name) in element \(headerElement.name), index \(elementIndex)"
            case .bodyUnexpectedValuesInElement(let headerElement, let elementIndex):
                "Unexpected values in element \(headerElement.name), index \(elementIndex)"
            }
        }
    }

    // Parse the given element type from the single line from the body of an ASCII PLY file.
    // Considers only bytes from offset..<(offset+size)
    // May modify the body; after this returns, the body contents are undefined.
    mutating func decodeASCII(type elementHeader: PLYHeader.Element,
                              fromMutable body: UnsafeMutablePointer<UInt8>,
                              at offset: Int,
                              bodySize: Int,
                              elementIndex: Int) throws {
        if properties.count != elementHeader.properties.count {
            properties = Array(repeating: .uint8(0), count: elementHeader.properties.count)
        }

        var stringParser = UnsafeStringParser(data: body, offset: offset, size: bodySize)

        for (i, propertyHeader) in elementHeader.properties.enumerated() {
            switch propertyHeader.type {
            case .primitive(let primitiveType):
                guard let string = stringParser.nextStringSeparatedByWhitespace() else {
                    throw ASCIIDecodeError.bodyMissingPropertyValuesInElement(elementHeader, elementIndex, propertyHeader)
                }
                guard let value = Property.tryDecodeASCIIPrimitive(type: primitiveType, from: string) else {
                    throw ASCIIDecodeError.bodyInvalidStringForPropertyType(elementHeader, elementIndex, propertyHeader)
                }
                properties[i] = value
            case .list(countType: let countType, valueType: let valueType):
                guard let countString = stringParser.nextStringSeparatedByWhitespace() else {
                    throw ASCIIDecodeError.bodyMissingPropertyValuesInElement(elementHeader, elementIndex, propertyHeader)
                }
                guard let count = Property.tryDecodeASCIIPrimitive(type: countType, from: countString)?.uint64Value else {
                    throw ASCIIDecodeError.bodyInvalidStringForPropertyType(elementHeader, elementIndex, propertyHeader)
                }

                properties[i] = try PLYElement.Property.tryDecodeASCIIList(valueType: valueType,
                                                                           count: Int(count),
                                                                           from: &stringParser,
                                                                           elementHeader: elementHeader,
                                                                           elementIndex: elementIndex,
                                                                           propertyHeader: propertyHeader)
            }
        }

        guard stringParser.nextStringSeparatedByWhitespace() == nil else {
            throw ASCIIDecodeError.bodyUnexpectedValuesInElement(elementHeader, elementIndex)
        }
    }
}

fileprivate extension PLYElement.Property {
    static func tryDecodeASCIIPrimitive(type: PLYHeader.PrimitivePropertyType,
                                        from string: String) -> PLYElement.Property? {
        switch type {
        case .int8   : if let value = Int8(  string) { .int8(   value) } else { nil }
        case .uint8  : if let value = UInt8( string) { .uint8(  value) } else { nil }
        case .int16  : if let value = Int16( string) { .int16(  value) } else { nil }
        case .uint16 : if let value = UInt16(string) { .uint16( value) } else { nil }
        case .int32  : if let value = Int32( string) { .int32(  value) } else { nil }
        case .uint32 : if let value = UInt32(string) { .uint32( value) } else { nil }
        case .float32: if let value = Float( string) { .float32(value) } else { nil }
        case .float64: if let value = Double(string) { .float64(value) } else { nil }
        }
    }

    static func tryDecodeASCIIList(valueType: PLYHeader.PrimitivePropertyType,
                                   from strings: [String]) -> PLYElement.Property? {
        switch valueType {
        case .int8:
            let values = strings.compactMap { Int8($0) }
            return values.count == strings.count ? .listInt8(values) : nil
        case .uint8:
            let values = strings.compactMap { UInt8($0) }
            return values.count == strings.count ? .listUInt8(values) : nil
        case .int16:
            let values = strings.compactMap { Int16($0) }
            return values.count == strings.count ? .listInt16(values) : nil
        case .uint16:
            let values = strings.compactMap { UInt16($0) }
            return values.count == strings.count ? .listUInt16(values) : nil
        case .int32:
            let values = strings.compactMap { Int32($0) }
            return values.count == strings.count ? .listInt32(values) : nil
        case .uint32:
            let values = strings.compactMap { UInt32($0) }
            return values.count == strings.count ? .listUInt32(values) : nil
        case .float32:
            let values = strings.compactMap { Float($0) }
            return values.count == strings.count ? .listFloat32(values) : nil
        case .float64:
            let values = strings.compactMap { Double($0) }
            return values.count == strings.count ? .listFloat64(values) : nil
        }
    }

    static func tryDecodeASCIIList(valueType: PLYHeader.PrimitivePropertyType,
                                   count: Int,
                                   from stringParser: inout UnsafeStringParser,
                                   elementHeader: PLYHeader.Element,
                                   elementIndex: Int,
                                   propertyHeader: PLYHeader.Property) throws -> PLYElement.Property {
        do {
            switch valueType {
            case .int8:
                return .listInt8(try (0..<count).map { _ in try stringParser.assumeNextElementSeparatedByWhitespace() })
            case .uint8:
                return .listUInt8(try (0..<count).map { _ in try stringParser.assumeNextElementSeparatedByWhitespace() })
            case .int16:
                return .listInt16(try (0..<count).map { _ in try stringParser.assumeNextElementSeparatedByWhitespace() })
            case .uint16:
                return .listUInt16(try (0..<count).map { _ in try stringParser.assumeNextElementSeparatedByWhitespace() })
            case .int32:
                return .listInt32(try (0..<count).map { _ in try stringParser.assumeNextElementSeparatedByWhitespace() })
            case .uint32:
                return .listUInt32(try (0..<count).map { _ in try stringParser.assumeNextElementSeparatedByWhitespace() })
            case .float32:
                return .listFloat32(try (0..<count).map { _ in try stringParser.assumeNextElementSeparatedByWhitespace() })
            case .float64:
                return .listFloat64(try (0..<count).map { _ in try stringParser.assumeNextElementSeparatedByWhitespace() })
            }
        } catch UnsafeStringParser.Error.invalidFormat {
            throw PLYElement.ASCIIDecodeError.bodyInvalidStringForPropertyType(elementHeader, elementIndex, propertyHeader)
        } catch UnsafeStringParser.Error.unexpectedEndOfData {
            throw PLYElement.ASCIIDecodeError.bodyMissingPropertyValuesInElement(elementHeader, elementIndex, propertyHeader)
        }
    }
}

extension PLYElement: CustomStringConvertible {
    public var description: String {
        properties.map(\.description).joined(separator: " ")
    }
}

extension PLYElement.Property: CustomStringConvertible {
    public var description: String {
        if let listCount, listCount == 0 {
            return "0"
        }
        return switch self {
        case .int8(       let value ): "\(value)"
        case .uint8(      let value ): "\(value)"
        case .int16(      let value ): "\(value)"
        case .uint16(     let value ): "\(value)"
        case .int32(      let value ): "\(value)"
        case .uint32(     let value ): "\(value)"
        case .float32(    let value ): "\(value)"
        case .float64(    let value ): "\(value)"
        case .listInt8(   let values): "\(values.count) \(values.map(\.description).joined(separator: " "))"
        case .listUInt8(  let values): "\(values.count) \(values.map(\.description).joined(separator: " "))"
        case .listInt16(  let values): "\(values.count) \(values.map(\.description).joined(separator: " "))"
        case .listUInt16( let values): "\(values.count) \(values.map(\.description).joined(separator: " "))"
        case .listInt32(  let values): "\(values.count) \(values.map(\.description).joined(separator: " "))"
        case .listUInt32( let values): "\(values.count) \(values.map(\.description).joined(separator: " "))"
        case .listFloat32(let values): "\(values.count) \(values.map(\.description).joined(separator: " "))"
        case .listFloat64(let values): "\(values.count) \(values.map(\.description).joined(separator: " "))"
        }
    }
}

fileprivate struct UnsafeStringParser {
    enum Error: Swift.Error {
        case invalidFormat(String)
        case unexpectedEndOfData
    }

    var data: UnsafeMutablePointer<UInt8>
    var offset: Int
    var size: Int
    var currentPosition = 0

    mutating func nextStringSeparatedByWhitespace() -> String? {
        var start = currentPosition
        var end = start
        while true {
            if end == size {
                guard start < end else { return nil }
                let s = String(data: Data(bytes: data + offset + start, count: end - start), encoding: .utf8)
                currentPosition = size
                return s
            }

            let byte = (data + offset + end).pointee
            if byte == PLYReader.Constants.space || byte == 0 {
                if start == end {
                    // Starts with a space -- ignore it; strings may be separated by multiple spaces
                    end += 1
                    start = end
                } else {
                    // Temporarily make this into a null-terminated string for String()'s benefit
                    let oldEndValue = (data + offset + end).pointee
                    (data + offset + end).pointee = 0
                    let s = String(cString: data + offset + start)
                    (data + offset + end).pointee = oldEndValue
                    currentPosition = end+1
                    return s
                }
            } else {
                end += 1
            }
        }
    }

    mutating func nextElementSeparatedByWhitespace<T: LosslessStringConvertible>() throws -> T? {
        guard let s = nextStringSeparatedByWhitespace() else { return nil }
        guard let result = T(s) else {
            throw Error.invalidFormat(s)
        }
        return result
    }

    mutating func assumeNextElementSeparatedByWhitespace<T: LosslessStringConvertible>() throws -> T {
        guard let result: T = try nextElementSeparatedByWhitespace() else {
            throw Error.unexpectedEndOfData
        }
        return result
    }
}

fileprivate func min<T>(_ x: T?, _ y: T?) -> T? where T : Comparable {
    guard let x else { return y }
    guard let y else { return x }
    return min(x, y)
}
