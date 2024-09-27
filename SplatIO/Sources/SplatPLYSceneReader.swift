import Foundation
import PLYIO

public class SplatPLYSceneReader: SplatSceneReader {
    enum Error: LocalizedError {
        case unsupportedFileContents(String?)
        case unexpectedPointCountDiscrepancy
        case internalConsistency(String?)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFileContents(let description):
                if let description {
                    "Unexpected file contents for a splat PLY: \(description)"
                } else {
                    "Unexpected file contents for a splat PLY"
                }
            case .unexpectedPointCountDiscrepancy:
                "Unexpected point count discrepancy"
            case .internalConsistency(let description):
                "Internal error in SplatPLYSceneReader: \(description ?? "(unknown)")"
            }
        }
    }

    private let ply: PLYReader

    public convenience init(_ url: URL) throws {
        self.init(try PLYReader(url))
    }

    public convenience init(_ inputStream: InputStream) {
        self.init(PLYReader(inputStream))
    }

    public init(_ ply: PLYReader) {
        self.ply = ply
    }

    public func read(to delegate: SplatSceneReaderDelegate) {
        SplatPLYSceneReaderStream().read(ply, to: delegate)
    }
}

private struct Chunk {
    let minPosition: SIMD3<Float>
    let maxPosition: SIMD3<Float>
    let minScale: SIMD3<Float>
    let maxScale: SIMD3<Float>
}

private class SplatPLYSceneReaderStream {
    private weak var delegate: SplatSceneReaderDelegate? = nil
    private var active = false {
        didSet {
            if !active && !chunks.isEmpty {
                chunks.removeAll()
            }
        }
    }
    private var compressedElementMapping: CompressedElementInputMapping?
    private var elementMapping: ElementInputMapping?
    private var expectedPointCount: UInt32 = 0
    private var pointCount: UInt32 = 0
    private var reusablePoint = SplatScenePoint(position: .zero,
                                                color: .linearUInt8(.zero),
                                                opacity: .linearFloat(.zero),
                                                scale: .exponent(.zero),
                                                rotation: .init(vector: .zero))
    private var isCompressed = false
    private var chunks = [Chunk]()

    func read(_ ply: PLYReader, to delegate: SplatSceneReaderDelegate) {
        self.delegate = delegate
        active = true
        compressedElementMapping = nil
        elementMapping = nil
        expectedPointCount = 0
        pointCount = 0

        ply.read(to: self)

        assert(!active)
    }
}

extension SplatPLYSceneReaderStream: PLYReaderDelegate {
    func didStartReading(withHeader header: PLYHeader) {
        guard active else { return }
        guard elementMapping == nil else {
            delegate?.didFailReading(withError: SplatPLYSceneReader.Error.internalConsistency("didStart called while elementMapping is non-nil"))
            active = false
            return
        }

        do {
            isCompressed = header.index(forElementNamed: CompressedElementInputMapping.ElementName.chunk.rawValue) != nil
            if isCompressed {
                let elementMapping = try CompressedElementInputMapping.elementMapping(for: header)
                compressedElementMapping = elementMapping
                expectedPointCount = header.elements[elementMapping.vertexTypeIndex].count
            }
            else {
                let elementMapping = try ElementInputMapping.elementMapping(for: header)
                self.elementMapping = elementMapping
                expectedPointCount = header.elements[elementMapping.elementTypeIndex].count
            }

            delegate?.didStartReading(withPointCount: expectedPointCount)
        } catch {
            delegate?.didFailReading(withError: error)
            active = false
            return
        }
    }

    func didRead(element: PLYElement, typeIndex: Int, withHeader elementHeader: PLYHeader.Element) {
        guard active else { return }
        if isCompressed {
            guard let compressedElementMapping else {
                delegate?.didFailReading(withError: SplatPLYSceneReader.Error.internalConsistency("didRead(element:typeIndex:withHeader:) called but elementMapping is nil"))
                active = false
                return
            }
            
            switch typeIndex {
            case compressedElementMapping.chunkTypeIndex:
                do {
                    let chunk = try compressedElementMapping.chunk(from: element)
                    chunks.append(chunk)
                } catch {
                    delegate?.didFailReading(withError: error)
                    active = false
                }
            case compressedElementMapping.vertexTypeIndex:
                do {
                    try compressedElementMapping.apply(from: element, with: chunks[Int(pointCount)/256], to: &reusablePoint)
                    pointCount += 1
                    delegate?.didRead(points: [ reusablePoint ])
                } catch {
                    delegate?.didFailReading(withError: error)
                    active = false
                }
            default:
                break
            }
            return
        }
        
        guard let elementMapping else {
            delegate?.didFailReading(withError: SplatPLYSceneReader.Error.internalConsistency("didRead(element:typeIndex:withHeader:) called but elementMapping is nil"))
            active = false
            return
        }

        guard typeIndex == elementMapping.elementTypeIndex else { return }
        do {
            try elementMapping.apply(from: element, to: &reusablePoint)
            pointCount += 1
            delegate?.didRead(points: [ reusablePoint ])
        } catch {
            delegate?.didFailReading(withError: error)
            active = false
            return
        }
    }

