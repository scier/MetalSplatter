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

    @discardableResult
    func store(to data: UnsafeMutableRawPointer, at offset: Int, bigEndian: Bool) -> Int {
        let sixFloats: [Float32] = [ position.x, position.y, position.z,
                                     scales.x, scales.y, scales.z ]
        let eightInts: [UInt8] = [ color.x, color.y, color.z, color.w,
                                   rot.x, rot.y, rot.z, rot.w ]
        var bytesWritten: Int = 0
        bytesWritten += Float32.store(sixFloats, to: data, at: offset, bigEndian: bigEndian)
        bytesWritten += UInt8.store(eightInts, to: data, at: offset + bytesWritten, bigEndian: bigEndian)
        return bytesWritten
    }
}

extension DotSplatEncodedPoint {
    var splatScenePoint: SplatScenePoint {
        SplatScenePoint(position: position,
                        color: .linearUInt8(color.xyz),
                        opacity: .linearUInt8(color.w),
                        scale: .linearFloat(scales),
                        rotation: simd_quatf(ix: Float(rot[1]) - 128,
                                             iy: Float(rot[2]) - 128,
                                             iz: Float(rot[3]) - 128,
                                             r: Float(rot[0]) - 128).normalized)
    }

    init(_ splatScenePoint: SplatScenePoint) {
        self.position = splatScenePoint.position
        let color = splatScenePoint.color.asLinearUInt8
        let opacity = splatScenePoint.opacity.asLinearUInt8
        self.color = .init(x: color.x, y: color.y, z: color.z, w: opacity)
        self.scales = splatScenePoint.scale.asLinearFloat
        let rotation = splatScenePoint.rotation.normalized
        self.rot = .init(
            x: UInt8((rotation.real   * 128 + 128).clamped(to: 0...255)),
            y: UInt8((rotation.imag.x * 128 + 128).clamped(to: 0...255)),
            z: UInt8((rotation.imag.y * 128 + 128).clamped(to: 0...255)),
            w: UInt8((rotation.imag.z * 128 + 128).clamped(to: 0...255))
        )
    }
}

fileprivate extension SIMD4 {
    var xyz: SIMD3<Scalar> {
        SIMD3(x: x, y: y, z: z)
    }
}
