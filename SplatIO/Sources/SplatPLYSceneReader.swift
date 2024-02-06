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

    public convenience init(_ url: URL) {
        self.init(PLYReader(url))
    }

    public init(_ ply: PLYReader) {
        self.ply = ply
    }

    public func read(to delegate: SplatSceneReaderDelegate) {
        SplatPLYSceneReaderStream().read(ply, to: delegate)
    }
}

private class SplatPLYSceneReaderStream {
    private weak var delegate: SplatSceneReaderDelegate? = nil
    private var active = false
    private var pointElementMapping: PointElementMapping?
    private var expectedPointCount: UInt32 = 0
    private var pointCount: UInt32 = 0
    private var reusablePoint = SplatScenePoint(position: .zero, normal: .zero, color: .none, opacity: .zero, scale: .zero, rotation: .init(vector: .zero))

    func read(_ ply: PLYReader, to delegate: SplatSceneReaderDelegate) {
        self.delegate = delegate
        active = true
        pointElementMapping = nil
        expectedPointCount = 0
        pointCount = 0

        ply.read(to: self)

        assert(!active)
    }
}

extension SplatPLYSceneReaderStream: PLYReaderDelegate {
    func didStartReading(withHeader header: PLYHeader) {
        guard active else { return }
        guard pointElementMapping == nil else {
            delegate?.didFailReading(withError: SplatPLYSceneReader.Error.internalConsistency("didStart called while pointElementMapping is non-nil"))
            active = false
            return
        }

        do {
            let pointElementMapping = try PointElementMapping.pointElementMapping(for: header)
            self.pointElementMapping = pointElementMapping
            expectedPointCount = header.elements[pointElementMapping.elementTypeIndex].count
            delegate?.didStartReading(withPointCount: expectedPointCount)
        } catch {
            delegate?.didFailReading(withError: error)
            active = false
            return
        }
    }

