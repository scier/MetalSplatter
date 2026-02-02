import Foundation
import PLYIO
import simd

/// A writer for Gaussian Splat files in the ".splat" format, created by https://github.com/antimatter15/splat/
public class DotSplatSceneWriter: SplatSceneWriter {
    enum Constants {
        static let bufferSize = 64 * 1024
    }

    enum Error: Swift.Error {
        case cannotWriteToFile(String)
        case unknownOutputStreamError
        case cannotWriteAfterClose
    }

    private let outputStream: AsyncBufferingOutputStream
    private var buffer: UnsafeMutableRawPointer?
    private var closed = false

    public init(to destination: WriterDestination) throws {
        self.outputStream = try AsyncBufferingOutputStream(to: destination, bufferSize: Constants.bufferSize)
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Constants.bufferSize, alignment: 8)
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
        try await outputStream.close()
    }

    public var writtenData: Data? {
        get async {
            await outputStream.writtenData
        }
    }

    public func write(_ points: [SplatPoint]) async throws {
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

            let data = Data(bytesNoCopy: buffer, count: bytesStored, deallocator: .none)
            try await outputStream.write(data)

            offset += count
        }
    }
}