    func didFinishReading() {
        guard active else { return }
        guard expectedPointCount == pointCount else {
            delegate?.didFailReading(withError: SplatPLYSceneReader.Error.unexpectedPointCountDiscrepancy)
            active = false
            return
        }

        delegate?.didFinishReading()
        active = false
    }

    func didFailReading(withError error: Swift.Error?) {
        guard active else { return }
        delegate?.didFailReading(withError: error)
        active = false
    }
}

private struct ElementInputMapping {
    public enum Color {
        case sphericalHarmonic([SIMD3<Int>])
        case linearFloat256(SIMD3<Int>)
        case linearUInt8(SIMD3<Int>)

    }

    static let sphericalHarmonicsCount = 45

    let elementTypeIndex: Int

    let positionXPropertyIndex: Int
    let positionYPropertyIndex: Int
    let positionZPropertyIndex: Int
    let colorPropertyIndices: Color
    let scaleXPropertyIndex: Int
    let scaleYPropertyIndex: Int
    let scaleZPropertyIndex: Int
    let opacityPropertyIndex: Int
    let rotation0PropertyIndex: Int
    let rotation1PropertyIndex: Int
    let rotation2PropertyIndex: Int
    let rotation3PropertyIndex: Int

    static func elementMapping(for header: PLYHeader) throws -> ElementInputMapping {
        guard let elementTypeIndex = header.index(forElementNamed: SplatPLYConstants.ElementName.point.rawValue) else {
            throw SplatPLYSceneReader.Error.unsupportedFileContents("No element type \"\(SplatPLYConstants.ElementName.point.rawValue)\" found")
        }
        let headerElement = header.elements[elementTypeIndex]

        let positionXPropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.positionX)
        let positionYPropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.positionY)
        let positionZPropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.positionZ)

        let color: Color
        if let sh0_rPropertyIndex = try headerElement.index(forOptionalFloat32PropertyNamed: SplatPLYConstants.PropertyName.sh0_r),
           let sh0_gPropertyIndex = try headerElement.index(forOptionalFloat32PropertyNamed: SplatPLYConstants.PropertyName.sh0_g),
            let sh0_bPropertyIndex = try headerElement.index(forOptionalFloat32PropertyNamed: SplatPLYConstants.PropertyName.sh0_b) {
            let primaryColorPropertyIndices = SIMD3<Int>(x: sh0_rPropertyIndex, y: sh0_gPropertyIndex, z: sh0_bPropertyIndex)
            if headerElement.hasProperty(forName: "\(SplatPLYConstants.PropertyName.sphericalHarmonicsPrefix)0") {
                let individualSphericalHarmonicsPropertyIndices: [Int] = try (0..<sphericalHarmonicsCount).map {
                    try headerElement.index(forFloat32PropertyNamed: [ "\(SplatPLYConstants.PropertyName.sphericalHarmonicsPrefix)\($0)" ])
                }
                let sphericalHarmonicsPropertyIndices: [SIMD3<Int>] = stride(from: 0, to: individualSphericalHarmonicsPropertyIndices.count, by: 3).map {
                    SIMD3<Int>(individualSphericalHarmonicsPropertyIndices[$0],
                               individualSphericalHarmonicsPropertyIndices[$0 + 1],
                               individualSphericalHarmonicsPropertyIndices[$0 + 2])
                }
                color = .sphericalHarmonic([primaryColorPropertyIndices] + sphericalHarmonicsPropertyIndices)
            } else {
                color = .sphericalHarmonic([primaryColorPropertyIndices])
            }
        } else if headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorR, type: .float32) &&
                    headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorG, type: .float32) &&
                    headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorB, type: .float32) {
            // Special case for NRRFStudio SH=0 files. This may be fixed now?
            let colorRPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorR, type: .float32)
            let colorGPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorG, type: .float32)
            let colorBPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorB, type: .float32)
            color = .linearFloat256(SIMD3(colorRPropertyIndex, colorGPropertyIndex, colorBPropertyIndex))
        } else if headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorR, type: .uint8) &&
                    headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorG, type: .uint8) &&
                    headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorB, type: .uint8) {
            let colorRPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorR, type: .uint8)
            let colorGPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorG, type: .uint8)
            let colorBPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorB, type: .uint8)
            color = .linearUInt8(SIMD3(colorRPropertyIndex, colorGPropertyIndex, colorBPropertyIndex))
        } else {
            throw SplatPLYSceneReader.Error.unsupportedFileContents("No color property elements found with the expected types")
        }

        let scaleXPropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.scaleX)
        let scaleYPropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.scaleY)
        let scaleZPropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.scaleZ)
        let opacityPropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.opacity)

        let rotation0PropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.rotation0)
        let rotation1PropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.rotation1)
        let rotation2PropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.rotation2)
        let rotation3PropertyIndex = try headerElement.index(forFloat32PropertyNamed: SplatPLYConstants.PropertyName.rotation3)

        return ElementInputMapping(elementTypeIndex: elementTypeIndex,
                                   positionXPropertyIndex: positionXPropertyIndex,
                                   positionYPropertyIndex: positionYPropertyIndex,
                                   positionZPropertyIndex: positionZPropertyIndex,
                                   colorPropertyIndices: color,
                                   scaleXPropertyIndex: scaleXPropertyIndex,
                                   scaleYPropertyIndex: scaleYPropertyIndex,
                                   scaleZPropertyIndex: scaleZPropertyIndex,
                                   opacityPropertyIndex: opacityPropertyIndex,
                                   rotation0PropertyIndex: rotation0PropertyIndex,
                                   rotation1PropertyIndex: rotation1PropertyIndex,
                                   rotation2PropertyIndex: rotation2PropertyIndex,
                                   rotation3PropertyIndex: rotation3PropertyIndex)
    }

    func apply(from element: PLYElement, to result: inout SplatScenePoint) throws {
        result.position = SIMD3(x: try element.float32Value(forPropertyIndex: positionXPropertyIndex),
                                y: try element.float32Value(forPropertyIndex: positionYPropertyIndex),
                                z: try element.float32Value(forPropertyIndex: positionZPropertyIndex))

        switch colorPropertyIndices {
        case .sphericalHarmonic(let sphericalHarmonicsPropertyIndices):
            result.color = .sphericalHarmonic(try sphericalHarmonicsPropertyIndices.map {
                try SIMD3<Float>(x: element.float32Value(forPropertyIndex: $0.x),
                                 y: element.float32Value(forPropertyIndex: $0.y),
                                 z: element.float32Value(forPropertyIndex: $0.z))
            })
        case .linearFloat256(let propertyIndices):
            result.color = .linearFloat256(SIMD3(try element.float32Value(forPropertyIndex: propertyIndices.x),
                                                 try element.float32Value(forPropertyIndex: propertyIndices.y),
                                                 try element.float32Value(forPropertyIndex: propertyIndices.z)))
        case .linearUInt8(let propertyIndices):
            result.color = .linearUInt8(SIMD3(try element.uint8Value(forPropertyIndex: propertyIndices.x),
                                              try element.uint8Value(forPropertyIndex: propertyIndices.y),
                                              try element.uint8Value(forPropertyIndex: propertyIndices.z)))
        }

        result.scale =
            .exponent(SIMD3(try element.float32Value(forPropertyIndex: scaleXPropertyIndex),
                            try element.float32Value(forPropertyIndex: scaleYPropertyIndex),
                            try element.float32Value(forPropertyIndex: scaleZPropertyIndex)))
        result.opacity = .logitFloat(try element.float32Value(forPropertyIndex: opacityPropertyIndex))
        result.rotation.real   = try element.float32Value(forPropertyIndex: rotation0PropertyIndex)
        result.rotation.imag.x = try element.float32Value(forPropertyIndex: rotation1PropertyIndex)
        result.rotation.imag.y = try element.float32Value(forPropertyIndex: rotation2PropertyIndex)
        result.rotation.imag.z = try element.float32Value(forPropertyIndex: rotation3PropertyIndex)
    }
}

