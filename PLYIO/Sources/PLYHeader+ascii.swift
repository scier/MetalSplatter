import Foundation

extension PLYHeader {
    public enum ASCIIDecodeError: LocalizedError {
        case headerFormatMissing
        case headerInvalidCharacters
        case headerUnknownKeyword(String)
        case headerUnexpectedKeyword(String)
        case headerInvalidLine(String)
        case headerInvalidFileFormatType(String)
        case headerUnknownPropertyType(String)
        case headerInvalidListCountType(String)

        public var errorDescription: String? {
            switch self {
            case .headerFormatMissing:
                "Header format missing"
            case .headerInvalidCharacters:
                "Invalid characters in header"
            case .headerUnknownKeyword(let keyword):
                "Unknown keyword in header: \"\(keyword)\""
            case .headerUnexpectedKeyword(let keyword):
                "Unexpected keyword in header: \"\(keyword)\""
            case .headerInvalidLine(let line):
                "Invalid line in header: \"\(line)\""
            case .headerInvalidFileFormatType(let type):
                "Invalid file format type in header: \(type)"
            case .headerUnknownPropertyType(let type):
                "Unknown property type: \(type)"
            case .headerInvalidListCountType(let type):
                "Invalid list count type: \(type)"
            }
        }
    }

    static func decodeASCII(from headerData: Data) throws -> PLYHeader {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw ASCIIDecodeError.headerInvalidCharacters
        }
        var parseError: Swift.Error?
        var header: PLYHeader?
        headerString.enumerateLines { (headerLine, stop: inout Bool) in
            do {
                guard let keywordString = headerLine.components(separatedBy: .whitespaces).filter({ !$0.isEmpty }).first else {
                    return
                }
                guard let keyword = PLYHeader.Keyword(rawValue: keywordString) else {
                    throw ASCIIDecodeError.headerUnknownKeyword(keywordString)
                }
                switch keyword {
                case .ply, .comment, .obj_info:
                    return
                case .format:
                    guard header == nil else {
                        throw ASCIIDecodeError.headerUnexpectedKeyword(keyword.rawValue)
                    }
                    let regex = #/\s*format\s+(?<format>\w+?)\s+(?<version>\S+?)/#
                    guard let match = try regex.wholeMatch(in: headerLine) else {
                        throw ASCIIDecodeError.headerInvalidLine(headerLine)
                    }
                    guard let format = PLYHeader.Format(rawValue: String(match.format)) else {
                        throw ASCIIDecodeError.headerInvalidFileFormatType(String(match.format))
                    }
                    header = PLYHeader(format: format, version: String(match.version), elements: [])
                case .element:
                    guard header != nil else {
                        throw ASCIIDecodeError.headerUnexpectedKeyword(keyword.rawValue)
                    }
                    let regex = #/\s*element\s+(?<name>\S+?)\s+(?<count>\d+?)/#
                    guard let match = try regex.wholeMatch(in: headerLine) else {
                        throw ASCIIDecodeError.headerInvalidLine(headerLine)
                    }
                    header?.elements.append(PLYHeader.Element(name: String(match.name),
                                                              count: UInt32(match.count)!,
                                                              properties: []))
                case .property:
                    guard header != nil, header?.elements.isEmpty == false else {
                        throw ASCIIDecodeError.headerUnexpectedKeyword(keyword.rawValue)
                    }
                    let listRegex = #/\s*property\s+list\s+(?<countType>\w+?)\s+(?<valueType>\w+?)\s+(?<name>\S+)/#
                    let nonListRegex = #/\s*property\s+(?<valueType>\w+?)\s+(?<name>\S+)/#
                    if let match = try listRegex.wholeMatch(in: headerLine) {
                        guard let countType = PLYHeader.PrimitivePropertyType.fromString(String(match.countType)) else {
                            throw ASCIIDecodeError.headerUnknownPropertyType(String(match.countType))
                        }
                        guard countType.isInteger else {
                            throw ASCIIDecodeError.headerInvalidListCountType(String(match.countType))
                        }
                        guard let valueType = PLYHeader.PrimitivePropertyType.fromString(String(match.valueType)) else {
                            throw ASCIIDecodeError.headerUnknownPropertyType(String(match.valueType))
                        }
                        let property = PLYHeader.Property(name: String(match.name),
                                                          type: .list(countType: countType, valueType: valueType))
                        header!.elements[header!.elements.count-1].properties.append(property)
                    } else if let match = try nonListRegex.wholeMatch(in: headerLine) {
                        guard let valueType = PLYHeader.PrimitivePropertyType.fromString(String(match.valueType)) else {
                            throw ASCIIDecodeError.headerUnknownPropertyType(String(match.valueType))
                        }
                        let property = PLYHeader.Property(name: String(match.name),
                                                          type: .primitive(valueType))
                        header!.elements[header!.elements.count-1].properties.append(property)
                    } else {
                        throw ASCIIDecodeError.headerInvalidLine(headerLine)
                    }
                case .endHeader:
                    stop = true
                }
            } catch {
                parseError = error
                stop = true
            }
        }

        if let parseError {
            throw parseError
        }

        guard let header else {
            throw ASCIIDecodeError.headerFormatMissing
        }

        return header
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
        case .list(let countType, let valueType): "list \(countType) \(valueType)"
        }
    }
}

extension PLYHeader.PrimitivePropertyType: CustomStringConvertible {
    static func fromString(_ string: String) -> PLYHeader.PrimitivePropertyType? {
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
