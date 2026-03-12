import Foundation
import os

struct AsyncLineIterator: AsyncIteratorProtocol {
    let iterator: AsyncBufferingInputStream.Iterator
    private var buffer = Data()

    init(_ iterator: AsyncBufferingInputStream.Iterator) {
        self.iterator = iterator
    }

    mutating func next() async throws -> String? {
        while true {
            guard let bodyData = try await iterator.next() else {
                // EOF: yield any remaining buffer as last line
                if !buffer.isEmpty {
                    defer { buffer.removeAll() }
                    return String(data: buffer, encoding: .utf8)
                }
                return nil
            }

            for (index, byte) in bodyData.enumerated() {
                if byte == UInt8(ascii: "\n") {
                    defer { buffer.removeAll() }
                    await iterator.pushback(bodyData.advanced(by: index + 1))
                    return String(data: buffer, encoding: .utf8)
                } else {
                    buffer.append(byte)
                }
            }
        }
    }
}

public class PLYReader {
    public struct ElementSeries: Sendable {
        public var elements: [PLYElement]
        public var typeIndex: Int
        public var elementHeader: PLYHeader.Element
    }

    public enum Error: LocalizedError {
        case readError
        case headerStartMissing
        case headerEndMissing
        case unexpectedEndOfFile
        case unexpectedContentAtEndOfBody
        case internalConsistency

        public var errorDescription: String? {
            switch self {
            case .readError:
                "Error while reading input"
            case .headerStartMissing:
                "Header start missing"
            case .headerEndMissing:
                "Header end missing"
            case .unexpectedEndOfFile:
                "Unexpected end-of-file while reading input"
            case .unexpectedContentAtEndOfBody:
                "Unexpected content past end of expected body"
            case .internalConsistency:
                "Internal error in PLYReader"
            }
        }
    }

    static let log = Logger(subsystem: "com.PLYIO", category: "PLYReader")

    enum Constants {
        static let headerStartToken = "\(PLYHeader.Keyword.ply.rawValue)\n".data(using: .utf8)!
        static let headerEndToken = "\(PLYHeader.Keyword.endHeader.rawValue)\n".data(using: .utf8)!
        static let headerMaxLen = 256*1024 // A header longer than 256kB is... unlikely
        static let bodyBufferLen = 16*1024
        static let asciiBufferElementCount = 1024
    }

    private let source: ReaderSource

    public init(_ source: ReaderSource) {
        self.source = source
    }

    public convenience init(_ url: URL) throws {
        guard url.isFileURL else {
            throw ReaderSource.Error.cannotOpen(url: url)
        }
        self.init(ReaderSource.url(url))
    }

    public convenience init(_ data: Data) throws {
        self.init(ReaderSource.memory(data))
    }

    public func read() async throws -> (header: PLYHeader, elements: AsyncThrowingStream<ElementSeries, Swift.Error>) {
        Self.log.debug("Starting PLY read")
        let byteStream = AsyncBufferingInputStream(try source.inputStream(),
                                                   bufferSize: Constants.bodyBufferLen)
        let iterator = byteStream.makeAsyncIterator()

        let preHeaderData = try await readData(from: iterator, until: Constants.headerStartToken, maxLength: 0)
        guard preHeaderData != nil else {
            Self.log.error("PLY header start token not found")
            throw Error.headerStartMissing
        }
        let headerData = try await readData(from: iterator, until: Constants.headerEndToken, maxLength: Constants.headerMaxLen)
        guard let headerData else {
            Self.log.error("PLY header end token not found (header data exceeded \(Constants.headerMaxLen) bytes or EOF)")
            throw Error.headerEndMissing
        }
        Self.log.debug("PLY header data: \(headerData.count) bytes")
        let header = try PLYHeader.decodeASCII(from: headerData)

        let totalElements = header.elements.reduce(0) { $0 + Int($1.count) }
        Self.log.info("PLY header parsed: format=\(header.format.rawValue, privacy: .public), version=\(header.version, privacy: .public), \(header.elements.count) element type(s), \(totalElements) total element(s)")
        for element in header.elements {
            Self.log.info("  element \"\(element.name, privacy: .public)\": \(element.count) instance(s), \(element.properties.count) propert(ies)")
            for property in element.properties {
                Self.log.debug("    property \"\(property.name, privacy: .public)\": \(String(describing: property.type), privacy: .public)")
            }
        }

        let elements: AsyncThrowingStream<ElementSeries, Swift.Error> =
        switch header.format {
        case .ascii:
            processASCIIBody(header: header, iterator: iterator)
        case .binaryBigEndian:
            processBinaryBody(header: header, iterator: iterator, bigEndian: true)
        case .binaryLittleEndian:
            processBinaryBody(header: header, iterator: iterator, bigEndian: false)
        }

        return (header: header, elements: elements)
    }