private struct CompressedElementInputMapping {
    enum ElementName: String {
        case chunk = "chunk"
        case vertex = "vertex"
    }
    
    static var SH_C0: Float = 0.28209479177387814
    
    enum PropertyName {
        static let positionMinX = ["min_x"]
        static let positionMinY = ["min_y"]
        static let positionMinZ = ["min_z"]
        static let positionMaxX = ["max_x"]
        static let positionMaxY = ["max_y"]
        static let positionMaxZ = ["max_z"]
        static let scaleMinX = ["min_scale_x"]
        static let scaleMinY = ["min_scale_y"]
        static let scaleMinZ = ["min_scale_z"]
        static let scaleMaxX = ["max_scale_x"]
        static let scaleMaxY = ["max_scale_y"]
        static let scaleMaxZ = ["max_scale_z"]
        
        static let packedPosition = ["packed_position"]
        static let packedRotation = ["packed_rotation"]
        static let packedScale = ["packed_scale"]
        static let packedColor = ["packed_color"]
    }
    
    let chunkTypeIndex: Int
    let vertexTypeIndex: Int
    
    let positionMinXPropertyIndex: Int
    let positionMinYPropertyIndex: Int
    let positionMinZPropertyIndex: Int
    let positionMaxXPropertyIndex: Int
    let positionMaxYPropertyIndex: Int
    let positionMaxZPropertyIndex: Int
    let scaleMinXPropertyIndex: Int
    let scaleMinYPropertyIndex: Int
    let scaleMinZPropertyIndex: Int
    let scaleMaxXPropertyIndex: Int
    let scaleMaxYPropertyIndex: Int
    let scaleMaxZPropertyIndex: Int
    let packedPositionPropertyIndex: Int
    let packedRotationPropertyIndex: Int
    let packedScalePropertyIndex: Int
    let packedColorPropertyIndex: Int
    
