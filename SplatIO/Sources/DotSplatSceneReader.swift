import Foundation
import PLYIO
import simd

/// A reader for Gaussian Splat files in the ".splat" format, possibly created by https://github.com/antimatter15/splat/
public class DotSplatSceneReader: SplatSceneReader {
    struct EncodedSplatPoint {
        var position: SIMD3<Float32>
        var scales: SIMD3<Float32>
        var color: SIMD4<UInt8>
        var rot: SIMD4<UInt8>
    }

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

            let encodedPointCount = bytesInBuffer / EncodedSplatPoint.byteWidth
            guard encodedPointCount > 0 else { continue }

            let bufferPointer = UnsafeBufferPointer(start: buffer, count: bytesInBuffer)
            let splatPoints = (0..<encodedPointCount).map {
                EncodedSplatPoint(bufferPointer, from: $0 * EncodedSplatPoint.byteWidth, bigEndian: false)
                    .splatScenePoint
            }
            delegate.didRead(points: splatPoints)

            let usedBytesInBuffer = encodedPointCount * EncodedSplatPoint.byteWidth
            if usedBytesInBuffer < bytesInBuffer {
                memmove(buffer, buffer+usedBytesInBuffer, bytesInBuffer - usedBytesInBuffer)
            }
            bytesInBuffer -= usedBytesInBuffer
        }
    }
}

extension DotSplatSceneReader.EncodedSplatPoint: ByteWidthProviding {
    static var byteWidth: Int {
        Float32.byteWidth * 6 + UInt8.byteWidth * 8
    }
}

extension DotSplatSceneReader.EncodedSplatPoint: ZeroProviding {
    static let zero = DotSplatSceneReader.EncodedSplatPoint(position: .zero, scales: .zero, color: .zero, rot: .zero)
}

extension DotSplatSceneReader.EncodedSplatPoint {
    init<D>(_ data: D, from offset: D.Index, bigEndian: Bool)
    where D : DataProtocol, D.Index == Int {
        let sixFloats = Float32.array(data, from: offset, count: 6, bigEndian: bigEndian)
        let eightInts = UInt8.array(data, from: offset + 6 * Float32.byteWidth, count: 8, bigEndian: bigEndian)
        position = .init(x: sixFloats[0], y: sixFloats[1], z: sixFloats[2])
        scales = .init(x: sixFloats[3], y: sixFloats[4], z: sixFloats[5])
        color = .init(eightInts[0], eightInts[1], eightInts[2], eightInts[3])
        rot = .init(eightInts[4], eightInts[5], eightInts[6], eightInts[7])
    }

    static func array<D>(_ data: D, from offset: D.Index, count: Int, bigEndian: Bool) -> [DotSplatSceneReader.EncodedSplatPoint]
    where D : DataProtocol, D.Index == Int {
        var values: [Self] = Array(repeating: .zero, count: count)
        var offset = offset
        for i in 0..<count {
            values[i] = Self(data, from: offset, bigEndian: bigEndian)
            offset += byteWidth
        }
        return values
    }
}

extension DotSplatSceneReader.EncodedSplatPoint {
    var splatScenePoint: SplatScenePoint {
        SplatScenePoint(position: position,
                        normal: nil,
                        color: .linearUInt8(color.x, color.y, color.z),
                        opacity: .linearUInt8(color.w),
                        scale: .linearFloat(scales.x, scales.y, scales.z),
                        rotation: simd_quatf(vector: SIMD4(x: Float(rot[1]) - 128,
                                                           y: Float(rot[2]) - 128,
                                                           z: Float(rot[3]) - 128,
                                                           w: Float(rot[0]) - 128)).normalized)
    }
}
