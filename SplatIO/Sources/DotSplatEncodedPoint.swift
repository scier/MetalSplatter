import Foundation
import PLYIO
import simd

struct DotSplatEncodedPoint {
    var position: SIMD3<Float32>
    var scales: SIMD3<Float32>
    var color: SIMD4<UInt8>
    var rot: SIMD4<UInt8>
}

extension DotSplatEncodedPoint: ByteWidthProviding {
    static var byteWidth: Int {
        Float32.byteWidth * 6 + UInt8.byteWidth * 8
    }
}

extension DotSplatEncodedPoint: ZeroProviding {
    static let zero = DotSplatEncodedPoint(position: .zero, scales: .zero, color: .zero, rot: .zero)
}

extension DotSplatEncodedPoint {
    init<D>(_ data: D, from offset: D.Index, bigEndian: Bool)
    where D : DataProtocol, D.Index == Int {
        let sixFloats = Float32.array(data, from: offset, count: 6, bigEndian: bigEndian)
        let eightInts = UInt8.array(data, from: offset + 6 * Float32.byteWidth, count: 8, bigEndian: bigEndian)
        position = .init(x: sixFloats[0], y: sixFloats[1], z: sixFloats[2])
        scales = .init(x: sixFloats[3], y: sixFloats[4], z: sixFloats[5])
        color = .init(eightInts[0], eightInts[1], eightInts[2], eightInts[3])
        rot = .init(eightInts[4], eightInts[5], eightInts[6], eightInts[7])
    }

    static func array<D>(_ data: D, from offset: D.Index, count: Int, bigEndian: Bool) -> [DotSplatEncodedPoint]
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

extension DotSplatEncodedPoint {
    var splatScenePoint: SplatScenePoint {
        SplatScenePoint(position: position,
                        color: .linearUInt8(color.x, color.y, color.z),
                        opacity: .linearUInt8(color.w),
                        scale: .linearFloat(scales.x, scales.y, scales.z),
                        rotation: simd_quatf(vector: SIMD4(x: Float(rot[1]) - 128,
                                                           y: Float(rot[2]) - 128,
                                                           z: Float(rot[3]) - 128,
                                                           w: Float(rot[0]) - 128)).normalized)
    }
}
