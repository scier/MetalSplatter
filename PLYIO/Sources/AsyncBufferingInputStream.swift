import Foundation

public struct AsyncBufferingInputStream: AsyncSequence, Sendable {
    public typealias Element = Data

    public enum StreamError: Error {
        case cannotOpenSource(URL)
        case eof
        case closed
        case readFailed(underlying: Error?)
        case unexpectedReadResult(Int)
        case cancelled
    }

    actor StreamReader {
        // InputStream is not Sendable, but we manage it safely within this actor.
        // Access is serialized by the actor, and deinit cleanup is safe.
        private nonisolated(unsafe) let stream: InputStream
        private let bufferSize: Int
        private var pushedbackData: [Data] = []
        private var isOpen = false
        private var isClosed = false

        init(_ stream: sending InputStream, bufferSize: Int) {
            self.stream = stream
            self.bufferSize = bufferSize
        }

        func pushback(_ data: Data) {
            guard !data.isEmpty else { return }
            pushedbackData.append(data)
        }

        func readChunk() async throws -> Data? {
            // Return pushback data first (LIFO)
            if let data = pushedbackData.popLast() {
                return data
            }

            guard !isClosed else { return nil }

            // Open stream on first read
            if !isOpen {
                stream.open()
                isOpen = true
            }

            // Check for cancellation
            try Task.checkCancellation()

            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            let readCount = stream.read(buffer, maxLength: bufferSize)

            switch readCount {
            case let n where n > 0:
                return Data(bytes: buffer, count: n)
            case 0:
                close()
                return nil
            case -1:
                close()
                throw StreamError.readFailed(underlying: stream.streamError)
            default:
                close()
                throw StreamError.unexpectedReadResult(readCount)
            }
        }

        private func close() {
            guard !isClosed else { return }
            isClosed = true
            if isOpen {
                stream.close()
            }
        }

        deinit {
            // Note: InputStream.close() is safe to call multiple times or on unopened streams
            stream.close()
        }
    }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        let reader: StreamReader

        public func next() async throws -> Data? {
            try await reader.readChunk()
        }

        public func pushback(_ data: Data) async {
            await reader.pushback(data)
        }
    }

    private let reader: StreamReader

    public init(_ stream: sending InputStream, bufferSize: Int = 16 * 1024) {
        self.reader = StreamReader(stream, bufferSize: bufferSize)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(reader: reader)
    }
}
