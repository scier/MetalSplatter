import Foundation
import os

public class PLYWriter {
    private enum Constants {
        static let defaultBufferSize = 64*1024
    }

    enum Error: Swift.Error {
        case headerAlreadyWritten
        case headerNotYetWritten
        case cannotWriteAfterClose
        case unexpectedElement
        case unknownOutputStreamError
        case outputStreamFull
    }

    private static let log = Logger()

    private let outputStream: OutputStream
    private var buffer: UnsafeMutableRawPointer?
    private var bufferSize: Int
    private var header: PLYHeader?

    private var ascii = false
    private var bigEndian = false

    private var currentElementGroupIndex = 0
    private var currentElementCountInGroup = 0

    public init(_ outputStream: OutputStream) {
        self.outputStream = outputStream
        outputStream.open()
        bufferSize = Constants.defaultBufferSize
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
    }

    public convenience init?(toFileAtPath path: String, append: Bool) {
        guard let outputStream = OutputStream(toFileAtPath: path, append: append) else {
            return nil
        }
        self.init(outputStream)
    }

    deinit {
        try? close()
    }

    public func close() throws {
        outputStream.close()

        buffer?.deallocate()
        buffer = nil

        guard let header else {
            throw Error.headerNotYetWritten
        }
        if currentElementGroupIndex < header.elements.count {
            Self.log.error("PLYWriter stream closed before all elements have been written")
        }
    }

    /// write(_:PLYHeader, elementCount: Int) must be callen exactly once before zero or more calls to write(_:[PLYElement]). Once called, this method should not be called again on the same PLYWriter.
    public func write(_ header: PLYHeader) throws {
        if self.header != nil {
            throw Error.headerAlreadyWritten
        }

        self.header = header

        outputStream.write("\(header.description)")
        outputStream.write("\(PLYHeader.Keyword.endHeader.rawValue)\n")

        switch header.format {
        case .ascii:
            self.ascii = true
        case .binaryBigEndian:
            self.ascii = false
            self.bigEndian = true
        case .binaryLittleEndian:
            self.ascii = false
            self.bigEndian = false
        }
    }

    /// write(_:PLYHeader, elementCount: Int) must be callen exactly once before any calls to write(_:[PLYElement]).  This method may be called multiple times, until all have been supplied, after which close() should be called exactly once.
    public func write(_ elements: [PLYElement], count: Int? = nil) throws {
        guard let header else {
            throw Error.headerNotYetWritten
        }

        var remainingElements: [PLYElement]
        if let count {
            guard count > 0 else { return }
            remainingElements = Array(elements[0..<count])
        } else {
            remainingElements = elements
        }

        while !remainingElements.isEmpty {
            guard currentElementGroupIndex < header.elements.count else {
                throw Error.unexpectedElement
            }
            let elementHeader = header.elements[currentElementGroupIndex]
            let countInGroup = min(remainingElements.count, Int(elementHeader.count) - currentElementCountInGroup)

            if ascii {
                for i in 0..<countInGroup {
                    outputStream.write(remainingElements[i].description)
                    outputStream.write("\n")
                }
            } else {
                var bufferOffset = 0
                for i in 0..<countInGroup {
                    let element = remainingElements[i]
                    let remainingBufferCapacity = bufferSize - bufferOffset
                    let elementByteWidth = try element.encodedBinaryByteWidth(type: elementHeader)
                    if elementByteWidth > remainingBufferCapacity {
                        // Not enough room in the buffer; make room
                        try dumpBuffer(length: bufferOffset)
                        bufferOffset = 0
                    }
                    if elementByteWidth > bufferSize {
                        assert(bufferOffset == 0)
                        // The buffer's empty and just not big enough. Expand it.
                        if bufferOffset == 0 {
                            buffer?.deallocate()
                            bufferSize = elementByteWidth
                            buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
                        }
                    }

                    bufferOffset += try element.encodeBinary(type: elementHeader,
                                                             to: buffer!,
                                                             at: bufferOffset,
                                                             bigEndian: bigEndian)
                }

                try dumpBuffer(length: bufferOffset)
            }

            remainingElements = Array(remainingElements.dropFirst(countInGroup))

            currentElementCountInGroup += countInGroup
            while (currentElementGroupIndex < header.elements.count) &&
                    (currentElementCountInGroup == header.elements[currentElementGroupIndex].count) {
                currentElementGroupIndex += 1
                currentElementCountInGroup = 0
            }
        }
    }

    private func dumpBuffer(length: Int) throws {
        guard length > 0 else {
            return
        }

        switch outputStream.write(buffer!, maxLength: length) {
        case length:
            return
        case 0:
            throw Error.outputStreamFull
        case -1:
            fallthrough
        default:
            if let error = outputStream.streamError {
                throw error
            } else {
                throw Error.unknownOutputStreamError
            }
        }
    }

    public func write(_ element: PLYElement) throws {
        try write([ element ])
    }
}

fileprivate extension OutputStream {
    @discardableResult
    func write(_ data: Data) -> Int {
        data.withUnsafeBytes {
            if let pointer = $0.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                return write(pointer, maxLength: data.count)
            } else {
                return 0
            }
        }
    }

    @discardableResult
    func write(_ string: String) -> Int {
        write(string.data(using: .utf8)!)
    }
}
