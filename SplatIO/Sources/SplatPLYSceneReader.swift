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

    private let source: ReaderSource

    public init(_ url: URL) throws {
        guard url.isFileURL else {
            throw ReaderSource.Error.cannotOpen(url: url)
        }
        self.source = .url(url)
    }

    public init(_ data: Data) throws {
        self.source = .memory(data)
    }

    public func read() async throws -> AsyncThrowingStream<[SplatPoint], Swift.Error> {
        let (header, plyStream) = try await PLYReader(source).read()

        let elementMapping = try ElementInputMapping.elementMapping(for: header)

        // TODO SCIER: report expected point count
        return AsyncThrowingStream { continuation in
            Task {
                var points = [SplatPoint]()

                for try await plyStreamElementSeries in plyStream {
                    var pointCount = 0
                    // Skip non-vertex element types (e.g. face, extrinsic, intrinsic metadata)
                    guard plyStreamElementSeries.typeIndex == elementMapping.elementTypeIndex else {
                        continue
                    }

                    do {
                        for element in plyStreamElementSeries.elements {
                            if points.count == pointCount {
                                points.append(SplatPoint(position: .zero,
                                                              color: .sRGBUInt8(.zero),
                                                              opacity: .linearFloat(.zero),
                                                              scale: .exponent(.zero),
                                                              rotation: .init(vector: .zero)))
                            }

                            try points[pointCount].apply(elementMapping, from: element)
                            pointCount += 1
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }

                    continuation.yield(Array(points.prefix(pointCount)))
                }
                
                // TODO SCIER: validate expected point count
                continuation.finish()
            }
        }
    }
}

private struct ElementInputMapping {
    public enum Color {
        case sphericalHarmonicFloat([SIMD3<Int>])
        case sRGBFloat256(SIMD3<Int>)  // Legacy NeRF Studio format, normalized on read
        case sRGBUInt8(SIMD3<Int>)
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
                // PLY files store SH coefficients channel-by-channel (all R, then all G, then all B),
                // but we need them RGB-interleaved. Reorganize the indices accordingly.
                // For 45 f_rest properties: R=0-14, G=15-29, B=30-44
                // Coefficient i maps to: (R[i], G[i], B[i]) = (i, i+15, i+30)
                let coeffsPerChannel = individualSphericalHarmonicsPropertyIndices.count / 3
                let sphericalHarmonicsPropertyIndices: [SIMD3<Int>] = (0..<coeffsPerChannel).map { i in
                    SIMD3<Int>(individualSphericalHarmonicsPropertyIndices[i],
                               individualSphericalHarmonicsPropertyIndices[i + coeffsPerChannel],
                               individualSphericalHarmonicsPropertyIndices[i + 2 * coeffsPerChannel])
                }
                color = .sphericalHarmonicFloat([primaryColorPropertyIndices] + sphericalHarmonicsPropertyIndices)
            } else {
                color = .sphericalHarmonicFloat([primaryColorPropertyIndices])
            }
        } else if headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorR, type: .float32) &&
                    headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorG, type: .float32) &&
                    headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorB, type: .float32) {
            // Special case for legacy NeRF Studio SH=0 files
            let colorRPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorR, type: .float32)
            let colorGPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorG, type: .float32)
            let colorBPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorB, type: .float32)
            color = .sRGBFloat256(SIMD3(colorRPropertyIndex, colorGPropertyIndex, colorBPropertyIndex))
        } else if headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorR, type: .uint8) &&
                    headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorG, type: .uint8) &&
                    headerElement.hasProperty(forName: SplatPLYConstants.PropertyName.colorB, type: .uint8) {
            let colorRPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorR, type: .uint8)
            let colorGPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorG, type: .uint8)
            let colorBPropertyIndex = try headerElement.index(forPropertyNamed: SplatPLYConstants.PropertyName.colorB, type: .uint8)
            color = .sRGBUInt8(SIMD3(colorRPropertyIndex, colorGPropertyIndex, colorBPropertyIndex))
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
}

private extension SplatPoint {
    mutating func apply(_ mapping: ElementInputMapping, from element: PLYElement) throws {
        position = SIMD3(x: try element.float32Value(forPropertyIndex: mapping.positionXPropertyIndex),
                         y: try element.float32Value(forPropertyIndex: mapping.positionYPropertyIndex),
                         z: try element.float32Value(forPropertyIndex: mapping.positionZPropertyIndex))

        switch mapping.colorPropertyIndices {
        case .sphericalHarmonicFloat(let sphericalHarmonicsPropertyIndices):
            color = .sphericalHarmonicFloat(try sphericalHarmonicsPropertyIndices.map {
                try SIMD3<Float>(x: element.float32Value(forPropertyIndex: $0.x),
                                 y: element.float32Value(forPropertyIndex: $0.y),
                                 z: element.float32Value(forPropertyIndex: $0.z))
            })
        case .sRGBFloat256(let propertyIndices):
            // Legacy NeRF Studio format: normalize 0-256 float range to 0-255 uint8
            let floatValues = SIMD3<Float>(try element.float32Value(forPropertyIndex: propertyIndices.x),
                                           try element.float32Value(forPropertyIndex: propertyIndices.y),
                                           try element.float32Value(forPropertyIndex: propertyIndices.z))
            let scaled = floatValues / 256.0 * 255.0
            color = .sRGBUInt8(SIMD3<UInt8>(UInt8(scaled.x.clamped(to: 0...255)),
                                            UInt8(scaled.y.clamped(to: 0...255)),
                                            UInt8(scaled.z.clamped(to: 0...255))))
        case .sRGBUInt8(let propertyIndices):
            color = .sRGBUInt8(SIMD3(try element.uint8Value(forPropertyIndex: propertyIndices.x),
                                     try element.uint8Value(forPropertyIndex: propertyIndices.y),
                                     try element.uint8Value(forPropertyIndex: propertyIndices.z)))
        }

        scale =
            .exponent(SIMD3(try element.float32Value(forPropertyIndex: mapping.scaleXPropertyIndex),
                            try element.float32Value(forPropertyIndex: mapping.scaleYPropertyIndex),
                            try element.float32Value(forPropertyIndex: mapping.scaleZPropertyIndex)))
        opacity = .logitFloat(try element.float32Value(forPropertyIndex: mapping.opacityPropertyIndex))
        rotation.real   = try element.float32Value(forPropertyIndex: mapping.rotation0PropertyIndex)
        rotation.imag.x = try element.float32Value(forPropertyIndex: mapping.rotation1PropertyIndex)
        rotation.imag.y = try element.float32Value(forPropertyIndex: mapping.rotation2PropertyIndex)
        rotation.imag.z = try element.float32Value(forPropertyIndex: mapping.rotation3PropertyIndex)
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