    static func elementMapping(for header: PLYHeader) throws -> CompressedElementInputMapping {
        guard let chunkTypeIndex = header.index(forElementNamed: ElementName.chunk.rawValue) else {
            throw SplatPLYSceneReader.Error.unsupportedFileContents("No element type \"\(ElementName.chunk.rawValue)\" found")
        }
        guard let vertexTypeIndex = header.index(forElementNamed: ElementName.vertex.rawValue) else {
            throw SplatPLYSceneReader.Error.unsupportedFileContents("No element type \"\(ElementName.vertex.rawValue)\" found")
        }
        
        let chunkHeaderElement = header.elements[chunkTypeIndex]
        let vertexHeaderElement = header.elements[vertexTypeIndex]
        
        let positionMinXPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.positionMinX)
        let positionMinYPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.positionMinY)
        let positionMinZPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.positionMinZ)
        let positionMaxXPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.positionMaxX)
        let positionMaxYPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.positionMaxY)
        let positionMaxZPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.positionMaxZ)
        
        let scaleMinXPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.scaleMinX)
        let scaleMinYPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.scaleMinY)
        let scaleMinZPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.scaleMinZ)
        let scaleMaxXPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.scaleMaxX)
        let scaleMaxYPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.scaleMaxY)
        let scaleMaxZPropertyIndex = try chunkHeaderElement.index(forFloat32PropertyNamed: PropertyName.scaleMaxZ)
        
        let packedPositionPropertyIndex = try vertexHeaderElement.index(forPropertyNamed: PropertyName.packedPosition, type: .uint32)
        let packedRotationPropertyIndex = try vertexHeaderElement.index(forPropertyNamed: PropertyName.packedRotation, type: .uint32)
        let packedScalePropertyIndex = try vertexHeaderElement.index(forPropertyNamed: PropertyName.packedScale, type: .uint32)
        let packedColorPropertyIndex = try vertexHeaderElement.index(forPropertyNamed: PropertyName.packedColor, type: .uint32)
        
        return CompressedElementInputMapping(chunkTypeIndex: chunkTypeIndex,
                                             vertexTypeIndex: vertexTypeIndex,
                                             positionMinXPropertyIndex: positionMinXPropertyIndex,
                                             positionMinYPropertyIndex: positionMinYPropertyIndex,
                                             positionMinZPropertyIndex: positionMinZPropertyIndex,
                                             positionMaxXPropertyIndex: positionMaxXPropertyIndex,
                                             positionMaxYPropertyIndex: positionMaxYPropertyIndex,
                                             positionMaxZPropertyIndex: positionMaxZPropertyIndex,
                                             scaleMinXPropertyIndex: scaleMinXPropertyIndex,
                                             scaleMinYPropertyIndex: scaleMinYPropertyIndex,
                                             scaleMinZPropertyIndex: scaleMinZPropertyIndex,
                                             scaleMaxXPropertyIndex: scaleMaxXPropertyIndex,
                                             scaleMaxYPropertyIndex: scaleMaxYPropertyIndex,
                                             scaleMaxZPropertyIndex: scaleMaxZPropertyIndex,
                                             packedPositionPropertyIndex: packedPositionPropertyIndex,
                                             packedRotationPropertyIndex: packedRotationPropertyIndex,
                                             packedScalePropertyIndex: packedScalePropertyIndex,
                                             packedColorPropertyIndex: packedColorPropertyIndex)
    }
    
    func chunk(from element: PLYElement) throws -> Chunk {
        let posMinX = try element.float32Value(forPropertyIndex: positionMinXPropertyIndex)
        let posMinY = try element.float32Value(forPropertyIndex: positionMinYPropertyIndex)
        let posMinZ = try element.float32Value(forPropertyIndex: positionMinZPropertyIndex)
        let posMaxX = try element.float32Value(forPropertyIndex: positionMaxXPropertyIndex)
        let posMaxY = try element.float32Value(forPropertyIndex: positionMaxYPropertyIndex)
        let posMaxZ = try element.float32Value(forPropertyIndex: positionMaxZPropertyIndex)
        let scaleMinX = try element.float32Value(forPropertyIndex: scaleMinXPropertyIndex)
        let scaleMinY = try element.float32Value(forPropertyIndex: scaleMinYPropertyIndex)
        let scaleMinZ = try element.float32Value(forPropertyIndex: scaleMinZPropertyIndex)
        let scaleMaxX = try element.float32Value(forPropertyIndex: scaleMaxXPropertyIndex)
        let scaleMaxY = try element.float32Value(forPropertyIndex: scaleMaxYPropertyIndex)
        let scaleMaxZ = try element.float32Value(forPropertyIndex: scaleMinZPropertyIndex)
        
        return Chunk(minPosition: SIMD3<Float>(posMinX, posMinY, posMinZ),
                     maxPosition: SIMD3<Float>(posMaxX, posMaxY, posMaxZ),
                     minScale: SIMD3<Float>(scaleMinX, scaleMinY, scaleMinZ),
                     maxScale: SIMD3<Float>(scaleMaxX, scaleMaxY, scaleMaxZ))
    }
    
    func apply(from element: PLYElement, with chunk: Chunk, to result: inout SplatScenePoint) throws {
        let packedPosition = try element.uint32Value(forPropertyIndex: packedPositionPropertyIndex)
        let packedRotation = try element.uint32Value(forPropertyIndex: packedRotationPropertyIndex)
        let packedScale = try element.uint32Value(forPropertyIndex: packedScalePropertyIndex)
        let packedColor = try element.uint32Value(forPropertyIndex: packedColorPropertyIndex)
    
        let posX = unpackUnorm(packedPosition >> 21, bits: 11)
        let posY = unpackUnorm(packedPosition >> 11, bits: 10)
        let posZ = unpackUnorm(packedPosition, bits: 11)
        
        result.position.x = lerp(a: chunk.minPosition.x, b: chunk.maxPosition.x, t: posX)
        result.position.y = lerp(a: chunk.minPosition.y, b: chunk.maxPosition.y, t: posY)
        result.position.z = lerp(a: chunk.minPosition.z, b: chunk.maxPosition.z, t: posZ)
        
        let rotation = try unpackRot(packedRotation)
        result.rotation.real = rotation.x
        result.rotation.imag.x = rotation.y
        result.rotation.imag.y = rotation.z
        result.rotation.imag.z = rotation.w
        
        let scaleX = unpackUnorm(packedScale >> 21, bits: 11)
        let scaleY = unpackUnorm(packedScale >> 11, bits: 10)
        let scaleZ = unpackUnorm(packedScale, bits: 11)
        
        result.scale = .exponent(.init(x: lerp(a: chunk.minScale.x, b: chunk.maxScale.x, t: scaleX),
                                       y: lerp(a: chunk.minScale.y, b: chunk.maxScale.y, t: scaleY),
                                       z: lerp(a: chunk.minScale.z, b: chunk.maxScale.z, t: scaleZ)))
        
        let colorR = unpackUnorm(packedColor >> 24, bits: 8)
        let colorG = unpackUnorm(packedColor >> 16, bits: 8)
        let colorB = unpackUnorm(packedColor >> 8, bits: 8)
        let opacity = unpackUnorm(packedColor, bits: 8)
        
        result.color = .sphericalHarmonic([.init(x: (colorR - 0.5) / CompressedElementInputMapping.SH_C0,
                                                 y: (colorG - 0.5) / CompressedElementInputMapping.SH_C0,
                                                 z: (colorB - 0.5) / CompressedElementInputMapping.SH_C0)])
        
        result.opacity = .logitFloat(-logf(1 / opacity - 1))
    }
    
    private func unpackUnorm(_ value: UInt32, bits: UInt) -> Float {
        let t: UInt32 = (1 << bits) - 1
        return Float(value & t) / Float(t)
    }
    
    private func unpackRot(_ value: UInt32) throws -> SIMD4<Float> {
        let norm: Float = 1.0 / (sqrtf(2.0) * 0.5)
        let a = (unpackUnorm(value >> 20, bits: 10) - 0.5) * norm
        let b = (unpackUnorm(value >> 10, bits: 10) - 0.5) * norm
        let c = (unpackUnorm(value, bits: 10) - 0.5) * norm
        let m = sqrtf(1.0 - (a*a + b*b + c*c))
        
        switch value >> 30 {
        case 0:
            return SIMD4<Float>(m, a, b, c)
        case 1:
            return SIMD4<Float>(a, m, b, c)
        case 2:
            return SIMD4<Float>(a, b, m, c)
        case 3:
            return SIMD4<Float>(a, b, c, m)
        default:
            throw SplatPLYSceneReader.Error.unsupportedFileContents("Can't unpack rotation")
        }
    }
    
    private func lerp(a: Float, b: Float, t: Float) -> Float {
        return a * (1 - t) + b * t
    }
}