    func didRead(element: PLYElement, typeIndex: Int, withHeader elementHeader: PLYHeader.Element) {
        guard active else { return }
        guard let pointElementMapping else {
            delegate?.didFailReading(withError: SplatPLYSceneReader.Error.internalConsistency("didRead(element:typeIndex:withHeader:) called but pointElementMapping is nil"))
            active = false
            return
        }

        guard typeIndex == pointElementMapping.elementTypeIndex else { return }
        do {
            try pointElementMapping.apply(from: element, to: &reusablePoint)
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

private struct PointElementMapping {
    enum ElementName: String {
        case point = "vertex"
    }

    enum PropertyName {
        static let positionX = [ "x" ]
        static let positionY = [ "y" ]
        static let positionZ = [ "z" ]
        static let normalX = [ "nx", "nxx" ]
        static let normalY = [ "ny" ]
        static let normalZ = [ "nz" ]
        static let sh0_r = [ "f_dc_0" ]
        static let sh0_g = [ "f_dc_1" ]
        static let sh0_b = [ "f_dc_2" ]
        static let sphericalHarmonicsPrefix = "f_rest_"
        static let colorR = [ "red" ]
        static let colorG = [ "green" ]
        static let colorB = [ "blue" ]
        static let scaleX = [ "scale_0" ]
        static let scaleY = [ "scale_1" ]
        static let scaleZ = [ "scale_2" ]
        static let opacity = [ "opacity" ]
        static let rotationI = [ "rot_0" ]
        static let rotationJ = [ "rot_1" ]
        static let rotationK = [ "rot_2" ]
        static let rotationW = [ "rot_3" ]
    }

    public enum Color {
        case sphericalHarmonic(Int, Int, Int, [Int])
        case firstOrderSphericalHarmonic(Int, Int, Int)
        case linearFloat(Int, Int, Int)
        case linearUInt8(Int, Int, Int)
    }

    static let sphericalHarmonicsCount = 45

    let elementTypeIndex: Int

    let positionXPropertyIndex: Int
    let positionYPropertyIndex: Int
    let positionZPropertyIndex: Int
    let normalXPropertyIndex: Int
    let normalYPropertyIndex: Int
    let normalZPropertyIndex: Int
    let colorPropertyIndices: Color
    let scaleXPropertyIndex: Int
    let scaleYPropertyIndex: Int
    let scaleZPropertyIndex: Int
    let opacityPropertyIndex: Int
    let rotationIPropertyIndex: Int
    let rotationJPropertyIndex: Int
    let rotationKPropertyIndex: Int
    let rotationWPropertyIndex: Int

    static func pointElementMapping(for header: PLYHeader) throws -> PointElementMapping {
        guard let elementTypeIndex = header.index(forElementNamed: ElementName.point.rawValue) else {
            throw SplatPLYSceneReader.Error.unsupportedFileContents("No element type \"\(ElementName.point.rawValue)\" found")
        }
        let headerElement = header.elements[elementTypeIndex]

        let positionXPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.positionX)
        let positionYPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.positionY)
        let positionZPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.positionZ)
        let normalXPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.normalX)
        let normalYPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.normalY)
        let normalZPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.normalZ)

        let color: Color
        if let sh0_rPropertyIndex = try headerElement.index(forOptionalFloat32PropertyNamed: PropertyName.sh0_r),
           let sh0_gPropertyIndex = try headerElement.index(forOptionalFloat32PropertyNamed: PropertyName.sh0_g),
            let sh0_bPropertyIndex = try headerElement.index(forOptionalFloat32PropertyNamed: PropertyName.sh0_b) {
            let sphericalHarmonicsPropertyIndices: [Int]
            if headerElement.hasProperty(forName: "\(PropertyName.sphericalHarmonicsPrefix)0") {
                sphericalHarmonicsPropertyIndices = try (0..<sphericalHarmonicsCount).map {
                    try headerElement.index(forFloat32PropertyNamed: [ "\(PropertyName.sphericalHarmonicsPrefix)\($0)" ])
                }
                color = .sphericalHarmonic(sh0_rPropertyIndex, sh0_gPropertyIndex, sh0_bPropertyIndex, sphericalHarmonicsPropertyIndices)
            } else {
                color = .firstOrderSphericalHarmonic(sh0_rPropertyIndex, sh0_gPropertyIndex, sh0_bPropertyIndex)
            }
        } else if headerElement.hasProperty(forName: PropertyName.colorR, type: .float32) &&
                    headerElement.hasProperty(forName: PropertyName.colorG, type: .float32) &&
                    headerElement.hasProperty(forName: PropertyName.colorB, type: .float32) {
            let colorRPropertyIndex = try headerElement.index(forPropertyNamed: PropertyName.colorR, type: .float32)
            let colorGPropertyIndex = try headerElement.index(forPropertyNamed: PropertyName.colorG, type: .float32)
            let colorBPropertyIndex = try headerElement.index(forPropertyNamed: PropertyName.colorB, type: .float32)
            color = .linearFloat(colorRPropertyIndex, colorGPropertyIndex, colorBPropertyIndex)
        } else if headerElement.hasProperty(forName: PropertyName.colorR, type: .uint8) &&
                    headerElement.hasProperty(forName: PropertyName.colorG, type: .uint8) &&
                    headerElement.hasProperty(forName: PropertyName.colorB, type: .uint8) {
            let colorRPropertyIndex = try headerElement.index(forPropertyNamed: PropertyName.colorR, type: .uint8)
            let colorGPropertyIndex = try headerElement.index(forPropertyNamed: PropertyName.colorG, type: .uint8)
            let colorBPropertyIndex = try headerElement.index(forPropertyNamed: PropertyName.colorB, type: .uint8)
            color = .linearUInt8(colorRPropertyIndex, colorGPropertyIndex, colorBPropertyIndex)
        } else {
            throw SplatPLYSceneReader.Error.unsupportedFileContents("No color property elements found with the expected types")
        }


        let scaleXPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.scaleX)
        let scaleYPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.scaleY)
        let scaleZPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.scaleZ)
        let opacityPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.opacity)

        let rotationIPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.rotationI)
        let rotationJPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.rotationJ)
        let rotationKPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.rotationK)
        let rotationWPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.rotationW)

        return PointElementMapping(elementTypeIndex: elementTypeIndex,
                                   positionXPropertyIndex: positionXPropertyIndex,
                                   positionYPropertyIndex: positionYPropertyIndex,
                                   positionZPropertyIndex: positionZPropertyIndex,
                                   normalXPropertyIndex: normalXPropertyIndex,
                                   normalYPropertyIndex: normalYPropertyIndex,
                                   normalZPropertyIndex: normalZPropertyIndex,
                                   colorPropertyIndices: color,
                                   scaleXPropertyIndex: scaleXPropertyIndex,
                                   scaleYPropertyIndex: scaleYPropertyIndex,
                                   scaleZPropertyIndex: scaleZPropertyIndex,
                                   opacityPropertyIndex: opacityPropertyIndex,
                                   rotationIPropertyIndex: rotationIPropertyIndex,
                                   rotationJPropertyIndex: rotationJPropertyIndex,
                                   rotationKPropertyIndex: rotationKPropertyIndex,
                                   rotationWPropertyIndex: rotationWPropertyIndex)
    }

    func apply(from element: PLYElement, to result: inout SplatScenePoint) throws {
        result.position.x = try element.float32Value(forPropertyIndex: positionXPropertyIndex)
        result.position.y = try element.float32Value(forPropertyIndex: positionYPropertyIndex)
        result.position.z = try element.float32Value(forPropertyIndex: positionZPropertyIndex)
        result.normal.x = try element.float32Value(forPropertyIndex: normalXPropertyIndex)
        result.normal.y = try element.float32Value(forPropertyIndex: normalYPropertyIndex)
        result.normal.z = try element.float32Value(forPropertyIndex: normalZPropertyIndex)

        switch colorPropertyIndices {
        case .sphericalHarmonic(let r, let g, let b, let sphericalHarmonicsPropertyIndices):
            var shValues =
                result.color.nonFirstOrderSphericalHarmonics ??
                Array(repeating: .zero, count: sphericalHarmonicsPropertyIndices.count)
            if shValues.count != sphericalHarmonicsPropertyIndices.count {
                shValues = Array(repeating: .zero, count: sphericalHarmonicsPropertyIndices.count)
            }
            for i in 0..<sphericalHarmonicsPropertyIndices.count {
                shValues[i] = try element.float32Value(forPropertyIndex: sphericalHarmonicsPropertyIndices[i])
            }
            result.color = .sphericalHarmonic(try element.float32Value(forPropertyIndex: r),
                                              try element.float32Value(forPropertyIndex: g),
                                              try element.float32Value(forPropertyIndex: b),
                                              shValues)
        case .firstOrderSphericalHarmonic(let r, let g, let b):
            result.color = .firstOrderSphericalHarmonic(try element.float32Value(forPropertyIndex: r),
                                                        try element.float32Value(forPropertyIndex: g),
                                                        try element.float32Value(forPropertyIndex: b))
        case .linearFloat(let r, let g, let b):
            result.color = .linearFloat(try element.float32Value(forPropertyIndex: r),
                                        try element.float32Value(forPropertyIndex: g),
                                        try element.float32Value(forPropertyIndex: b))
        case .linearUInt8(let r, let g, let b):
            result.color = .linearUInt8(try element.uint8Value(forPropertyIndex: r),
                                        try element.uint8Value(forPropertyIndex: g),
                                        try element.uint8Value(forPropertyIndex: b))
        }

        result.scale.x = try element.float32Value(forPropertyIndex: scaleXPropertyIndex)
        result.scale.y = try element.float32Value(forPropertyIndex: scaleYPropertyIndex)
        result.scale.z = try element.float32Value(forPropertyIndex: scaleZPropertyIndex)
        result.opacity = try element.float32Value(forPropertyIndex: opacityPropertyIndex)
        result.rotation.vector.x = try element.float32Value(forPropertyIndex: rotationIPropertyIndex)
        result.rotation.vector.y = try element.float32Value(forPropertyIndex: rotationJPropertyIndex)
        result.rotation.vector.z = try element.float32Value(forPropertyIndex: rotationKPropertyIndex)
        result.rotation.vector.w = try element.float32Value(forPropertyIndex: rotationWPropertyIndex)
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
}
