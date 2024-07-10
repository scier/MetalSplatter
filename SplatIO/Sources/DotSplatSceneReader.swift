import Foundation
import PLYIO
import simd

/// A reader for Gaussian Splat files in the ".splat" format, possibly created by https://github.com/antimatter15/splat/
public class DotSplatSceneReader: SplatSceneReader {
    enum Error: Swift.Error {
        case cannotOpenSource(URL)
        case readError(URL)
        case unexpectedEndOfFile
    }

    let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    public func read(to delegate: any SplatSceneReaderDelegate) {
        guard let inputStream = InputStream(url: url) else {
            delegate.didFailReading(withError: Error.cannotOpenSource(url))
            return
        }

        let bufferSize = 64*1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        inputStream.open()
        defer { inputStream.close() }

        var bytesInBuffer = 0
        while true {
            let readResult = inputStream.read(buffer + bytesInBuffer, maxLength: bufferSize - bytesInBuffer)
            switch readResult {
            case -1:
                delegate.didFailReading(withError: Error.readError(url))
                return
            case 0:
                guard bytesInBuffer == 0 else {
                    delegate.didFailReading(withError: Error.unexpectedEndOfFile)
                    return
                }
                delegate.didFinishReading()
                return
            default:
                bytesInBuffer += readResult
            }

            let encodedPointCount = bytesInBuffer / DotSplatEncodedPoint.byteWidth
            guard encodedPointCount > 0 else { continue }

            let bufferPointer = UnsafeBufferPointer(start: buffer, count: bytesInBuffer)
            let splatPoints = (0..<encodedPointCount).map {
                DotSplatEncodedPoint(bufferPointer, from: $0 * DotSplatEncodedPoint.byteWidth, bigEndian: false)
                    .splatScenePoint
            }
            delegate.didRead(points: splatPoints)

            let usedBytesInBuffer = encodedPointCount * DotSplatEncodedPoint.byteWidth
            if usedBytesInBuffer < bytesInBuffer {
                memmove(buffer, buffer+usedBytesInBuffer, bytesInBuffer - usedBytesInBuffer)
            }
            bytesInBuffer -= usedBytesInBuffer
        }
    }
}
