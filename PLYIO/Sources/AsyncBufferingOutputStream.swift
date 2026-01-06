import Foundation

public struct AsyncBufferingOutputStream {
    public enum StreamError: Error {
        case closed
        case writeFailed(underlying: Error?)
        case streamFull
    }

    actor StreamWriter {
        // OutputStream is not Sendable, but we manage it safely within this actor.
        // Access is serialized by the actor, and deinit cleanup is safe.
        private nonisolated(unsafe) let stream: OutputStream
        private let bufferSize: Int
        // UnsafeMutablePointer is not Sendable, but owned exclusively by this actor.
        private nonisolated(unsafe) var buffer: UnsafeMutablePointer<UInt8>
        private var bufferOffset: Int = 0
        private var isOpen = false
        private var isClosed = false
        private(set) var writtenData: Data?

        init(_ stream: sending OutputStream, bufferSize: Int) {
            self.stream = stream
            self.bufferSize = bufferSize
            self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        }

        func write(_ data: Data) async throws {
            guard !isClosed else { throw StreamError.closed }

            if !isOpen {
                stream.open()
                isOpen = true
            }

            try data.withUnsafeBytes { rawBuffer in
                guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }

                var offset = 0
                while offset < data.count {
                    let remainingData = data.count - offset
                    let remainingBuffer = bufferSize - bufferOffset
                    let toCopy = min(remainingData, remainingBuffer)

                    // Copy to buffer
                    memcpy(buffer.advanced(by: bufferOffset), bytes.advanced(by: offset), toCopy)
                    bufferOffset += toCopy
                    offset += toCopy

                    // Flush if buffer is full
                    if bufferOffset == bufferSize {
                        try flush()
                    }
                }
            }
        }

        func write(_ string: String) async throws {
            guard let data = string.data(using: .utf8) else { return }
            try await write(data)
        }

        func flush() throws {
            guard bufferOffset > 0 else { return }

            let written = stream.write(buffer, maxLength: bufferOffset)
            if written != bufferOffset {
                if written == 0 {
                    throw StreamError.streamFull
                } else if written == -1 {
                    throw StreamError.writeFailed(underlying: stream.streamError)
                } else {
                    throw StreamError.writeFailed(underlying: nil)
                }
            }
            bufferOffset = 0
        }

        func close() throws {
            guard !isClosed else { return }

            // Flush remaining buffer
            if bufferOffset > 0 {
                try flush()
            }

            isClosed = true
            stream.close()

            // Store memory data if applicable
            writtenData = stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data
        }

        deinit {
            buffer.deallocate()
            // Note: OutputStream.close() is safe to call multiple times or on unopened streams
            stream.close()
        }
    }

    private let writer: StreamWriter
    public let destination: WriterDestination

    public init(to destination: WriterDestination, bufferSize: Int = 64 * 1024) throws {
        self.destination = destination
        self.writer = StreamWriter(try destination.outputStream(), bufferSize: bufferSize)
    }

    public func write(_ data: Data) async throws {
        try await writer.write(data)
    }

    public func write(_ string: String) async throws {
        try await writer.write(string)
    }

    public func flush() async throws {
        try await writer.flush()
    }

    public func close() async throws {
        try await writer.close()
    }

    public var writtenData: Data? {
        get async {
            await writer.writtenData
        }
    }
}
