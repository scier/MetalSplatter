import Foundation
import os

public class PLYWriter {
    private enum Constants {
        static let defaultBufferSize = 64 * 1024
    }

    public enum Error: Swift.Error {
        case headerAlreadyWritten
        case headerNotYetWritten
        case cannotWriteAfterClose
        case unexpectedElement
        case unknownOutputStreamError
        case outputStreamFull
    }

    private static let log = Logger()

    private let outputStream: AsyncBufferingOutputStream
    private var buffer: UnsafeMutableRawPointer?
    private var bufferSize: Int
    private var header: PLYHeader?

    private var ascii = false
    private var bigEndian = false

    private var currentElementGroupIndex = 0
    private var currentElementCountInGroup = 0
    private var closed = false

    public init(to destination: WriterDestination) throws {
        self.outputStream = try AsyncBufferingOutputStream(to: destination, bufferSize: Constants.defaultBufferSize)
        bufferSize = Constants.defaultBufferSize
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
    }

    public convenience init(toFileAtPath path: String) throws {
        try self.init(to: .file(URL(fileURLWithPath: path)))
    }

    deinit {
        buffer?.deallocate()
    }

    public func close() async throws {
        guard !closed else { return }
        closed = true

        buffer?.deallocate()
        buffer = nil

        if let header {
            if currentElementGroupIndex < header.elements.count {
                Self.log.error("PLYWriter stream closed before all elements have been written")
            }
        }

        try await outputStream.close()
    }

    public var writtenData: Data? {
        get async {
            await outputStream.writtenData
        }
    }

    /// write(_:PLYHeader) must be called exactly once before zero or more calls to write(_:[PLYElement]).
    public func write(_ header: PLYHeader) async throws {
        guard !closed else { throw Error.cannotWriteAfterClose }
        if self.header != nil {
            throw Error.headerAlreadyWritten
        }

        self.header = header

        try await outputStream.write("\(header.description)")
        try await outputStream.write("\(PLYHeader.Keyword.endHeader.rawValue)\n")

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

    /// write(_:[PLYElement]) may be called multiple times after write(_:PLYHeader), until all elements have been supplied.
    public func write(_ elements: [PLYElement], count: Int? = nil) async throws {
        guard !closed else { throw Error.cannotWriteAfterClose }
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
                    try await outputStream.write(remainingElements[i].description)
                    try await outputStream.write("\n")
                }
            } else {
                var bufferOffset = 0
                for i in 0..<countInGroup {
                    let element = remainingElements[i]
                    let remainingBufferCapacity = bufferSize - bufferOffset
                    let elementByteWidth = try element.encodedBinaryByteWidth(type: elementHeader)
                    if elementByteWidth > remainingBufferCapacity {
                        // Not enough room in the buffer; flush it
                        try await dumpBuffer(length: bufferOffset)
                        bufferOffset = 0
                    }
                    if elementByteWidth > bufferSize {
                        assert(bufferOffset == 0)
                        // The buffer's empty and just not big enough. Expand it.
                        buffer?.deallocate()
                        bufferSize = elementByteWidth
                        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
                    }

                    bufferOffset += try element.encodeBinary(type: elementHeader,
                                                             to: buffer!,
                                                             at: bufferOffset,
                                                             bigEndian: bigEndian)
                }

                try await dumpBuffer(length: bufferOffset)
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

    private func dumpBuffer(length: Int) async throws {
        guard length > 0, let buffer else { return }
        let data = Data(bytesNoCopy: buffer, count: length, deallocator: .none)
        try await outputStream.write(data)
    }

    public func write(_ element: PLYElement) async throws {
        try await write([element])
    }
}
