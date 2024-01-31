import Foundation

public protocol PLYReaderDelegate {
    func didStartReading(withHeader header: PLYHeader)
    func didRead(element: PLYElement, typeIndex: Int, withHeader elementHeader: PLYHeader.Element)
    func didFinishReading()
    func didFailReading(withError error: Swift.Error?)
}

public class PLYReader {
    public enum Error: LocalizedError {
        case cannotOpenSource(URL)
        case readError(URL)
        case headerStartMissing
        case headerEndMissing
        case headerFormatMissing
        case headerInvalidCharacters
        case headerUnknownKeyword(String)
        case headerUnexpectedKeyword(String)
        case headerInvalidLine(String)
        case headerInvalidFileFormatType(String)
        case headerUnknownPropertyType(String)
        case headerInvalidListCountType(String)
        case bodyInvalidStringForPropertyType(PLYHeader.Element, Int, PLYHeader.Property)
        case bodyMissingPropertyValuesInElement(PLYHeader.Element, Int, PLYHeader.Property)
        case bodyUnexpectedValuesInElement(PLYHeader.Element, Int)
        case unexpectedEndOfFile(URL)
        case internalConsistency

        public var errorDescription: String? {
            switch self {
            case .cannotOpenSource(let url):
                "Cannot open source file at \(url)"
            case .readError(let url):
                "Error while reading \(url)"
            case .headerStartMissing:
                "Header start missing"
            case .headerEndMissing:
                "Header end missing"
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
            case .bodyInvalidStringForPropertyType(let headerElement, let elementIndex, let headerProperty):
                "Invalid type string for property \(headerProperty.name) in element \(headerElement.name), index \(elementIndex)"
            case .bodyMissingPropertyValuesInElement(let headerElement, let elementIndex, let headerProperty):
                "Missing values for property \(headerProperty.name) in element \(headerElement.name), index \(elementIndex)"
            case .bodyUnexpectedValuesInElement(let headerElement, let elementIndex):
                "Unexpected values in element \(headerElement.name), index \(elementIndex)"
            case .unexpectedEndOfFile(let url):
                "Unexpected end-of-file while reading \(url)"
            case .internalConsistency:
                "Internal error in PLYReader"
            }
        }
    }

    fileprivate enum Constants {
        static let headerStartToken = "\(HeaderKeyword.ply.rawValue)\n".data(using: .utf8)!
        static let headerEndToken = "\(HeaderKeyword.endHeader.rawValue)\n".data(using: .utf8)!
        // Hold up to 16k of data at once before reclaiming. Higher numbers will use more data, but lower numbers will result in more frequent, somewhat expensive "move bytes" operations.
        static let bodySizeForReclaim = 16*1024

        static let cr = UInt8(ascii: "\r")
        static let lf = UInt8(ascii: "\n")
        static let space = UInt8(ascii: " ")
        static let isLittleEndian = 14 == 14.littleEndian
    }

    fileprivate enum HeaderKeyword: String {
        case ply = "ply"
        case format = "format"
        case comment = "comment"
        case element = "element"
        case property = "property"
        case endHeader = "end_header"
    }

    let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    public func read(to delegate: PLYReaderDelegate) {
        PLYReaderStream().read(url, to: delegate)
    }
}

