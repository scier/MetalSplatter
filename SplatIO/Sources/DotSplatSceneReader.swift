import Foundation
import PLYIO
import simd

/// A reader for Gaussian Splat files in the ".splat" format, created by https://github.com/antimatter15/splat/
public class DotSplatSceneReader: SplatSceneReader {
    enum Constants {
        static let bodyBufferLen = 16*1024
    }

    public enum Error: Swift.Error {
        case cannotOpenSource(URL)
        case readError
        case unexpectedEndOfFile
    }

    private let source: ReaderSource

    public init(_ url: URL) throws {
        guard url.isFileURL else {
            throw Error.cannotOpenSource(url)
        }
        self.source = .url(url)
    }

    public init(_ data: Data) throws {
        self.source = .memory(data)
    }

    public func read() throws -> AsyncThrowingStream<[SplatPoint], Swift.Error> {
        let byteStream = AsyncBufferingInputStream(try source.inputStream(),
                                                   bufferSize: Constants.bodyBufferLen)

        return AsyncThrowingStream { continuation in
            Task {
                var buffer = Data()
                var startIndex = buffer.startIndex
                do {
                    for try await chunk in byteStream {
                        buffer.append(chunk)

                        let fullPointsCount = buffer.count / DotSplatEncodedPoint.byteWidth
                        guard fullPointsCount > 0 else { continue }

                        let pointsCountBytes = fullPointsCount * DotSplatEncodedPoint.byteWidth
                        var splatPoints = [SplatPoint]()
                        splatPoints.reserveCapacity(fullPointsCount)

                        for i in 0..<fullPointsCount {
                            let encodedPoint = DotSplatEncodedPoint(buffer,
                                                                    from: startIndex + i * DotSplatEncodedPoint.byteWidth,
                                                                    bigEndian: false)
                            splatPoints.append(encodedPoint.splatPoint)
                        }

                        continuation.yield(splatPoints)

                        buffer.removeFirst(pointsCountBytes)
                        startIndex = buffer.startIndex
                    }

                    if !buffer.isEmpty {
                        continuation.finish(throwing: Error.unexpectedEndOfFile)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: Error.readError)
                }
            }
        }
    }
}
