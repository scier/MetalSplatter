import Foundation
import PLYIO

public class SplatPLYSceneReader: SplatSceneReader {
    enum Error: Swift.Error {
        case unsupportedFileContents(String?)
        case unexpectedPointCountDiscrepancy
        case internalConsistency(String?)
        case pointElementPropertyValueMissingOrInvalid(String)
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
    private var reusablePoint = SplatScenePoint(position: .zero, normal: .zero, color: .zero, opacity: .zero, scale: .zero, rotation: .init(vector: .zero))

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

    enum PropertyName: String {
        case positionX = "x"
        case positionY = "y"
        case positionZ = "z"
        case normalX = "nx"
        case normalY = "ny"
        case normalZ = "nz"
        case colorR = "f_dc_0"
        case colorG = "f_dc_1"
        case colorB = "f_dc_2"
        case sphericalHarmonicsPrefix = "f_rest_"
        case scaleX = "scale_0"
        case scaleY = "scale_1"
        case scaleZ = "scale_2"
        case opacity = "opacity"
        case rotationI = "rot_0"
        case rotationJ = "rot_1"
        case rotationK = "rot_2"
        case rotationW = "rot_3"
    }

    static let sphericalHarmonicsCount = 45

    let elementTypeIndex: Int

    let positionXPropertyIndex: Int
    let positionYPropertyIndex: Int
    let positionZPropertyIndex: Int
    let normalXPropertyIndex: Int
    let normalYPropertyIndex: Int
    let normalZPropertyIndex: Int
    let colorRPropertyIndex: Int
    let colorGPropertyIndex: Int
    let colorBPropertyIndex: Int
    let sphericalHarmonicsPropertyIndices: [Int]
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

        let positionXPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.positionX.rawValue)
        let positionYPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.positionY.rawValue)
        let positionZPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.positionZ.rawValue)
        let normalXPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.normalX.rawValue)
        let normalYPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.normalX.rawValue)
        let normalZPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.normalX.rawValue)
        let colorRPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.colorR.rawValue)
        let colorGPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.colorG.rawValue)
        let colorBPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.colorB.rawValue)

        let sphericalHarmonicsPropertyIndices: [Int]
        if headerElement.hasProperty(forName: "\(PropertyName.sphericalHarmonicsPrefix.rawValue)0") {
            sphericalHarmonicsPropertyIndices = try (0..<sphericalHarmonicsCount).map { try headerElement.index(forFloat32PropertyNamed: "\(PropertyName.sphericalHarmonicsPrefix.rawValue)\($0)") }
        } else {
            sphericalHarmonicsPropertyIndices = []
        }

        let scaleXPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.scaleX.rawValue)
        let scaleYPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.scaleY.rawValue)
        let scaleZPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.scaleZ.rawValue)
        let opacityPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.opacity.rawValue)

        let rotationIPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.rotationI.rawValue)
        let rotationJPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.rotationJ.rawValue)
        let rotationKPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.rotationK.rawValue)
        let rotationWPropertyIndex = try headerElement.index(forFloat32PropertyNamed: PropertyName.rotationW.rawValue)

        return PointElementMapping(elementTypeIndex: elementTypeIndex,
                                   positionXPropertyIndex: positionXPropertyIndex,
                                   positionYPropertyIndex: positionYPropertyIndex,
                                   positionZPropertyIndex: positionZPropertyIndex,
                                   normalXPropertyIndex: normalXPropertyIndex,
                                   normalYPropertyIndex: normalYPropertyIndex,
                                   normalZPropertyIndex: normalZPropertyIndex,
                                   colorRPropertyIndex: colorRPropertyIndex,
                                   colorGPropertyIndex: colorGPropertyIndex,
                                   colorBPropertyIndex: colorBPropertyIndex,
                                   sphericalHarmonicsPropertyIndices: sphericalHarmonicsPropertyIndices,
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
        result.color.x = try element.float32Value(forPropertyIndex: colorRPropertyIndex)
        result.color.y = try element.float32Value(forPropertyIndex: colorGPropertyIndex)
        result.color.z = try element.float32Value(forPropertyIndex: colorBPropertyIndex)
        if sphericalHarmonicsPropertyIndices.isEmpty {
            result.sphericalHarmonics = nil
        } else {
            if result.sphericalHarmonics?.count != sphericalHarmonicsPropertyIndices.count {
                result.sphericalHarmonics = Array(repeating: .zero, count: sphericalHarmonicsPropertyIndices.count)
            }
            for i in 0..<sphericalHarmonicsPropertyIndices.count {
                result.sphericalHarmonics?[i] = try element.float32Value(forPropertyIndex: sphericalHarmonicsPropertyIndices[i])
            }
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
    func hasProperty(forName name: String) -> Bool {
        index(forPropertyNamed: name) != nil
    }

    func index(forFloat32PropertyNamed name: String) throws -> Int {
        guard let index = index(forPropertyNamed: name) else { throw SplatPLYSceneReader.Error.unsupportedFileContents("No property named \"\(name)\" found") }
        guard case .primitive(.float32) = properties[index].type else { throw SplatPLYSceneReader.Error.unsupportedFileContents("Unexpected type for property \"\(name)\"") }
        return index
    }
}

private extension PLYElement {
    func float32Value(forPropertyIndex propertyIndex: Int) throws -> Float {
        guard case .float32(let typedValue) = properties[propertyIndex] else { throw SplatPLYSceneReader.Error.internalConsistency("Unexpected type for property at index \(propertyIndex)") }
        return typedValue
    }
}