    /// Reads bytes until the endToken is found, and returns the resulting Data (which does not include the bytes in endToken).
    /// The resulting Data will contain up to maxLength bytes; if maxLength + endToken.count bytes have been read and
    /// endToken has not been found, or no more bytes are available, returns nil.
    private func readData(from iterator: AsyncBufferingInputStream.Iterator, until endToken: Data, consumeToken: Bool = true, maxLength: Int) async throws -> Data? {
        var buffer = Data()
        let tokenLen = endToken.count
        let maxAllowed = maxLength + tokenLen
        while let bytes = try await iterator.next() {
            for (index, byte) in bytes.enumerated() {
                buffer.append(byte)
                // Check if the buffer ends with the endToken
                if buffer.count >= tokenLen && buffer.suffix(tokenLen) == endToken {
                    // Push back the unused data
                    let startPushbackIndex = consumeToken ? (index+1) : (index+1 - tokenLen)
                    await iterator.pushback(bytes.advanced(by: startPushbackIndex))
                    // Return data minus the token
                    return buffer.dropLast(tokenLen)
                }
                // If we exceed the allowed length, abort
                if buffer.count >= maxAllowed {
                    return nil
                }
            }
        }

        // We hit EOF without finding the token
        return nil
    }

    private func processASCIIBody(header: PLYHeader, iterator: sending AsyncBufferingInputStream.Iterator) -> AsyncThrowingStream<ElementSeries, Swift.Error> {
        // Move iterator into local var to transfer ownership to the closure
        let iterator = iterator
        return AsyncThrowingStream { continuation in
            Task { [iterator] in
                guard header.elements.count > 0 else {
                    Self.log.debug("ASCII body: no element types defined, finishing")
                    continuation.finish()
                    return
                }

                Self.log.debug("ASCII body: beginning element parsing")
                var currentElementGroup = 0
                var currentElementCountInGroup = 0
                var totalElementsDecoded = 0

                var bufferedElements: [PLYElement] = Array(repeating: PLYElement(properties: []),
                                                           count: Constants.asciiBufferElementCount)
                var bufferedElementCount = 0

                var lines = AsyncLineIterator(iterator)
                do {
                    while let line = try await lines.next() {
                        guard currentElementGroup < header.elements.count else {
                            if line.isEmpty {
                                continue
                            }
                            Self.log.error("ASCII body: unexpected content after all \(totalElementsDecoded) element(s) decoded")
                            continuation.finish(throwing: Error.unexpectedContentAtEndOfBody)
                            return
                        }

                        let elementHeader = header.elements[currentElementGroup]

                        try bufferedElements[bufferedElementCount].decodeASCII(type: elementHeader,
                                                                               fromBody: line,
                                                                               elementIndex: currentElementGroup)
                        bufferedElementCount += 1
                        totalElementsDecoded += 1

                        if bufferedElementCount == bufferedElements.count {
                            let elementSeries = ElementSeries(elements: bufferedElements,
                                                              typeIndex: currentElementGroup,
                                                              elementHeader: elementHeader)
                            continuation.yield(elementSeries)
                            Self.log.debug("ASCII body: yielded batch of \(bufferedElementCount) \"\(elementHeader.name, privacy: .public)\" element(s) (\(totalElementsDecoded) total)")
                            bufferedElementCount = 0
                        }

                        currentElementCountInGroup += 1
                        while currentElementGroup < header.elements.count
                                && currentElementCountInGroup == header.elements[currentElementGroup].count {
                            if bufferedElementCount != 0 {
                                let elementSeries = ElementSeries(elements: Array(bufferedElements[0..<bufferedElementCount]),
                                                                  typeIndex: currentElementGroup,
                                                                  elementHeader: elementHeader)
                                continuation.yield(elementSeries)
                                Self.log.debug("ASCII body: yielded final batch of \(bufferedElementCount) \"\(elementHeader.name, privacy: .public)\" element(s) (\(totalElementsDecoded) total)")
                                bufferedElementCount = 0
                            }

                            Self.log.debug("ASCII body: completed element type \"\(header.elements[currentElementGroup].name, privacy: .public)\" (\(currentElementCountInGroup)/\(header.elements[currentElementGroup].count))")
                            currentElementGroup += 1
                            currentElementCountInGroup = 0
                        }
                    }

                    Self.log.info("ASCII body: finished, \(totalElementsDecoded) element(s) decoded across \(currentElementGroup) type(s)")
                    continuation.finish()
                } catch {
                    Self.log.error("ASCII body: error after \(totalElementsDecoded) element(s): \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func processBinaryBody(header: PLYHeader, iterator: sending AsyncBufferingInputStream.Iterator, bigEndian: Bool) -> AsyncThrowingStream<ElementSeries, Swift.Error> {
        // Move iterator into local var to transfer ownership to the closure
        let iterator = iterator
        return AsyncThrowingStream { continuation in
            Task {
                guard header.elements.count > 0 else {
                    Self.log.debug("Binary body: no element types defined, finishing")
                    continuation.finish()
                    return
                }

                Self.log.debug("Binary body: beginning element parsing (bigEndian=\(bigEndian))")
                let iterator = iterator  // Copy captured iterator for use in async loop
                var currentElementGroup = 0
                var currentElementCountInGroup = 0
                var currentElementHeader = header.elements[currentElementGroup]
                var totalElementsDecoded = 0
                var totalBytesRead = 0

                var bufferOffset: Int = 0
                var bufferSize: Int = 0
                var targetBufferSize = Constants.bodyBufferLen
                var bufferCapacity = Constants.bodyBufferLen
                var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferCapacity)
                defer { buffer.deallocate() }

                var elementsInBuffer: [PLYElement] = []

                do {
                    func processBuffer() throws {
                        var elementCountInBuffer = 0
                        while bufferOffset < bufferSize {
                            guard currentElementGroup < header.elements.count else {
                                Self.log.error("Binary body: unexpected content after all element types consumed (\(totalElementsDecoded) element(s), \(totalBytesRead) bytes read)")
                                throw Error.unexpectedContentAtEndOfBody
                            }

                            if elementsInBuffer.count == elementCountInBuffer {
                                elementsInBuffer.append(PLYElement(properties: []))
                            }

                            guard let bytesConsumed =
                                    try elementsInBuffer[elementCountInBuffer].tryDecodeBinary(type: currentElementHeader,
                                                                                               from: buffer,
                                                                                               at: bufferOffset,
                                                                                               bodySize: bufferSize - bufferOffset,
                                                                                               bigEndian: bigEndian)
                            else {
                                // Insufficient data available for a single new element
                                let elementSeries = ElementSeries(elements: Array(elementsInBuffer.prefix(elementCountInBuffer)),
                                                                  typeIndex: currentElementGroup,
                                                                  elementHeader: currentElementHeader)
                                continuation.yield(elementSeries)
                                Self.log.debug("Binary body: yielded partial batch of \(elementCountInBuffer) element(s), waiting for more data (buffer has \(bufferSize - bufferOffset) unconsumed bytes)")
                                return
                            }
                            assert(bytesConsumed != 0, "PLYElement.tryDecodeBinary consumed at least one byte in producing the PLYElement")
                            bufferOffset += bytesConsumed
                            elementCountInBuffer += 1
                            totalElementsDecoded += 1

                            currentElementCountInGroup += 1
                            while currentElementGroup < header.elements.count
                                    && ((currentElementCountInGroup == header.elements[currentElementGroup].count)
                                        || (elementCountInBuffer != 0 && bufferOffset == bufferSize)) {
                                // Dump the current buffer because either we've finished the current group, *or* we're at the end of the buffer
                                if elementCountInBuffer != 0 {
                                    let elementSeries = ElementSeries(elements: Array(elementsInBuffer.prefix(elementCountInBuffer)),
                                                                      typeIndex: currentElementGroup,
                                                                      elementHeader: currentElementHeader)
                                    continuation.yield(elementSeries)
                                    Self.log.debug("Binary body: yielded batch of \(elementCountInBuffer) \"\(currentElementHeader.name, privacy: .public)\" element(s) (\(totalElementsDecoded) total)")
                                    elementCountInBuffer = 0
                                }

                                if currentElementCountInGroup == header.elements[currentElementGroup].count {
                                    Self.log.debug("Binary body: completed element type \"\(header.elements[currentElementGroup].name, privacy: .public)\" (\(currentElementCountInGroup)/\(header.elements[currentElementGroup].count))")
                                    currentElementGroup += 1
                                    currentElementCountInGroup = 0
                                    if currentElementGroup < header.elements.count {
                                        currentElementHeader = header.elements[currentElementGroup]
                                    }
                                }
                            }
                        }
                    }

                    do {
                        while let bodyData = try await iterator.next() {
                            Self.append(to: &buffer, withCapacity: &bufferCapacity, from: bufferSize, data: bodyData)
                            bufferSize += bodyData.count
                            totalBytesRead += bodyData.count
                            guard bufferSize >= targetBufferSize else {
                                continue
                            }

                            try processBuffer()

                            if bufferOffset == 0 {
                                // Buffer contents exist, but no elements were processed. This might mean the bufferCapacity was
                                // actually too small to contain even a single element. If we don't want to crash (by reading past
                                // the end of the buffer), we'd better make room
                                Self.log.debug("Binary body: growing buffer from \(bufferCapacity) to \(targetBufferSize * 2) bytes (no elements fit in current buffer)")
                                targetBufferSize *= 2
                                if targetBufferSize > bufferCapacity {
                                    let newCapacity = targetBufferSize
                                    let newBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
                                    memcpy(newBuffer, buffer, bufferSize)
                                    buffer.deallocate()
                                    buffer = newBuffer
                                    bufferCapacity = newCapacity
                                }
                            }

                            if bufferOffset > 0 && bufferSize > 0 {
                                memmove(buffer, buffer.advanced(by: bufferOffset), bufferSize - bufferOffset)
                                bufferSize -= bufferOffset
                            }
                            bufferOffset = 0
                        }
                        if bufferSize > 0 {
                            try processBuffer()
                        }

                        if currentElementGroup < header.elements.count {
                            Self.log.error("Binary body: unexpected end of file at element type \"\(header.elements[currentElementGroup].name, privacy: .public)\" (\(currentElementCountInGroup)/\(header.elements[currentElementGroup].count)), \(totalElementsDecoded) element(s) decoded, \(totalBytesRead) bytes read")
                            continuation.finish(throwing: Error.unexpectedEndOfFile)
                        } else if bufferOffset < bufferSize {
                            Self.log.error("Binary body: \(bufferSize - bufferOffset) unexpected trailing byte(s) after \(totalElementsDecoded) element(s)")
                            continuation.finish(throwing: Error.unexpectedContentAtEndOfBody)
                        } else {
                            Self.log.info("Binary body: finished, \(totalElementsDecoded) element(s) decoded, \(totalBytesRead) bytes read")
                            continuation.finish()
                        }
                    } catch {
                        Self.log.error("Binary body: error after \(totalElementsDecoded) element(s), \(totalBytesRead) bytes: \(error.localizedDescription, privacy: .public)")
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    private static func append(to buffer: inout UnsafeMutablePointer<UInt8>,
                               withCapacity currentCapacity: inout Int,
                               growthFactor: Float = 2.0,
                               from startIndex: Int,
                               data: Data) {
        guard !data.isEmpty else { return }
        let requiredCapacity = startIndex + data.count
        if requiredCapacity > currentCapacity {
            let newCapacity = max(Int(growthFactor * Float(currentCapacity)), requiredCapacity)
            let newBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
            if startIndex > 0 {
                memcpy(newBuffer, buffer, startIndex)
            }
            buffer.deallocate()
            buffer = newBuffer
            currentCapacity = newCapacity
        }

        data.withUnsafeBytes { rawBuf in
            if let src = rawBuf.baseAddress {
                memcpy(buffer.advanced(by: startIndex), src, data.count)
            }
        }
    }
}