fileprivate class PLYReaderStream {
    private enum Phase {
        case unstarted
        case header
        case body
    }

    private var header: PLYHeader? = nil
    private var body = Data()
    private var bodyOffset: Int = 0
    private var currentElementGroup: Int = 0
    private var currentElementCountInGroup: Int = 0
    private var reusableElement = PLYElement(properties: [])

    public func read(_ url: URL, to delegate: PLYReaderDelegate) {
        header = nil
        body = Data()
        bodyOffset = 0
        currentElementGroup = 0
        currentElementCountInGroup = 0

        guard let inputStream = InputStream(url: url) else {
            delegate.didFailReading(withError: PLYReader.Error.cannotOpenSource(url))
            return
        }

        let bufferSize = 8*1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var headerData = Data()

        inputStream.open()
        defer { inputStream.close() }

        var phase: Phase = .unstarted

        while true {
            let readResult = inputStream.read(buffer, maxLength: bufferSize)
            let bytesRead: Int
            switch readResult {
            case -1:
                delegate.didFailReading(withError: PLYReader.Error.readError(url))
                return
            case 0:
                switch phase {
                case .unstarted, .header:
                    break
                case .body:
                    // Reprocess the remaining data, now with isEOF = true, since that might mean a successful completion (e.g. ASCII data missing a final EOL)
                    do {
                        try processBody(delegate: delegate, isEOF: true)
                    } catch {
                        delegate.didFailReading(withError: error)
                        return
                    }
                    if isComplete {
                        delegate.didFinishReading()
                        return
                    }
                }
                delegate.didFailReading(withError: PLYReader.Error.unexpectedEndOfFile(url))
                return
            default:
                bytesRead = readResult
            }

            var bufferIndex = 0
            while bufferIndex < bytesRead {
                switch phase {
                case .unstarted:
                    headerData.append(buffer[bufferIndex])
                    bufferIndex += 1
                    if headerData.count == PLYReader.Constants.headerStartToken.count {
                        if headerData == PLYReader.Constants.headerStartToken {
                            // Found header start token. Continue to read actual header
                            phase = .header
                        } else {
                            // Beginning of stream didn't match headerStartToken; fail
                            delegate.didFailReading(withError: PLYReader.Error.headerStartMissing)
                            return
                        }
                    }
                case .header:
                    headerData.append(buffer[bufferIndex])
                    bufferIndex += 1
                    if headerData.hasSuffix(PLYReader.Constants.headerEndToken) {
                        do {
                            let header = try parseHeader(headerData)
                            self.header = header
                            phase = .body
                            delegate.didStartReading(withHeader: header)
                        } catch {
                            delegate.didFailReading(withError: error)
                            return
                        }
                    }
                case .body:
                    if bufferIndex == 0 {
                        body.append(buffer, count: bytesRead)
                    } else if bufferIndex < bytesRead {
                        body.append(Data(bytes: buffer, count: bytesRead)[bufferIndex..<bytesRead])
                    }
                    bufferIndex = bytesRead
                    do {
                        try processBody(delegate: delegate, isEOF: false)
                    } catch {
                        delegate.didFailReading(withError: error)
                        return
                    }
                    if isComplete {
                        delegate.didFinishReading()
                        return
                    }
                    reclaimBodyIfNeeded()
                }
            }
        }
    }

    private var isComplete: Bool {
        guard let header else { return false }
        return currentElementGroup == header.elements.count
    }

    // Maybe remove already-processed bytes from body, to reclaim memory
    private func reclaimBodyIfNeeded() {
        // Removing bytes is an O(N) operation, where N = number of remaining bytes. Fortunately we only reset
        // when we've already consumed as many bytes as we can, so there are < 1 element's worth of bytes remaining
        guard bodyOffset > 0 && body.count >= PLYReader.Constants.bodySizeForReclaim else { return }
        body.removeSubrange(0..<bodyOffset)
        bodyOffset = body.startIndex
    }

    private func parseHeader(_ headerData: Data) throws -> PLYHeader {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw PLYReader.Error.headerInvalidCharacters
        }
        var parseError: Swift.Error?
        var header: PLYHeader?
        headerString.enumerateLines { (headerLine, stop: inout Bool) in
            do {
                guard let keywordString = headerLine.components(separatedBy: .whitespaces).filter({ !$0.isEmpty }).first else {
                    return
                }
                guard let keyword = PLYReader.HeaderKeyword(rawValue: keywordString) else {
                    throw PLYReader.Error.headerUnknownKeyword(keywordString)
                }
                switch keyword {
                case .ply, .comment:
                    return
                case .format:
                    guard header == nil else {
                        throw PLYReader.Error.headerUnexpectedKeyword(keyword.rawValue)
                    }
                    let regex = #/\s*format\s+(?<format>\w+?)\s+(?<version>\S+?)/#
                    guard let match = try regex.wholeMatch(in: headerLine) else {
                        throw PLYReader.Error.headerInvalidLine(headerLine)
                    }
                    guard let format = PLYHeader.Format(rawValue: String(match.format)) else {
                        throw PLYReader.Error.headerInvalidFileFormatType(String(match.format))
                    }
                    header = PLYHeader(format: format, version: String(match.version), elements: [])
                case .element:
                    guard header != nil else {
                        throw PLYReader.Error.headerUnexpectedKeyword(keyword.rawValue)
                    }
                    let regex = #/\s*element\s+(?<name>\S+?)\s+(?<count>\d+?)/#
                    guard let match = try regex.wholeMatch(in: headerLine) else {
                        throw PLYReader.Error.headerInvalidLine(headerLine)
                    }
                    header?.elements.append(PLYHeader.Element(name: String(match.name),
                                                              count: UInt32(match.count)!,
                                                              properties: []))
                case .property:
                    guard header != nil, header?.elements.isEmpty == false else {
                        throw PLYReader.Error.headerUnexpectedKeyword(keyword.rawValue)
                    }
                    let listRegex = #/\s*property\s+list\s+(?<countType>\w+?)\s+(?<valueType>\w+?)\s+(?<name>\S+)/#
                    let nonListRegex = #/\s*property\s+(?<valueType>\w+?)\s+(?<name>\S+)/#
                    if let match = try listRegex.wholeMatch(in: headerLine) {
                        guard let countType = PLYHeader.PrimitivePropertyType.fromString(String(match.countType)) else {
                            throw PLYReader.Error.headerUnknownPropertyType(String(match.countType))
                        }
                        guard countType.isInteger else {
                            throw PLYReader.Error.headerInvalidListCountType(String(match.countType))
                        }
                        guard let valueType = PLYHeader.PrimitivePropertyType.fromString(String(match.valueType)) else {
                            throw PLYReader.Error.headerUnknownPropertyType(String(match.valueType))
                        }
                        let property = PLYHeader.Property(name: String(match.name),
                                                          type: .list(countType: countType, valueType: valueType))
                        header!.elements[header!.elements.count-1].properties.append(property)
                    } else if let match = try nonListRegex.wholeMatch(in: headerLine) {
                        guard let valueType = PLYHeader.PrimitivePropertyType.fromString(String(match.valueType)) else {
                            throw PLYReader.Error.headerUnknownPropertyType(String(match.valueType))
                        }
                        let property = PLYHeader.Property(name: String(match.name),
                                                          type: .primitive(valueType))
                        header!.elements[header!.elements.count-1].properties.append(property)
                    } else {
                        throw PLYReader.Error.headerInvalidLine(headerLine)
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
            throw PLYReader.Error.headerFormatMissing
        }

        return header
    }

    private func processBody(delegate: PLYReaderDelegate,
                             isEOF: Bool) throws {
        guard let header else {
            throw PLYReader.Error.internalConsistency
        }

        switch header.format {
        case .ascii:
            try body[bodyOffset...].withUnsafeMutableBytes { (bodyUnsafeRawBufferPointer: UnsafeMutableRawBufferPointer) in
                let bodyUnsafeBytePointer = bodyUnsafeRawBufferPointer.bindMemory(to: UInt8.self).baseAddress!
                var bodyUnsafeBytePointerOffset = 0
                let bodyUnsafeBytePointerCount = bodyUnsafeRawBufferPointer.count
                while !isComplete {
                    let elementHeader = header.elements[self.currentElementGroup]

                    let lineStart = bodyUnsafeBytePointerOffset
                    var firstNewlineIndex = lineStart
                    var newlineFound = false
                    while !newlineFound && firstNewlineIndex < bodyUnsafeBytePointerCount {
                        let byte = (bodyUnsafeBytePointer + firstNewlineIndex).pointee
                        newlineFound = byte == PLYReader.Constants.cr || byte == PLYReader.Constants.lf
                        if !newlineFound {
                            firstNewlineIndex += 1
                        }
                    }

                    let lineLength = firstNewlineIndex - lineStart
                    if firstNewlineIndex < bodyUnsafeBytePointerCount {
                        bodyUnsafeBytePointerOffset = firstNewlineIndex + 1
                    } else if isEOF {
                        bodyUnsafeBytePointerOffset = bodyUnsafeBytePointerCount
                    } else {
                        return
                    }

                    bodyOffset += (bodyUnsafeBytePointerOffset - lineStart)

                    if lineLength == 0 {
                        continue
                    }

                    let success = try Self.processASCIIBodyElement(bodyUnsafeBytePointer,
                                                                   offset: lineStart,
                                                                   size: lineLength,
                                                                   withHeader: elementHeader,
                                                                   elementIndex: currentElementGroup,
                                                                   result: &reusableElement)
                    guard success else { continue }

                    delegate.didRead(element: reusableElement, typeIndex: self.currentElementGroup, withHeader: elementHeader)
                    currentElementCountInGroup += 1
                    while !isComplete && currentElementCountInGroup == header.elements[currentElementGroup].count {
                        currentElementGroup += 1
                        currentElementCountInGroup = 0
                    }
                }
            }
        case .binaryBigEndian, .binaryLittleEndian:
            try body[bodyOffset...].withUnsafeBytes { (bodyUnsafeRawBufferPointer: UnsafeRawBufferPointer) in
                let bodyUnsafeRawPointer = bodyUnsafeRawBufferPointer.baseAddress!
                var bodyUnsafeRawPointerOffset = 0
                while !isComplete {
                    let elementHeader = header.elements[self.currentElementGroup]

                    let (success, bytesConsumed) = try Self.processBinaryBodyElement(bodyUnsafeRawPointer,
                                                                                     offset: bodyUnsafeRawPointerOffset,
                                                                                     size: bodyUnsafeRawBufferPointer.count - bodyUnsafeRawPointerOffset,
                                                                                     bigEndian: header.format == .binaryBigEndian,
                                                                                     withHeader: elementHeader,
                                                                                     result: &reusableElement)
                    guard success else { return }
                    assert(bytesConsumed != 0, "processBinaryBodyElement consumed at least one byte in producing the PLYElement")
                    bodyOffset += bytesConsumed
                    bodyUnsafeRawPointerOffset += bytesConsumed

                    delegate.didRead(element: reusableElement, typeIndex: currentElementGroup, withHeader: elementHeader)
                    currentElementCountInGroup += 1
                    while !isComplete && currentElementCountInGroup == header.elements[currentElementGroup].count {
                        currentElementGroup += 1
                        currentElementCountInGroup = 0
                    }
                }
            }
        }
    }

    private static func tryParsePrimitivePropertyValue(_ propertyString: String, withType propertyType: PLYHeader.PrimitivePropertyType) -> PLYElement.Property? {
        switch propertyType {
        case .int8   : if let value = Int8(  propertyString) { .int8(   value) } else { nil }
        case .uint8  : if let value = UInt8( propertyString) { .uint8(  value) } else { nil }
        case .int16  : if let value = Int16( propertyString) { .int16(  value) } else { nil }
        case .uint16 : if let value = UInt16(propertyString) { .uint16( value) } else { nil }
        case .int32  : if let value = Int32( propertyString) { .int32(  value) } else { nil }
        case .uint32 : if let value = UInt32(propertyString) { .uint32( value) } else { nil }
        case .float32: if let value = Float( propertyString) { .float32(value) } else { nil }
        case .float64: if let value = Double(propertyString) { .float64(value) } else { nil }
        }
    }

    private static func tryParseListPropertyValue(_ propertyStrings: [String], withValueType propertyValueType: PLYHeader.PrimitivePropertyType) -> PLYElement.Property? {
        switch propertyValueType {
        case .int8:
            let values = propertyStrings.compactMap { Int8($0) }
            return values.count == propertyStrings.count ? .listInt8(values) : nil
        case .uint8:
            let values = propertyStrings.compactMap { UInt8($0) }
            return values.count == propertyStrings.count ? .listUInt8(values) : nil
        case .int16:
            let values = propertyStrings.compactMap { Int16($0) }
            return values.count == propertyStrings.count ? .listInt16(values) : nil
        case .uint16:
            let values = propertyStrings.compactMap { UInt16($0) }
            return values.count == propertyStrings.count ? .listUInt16(values) : nil
        case .int32:
            let values = propertyStrings.compactMap { Int32($0) }
            return values.count == propertyStrings.count ? .listInt32(values) : nil
        case .uint32:
            let values = propertyStrings.compactMap { UInt32($0) }
            return values.count == propertyStrings.count ? .listUInt32(values) : nil
        case .float32:
            let values = propertyStrings.compactMap { Float($0) }
            return values.count == propertyStrings.count ? .listFloat32(values) : nil
        case .float64:
            let values = propertyStrings.compactMap { Double($0) }
            return values.count == propertyStrings.count ? .listFloat64(values) : nil
        }
    }

    private static func parseListPropertyValue(_ propertyStrings: inout UnsafeStringParser,
                                               count: Int,
                                               withValueType propertyValueType: PLYHeader.PrimitivePropertyType,
                                               elementHeader: PLYHeader.Element,
                                               elementIndex: Int,
                                               propertyHeader: PLYHeader.Property) throws -> PLYElement.Property {
        do {
            switch propertyValueType {
            case .int8:
                return .listInt8(try (0..<count).map { _ in try propertyStrings.assumeNextElementSeparatedByWhitespace() })
            case .uint8:
                return .listUInt8(try (0..<count).map { _ in try propertyStrings.assumeNextElementSeparatedByWhitespace() })
            case .int16:
                return .listInt16(try (0..<count).map { _ in try propertyStrings.assumeNextElementSeparatedByWhitespace() })
            case .uint16:
                return .listUInt16(try (0..<count).map { _ in try propertyStrings.assumeNextElementSeparatedByWhitespace() })
            case .int32:
                return .listInt32(try (0..<count).map { _ in try propertyStrings.assumeNextElementSeparatedByWhitespace() })
            case .uint32:
                return .listUInt32(try (0..<count).map { _ in try propertyStrings.assumeNextElementSeparatedByWhitespace() })
            case .float32:
                return .listFloat32(try (0..<count).map { _ in try propertyStrings.assumeNextElementSeparatedByWhitespace() })
            case .float64:
                return .listFloat64(try (0..<count).map { _ in try propertyStrings.assumeNextElementSeparatedByWhitespace() })
            }
        } catch UnsafeStringParser.Error.invalidFormat {
            throw PLYReader.Error.bodyInvalidStringForPropertyType(elementHeader, elementIndex, propertyHeader)
        } catch UnsafeStringParser.Error.unexpectedEndOfData {
            throw PLYReader.Error.bodyMissingPropertyValuesInElement(elementHeader, elementIndex, propertyHeader)
        }
    }

    // Parse the given element type from the single line from the body of an ASCII PLY file.
    // Considers only bytes from offset..<(offset+size)
    // May modify the body; after this returns, the body contents are undefined.
    private static func processASCIIBodyElement(_ body: UnsafeMutablePointer<UInt8>,
                                                offset: Int,
                                                size: Int,
                                                withHeader elementHeader: PLYHeader.Element,
                                                elementIndex: Int,
                                                result: inout PLYElement) throws -> Bool {
        var stringParser = UnsafeStringParser(data: body, offset: offset, size: size)

        if result.properties.count != elementHeader.properties.count {
            result.properties = Array(repeating: .uint8(0), count: elementHeader.properties.count)
        }
        for (i, propertyHeader) in elementHeader.properties.enumerated() {
            switch propertyHeader.type {
            case .primitive(let primitiveType):
                guard let string = stringParser.nextStringSeparatedByWhitespace() else {
                    throw PLYReader.Error.bodyMissingPropertyValuesInElement(elementHeader, elementIndex, propertyHeader)
                }
                guard let value = tryParsePrimitivePropertyValue(string, withType: primitiveType) else {
                    throw PLYReader.Error.bodyInvalidStringForPropertyType(elementHeader, elementIndex, propertyHeader)
                }
                result.properties[i] = value
            case .list(countType: let countType, valueType: let valueType):
                guard let countString = stringParser.nextStringSeparatedByWhitespace() else {
                    throw PLYReader.Error.bodyMissingPropertyValuesInElement(elementHeader, elementIndex, propertyHeader)
                }
                guard let count = tryParsePrimitivePropertyValue(countString, withType: countType)?.uint64Value else {
                    throw PLYReader.Error.bodyInvalidStringForPropertyType(elementHeader, elementIndex, propertyHeader)
                }

                result.properties[i] = try parseListPropertyValue(&stringParser, count: Int(count), withValueType: valueType,
                                                                  elementHeader: elementHeader, elementIndex: elementIndex, propertyHeader: propertyHeader)
            }
        }
        guard stringParser.nextStringSeparatedByWhitespace() == nil else {
            throw PLYReader.Error.bodyUnexpectedValuesInElement(elementHeader, elementIndex)
        }

        return true
    }

    // Parse the given element type from the next bytes in the body of a binary PLY file.
    // The provided element is assumed to have the correct number of properties.
    // If sufficient bytes are available, updates the given result and returns success:true and a nonzero number of bytes consumed.
    // Otherwise if insufficient bytes are available, return success:false.
    private static func processBinaryBodyElement(_ body: UnsafeRawPointer,
                                                 offset: Int,
                                                 size: Int,
                                                 bigEndian: Bool,
                                                 withHeader elementHeader: PLYHeader.Element,
                                                 result: inout PLYElement) throws -> (success: Bool, bytesConsumed: Int) {
        if result.properties.count != elementHeader.properties.count {
            result.properties = Array(repeating: .uint8(0), count: elementHeader.properties.count)
        }
        var offset = offset
        let originalOffset = offset
        for (i, propertyHeader) in elementHeader.properties.enumerated() {
            let remainingBytes = size - (offset - originalOffset)
            switch propertyHeader.type {
            case .primitive(let primitiveType):
                guard remainingBytes >= primitiveType.byteWidth else {
                    return (success: false, bytesConsumed: 0)
                }
                let value = primitiveType.decodePrimitive(body, offset: offset, bigEndian: bigEndian)
                result.properties[i] = value
                offset += primitiveType.byteWidth
            case .list(countType: let countType, valueType: let valueType):
                guard remainingBytes >= countType.byteWidth else {
                    return (success: false, bytesConsumed: 0)
                }
                let count = Int(countType.decodePrimitive(body, offset: offset, bigEndian: bigEndian).uint64Value!)
                guard remainingBytes >= countType.byteWidth + count * valueType.byteWidth else {
                    return (success: false, bytesConsumed: 0)
                }

                offset += countType.byteWidth
                let value = valueType.decodeList(body, offset: offset, count: count, bigEndian: bigEndian)
                result.properties[i] = value
                offset += count * valueType.byteWidth
            }
        }
        return (success: true, bytesConsumed: offset - originalOffset)
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

            if (data + offset + end).pointee == PLYReader.Constants.space {
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

fileprivate extension Data {
    func hasSuffix(_ data: Data) -> Bool {
        count >= data.count && self[(count - data.count)...] == data
    }
}

fileprivate func min<T>(_ x: T?, _ y: T?) -> T? where T : Comparable {
    guard let x else { return y }
    guard let y else { return x }
    return min(x, y)
}
