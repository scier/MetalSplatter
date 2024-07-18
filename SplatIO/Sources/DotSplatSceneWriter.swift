import Foundation
import PLYIO
import simd

/// A writer for Gaussian Splat files in the ".splat" format, created by https://github.com/antimatter15/splat/
public class DotSplatSceneWriter: SplatSceneWriter {
    enum Constants {
        static let bufferSize = 64*1024
    }

    enum Error: Swift.Error {
        case cannotWriteToFile(String)
        case unknownOutputStreamError
        case cannotWriteAfterClose
    }

    private let outputStream: OutputStream
    private var buffer: UnsafeMutableRawPointer?

    public init(_ outputStream: OutputStream) {
        self.outputStream = outputStream
        outputStream.open()
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Constants.bufferSize, alignment: 8)
    }

    public convenience init(toFileAtPath path: String, append: Bool) throws {
        guard let outputStream = OutputStream(toFileAtPath: path, append: append) else {
            throw Error.cannotWriteToFile(path)
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
    }

    public func write(_ points: [SplatScenePoint]) throws {
        guard let buffer else {
            throw Error.cannotWriteAfterClose
        }

        var offset = 0
        while offset < points.count {
            let count = min(points.count - offset, Constants.bufferSize / DotSplatEncodedPoint.byteWidth)
            var bytesStored = 0
            for i in offset..<(offset+count) {
                bytesStored += DotSplatEncodedPoint(points[i]).store(to: buffer, at: bytesStored, bigEndian: false)
            }

            if outputStream.write(buffer, maxLength: bytesStored) == -1 {
                if let error = outputStream.streamError {
                    throw error
                } else {
                    throw Error.unknownOutputStreamError
                }
            }

            offset += count
        }
    }
}
