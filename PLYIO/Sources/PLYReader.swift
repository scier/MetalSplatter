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
        case readError
        case headerStartMissing
        case headerEndMissing
        case unexpectedEndOfFile
        case internalConsistency

        public var errorDescription: String? {
            switch self {
            case .cannotOpenSource(let url):
                "Cannot open source file at \(url)"
            case .readError:
                "Error while reading input"
            case .headerStartMissing:
                "Header start missing"
            case .headerEndMissing:
                "Header end missing"
            case .unexpectedEndOfFile:
                "Unexpected end-of-file while reading input"
            case .internalConsistency:
                "Internal error in PLYReader"
            }
        }
    }

    enum Constants {
        static let headerStartToken = "\(PLYHeader.Keyword.ply.rawValue)\n".data(using: .utf8)!
        static let headerEndToken = "\(PLYHeader.Keyword.endHeader.rawValue)\n".data(using: .utf8)!
        // Hold up to 16k of data at once before reclaiming. Higher numbers will use more data, but lower numbers will result in more frequent, somewhat expensive "move bytes" operations.
        static let bodySizeForReclaim = 16*1024

        static let cr = UInt8(ascii: "\r")
        static let lf = UInt8(ascii: "\n")
        static let space = UInt8(ascii: " ")
    }

    private enum Phase {
        case unstarted
        case header
        case body
    }

    private var inputStream: InputStream
    private var header: PLYHeader? = nil
    private var body = Data()
    private var bodyOffset: Int = 0
    private var currentElementGroup: Int = 0
    private var currentElementCountInGroup: Int = 0
    private var reusableElement = PLYElement(properties: [])

    public init(_ inputStream: InputStream) {
        self.inputStream = inputStream
    }

    public convenience init(_ url: URL) throws {
        guard let inputStream = InputStream(url: url) else {
            throw Error.cannotOpenSource(url)
        }
        self.init(inputStream)
    }

    public func read(to delegate: PLYReaderDelegate) {
        header = nil
        body = Data()
        bodyOffset = 0
        currentElementGroup = 0
        currentElementCountInGroup = 0

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
                delegate.didFailReading(withError: Error.readError)
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
                delegate.didFailReading(withError: Error.unexpectedEndOfFile)
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
                    if headerData.count == Constants.headerStartToken.count {
                        if headerData == Constants.headerStartToken {
                            // Found header start token. Continue to read actual header
                            phase = .header
                        } else {
                            // Beginning of stream didn't match headerStartToken; fail
                            delegate.didFailReading(withError: Error.headerStartMissing)
                            return
                        }
                    }
                case .header:
                    headerData.append(buffer[bufferIndex])
                    bufferIndex += 1
                    if headerData.hasSuffix(Constants.headerEndToken) {
                        do {
                            let header = try PLYHeader.decodeASCII(from: headerData)
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
        guard bodyOffset > 0 && body.count >= Constants.bodySizeForReclaim else { return }
        body.removeSubrange(0..<bodyOffset)
        bodyOffset = body.startIndex
    }

    private func processBody(delegate: PLYReaderDelegate,
                             isEOF: Bool) throws {
        guard let header else {
            throw Error.internalConsistency
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
                        newlineFound = byte == Constants.cr || byte == Constants.lf
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

                    try reusableElement.decodeASCII(type: elementHeader,
                                                    fromMutable: bodyUnsafeBytePointer,
                                                    at: lineStart,
                                                    bodySize: lineLength,
                                                    elementIndex: currentElementGroup)

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

                    guard let bytesConsumed = try reusableElement.tryDecodeBinary(type: elementHeader,
                                                                                  from: bodyUnsafeRawPointer,
                                                                                  at: bodyUnsafeRawPointerOffset,
                                                                                  bodySize: bodyUnsafeRawBufferPointer.count - bodyUnsafeRawPointerOffset,
                                                                                  bigEndian: header.format == .binaryBigEndian) else {
                        // Insufficient data available
                        return
                    }
                    assert(bytesConsumed != 0, "PLYElement.tryDecode consumed at least one byte in producing the PLYElement")
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
}

fileprivate extension Data {
    func hasSuffix(_ data: Data) -> Bool {
        count >= data.count && self[(count - data.count)...] == data
    }
}