private extension PLYHeader.Element {
    func hasProperty(forName name: String, type: PLYHeader.PrimitivePropertyType? = nil) -> Bool {
        guard let index = index(forPropertyNamed: name) else {
            return false
        }

        if let type {
            guard case .primitive(type) = properties[index].type else {
                return false
            }
        }

        return true
    }

    func hasProperty(forName names: [String], type: PLYHeader.PrimitivePropertyType? = nil) -> Bool {
        for name in names {
            if hasProperty(forName: name, type: type) {
                return true
            }
        }
        return false
    }

    func index(forOptionalPropertyNamed names: [String], type: PLYHeader.PrimitivePropertyType) throws -> Int? {
        for name in names {
            if let index = index(forPropertyNamed: name) {
                guard case .primitive(type) = properties[index].type else { throw SplatPLYSceneReader.Error.unsupportedFileContents("Unexpected type for property \"\(name)\"") }
                return index
            }
        }
        return nil
    }

    func index(forPropertyNamed names: [String], type: PLYHeader.PrimitivePropertyType) throws -> Int {
        guard let result = try index(forOptionalPropertyNamed: names, type: type) else {
            throw SplatPLYSceneReader.Error.unsupportedFileContents("No property named \"\(names.first ?? "(none)")\" found")
        }
        return result
    }

    func index(forOptionalFloat32PropertyNamed names: [String]) throws -> Int? {
        try index(forOptionalPropertyNamed: names, type: .float32)
    }

    func index(forFloat32PropertyNamed names: [String]) throws -> Int {
        try index(forPropertyNamed: names, type: .float32)
    }
}

private extension PLYElement {
    func float32Value(forPropertyIndex propertyIndex: Int) throws -> Float {
        guard case .float32(let typedValue) = properties[propertyIndex] else { throw SplatPLYSceneReader.Error.internalConsistency("Unexpected type for property at index \(propertyIndex)") }
        return typedValue
    }

    func uint8Value(forPropertyIndex propertyIndex: Int) throws -> UInt8 {
        guard case .uint8(let typedValue) = properties[propertyIndex] else { throw SplatPLYSceneReader.Error.internalConsistency("Unexpected type for property at index \(propertyIndex)") }
        return typedValue
    }
    
    func uint32Value(forPropertyIndex propertyIndex: Int) throws -> UInt32 {
        guard case .uint32(let typedValue) = properties[propertyIndex] else { throw SplatPLYSceneReader.Error.internalConsistency("Unexpected type for property at index \(propertyIndex)") }
        return typedValue
    }
}
