import Foundation
import PLYIO
import simd

public class SplatPLYSceneWriter: SplatSceneWriter {
    public enum Error: Swift.Error {
        case cannotWriteToFile(String)
        case unknownOutputStreamError
        case alreadyStarted
        case notStarted
        case cannotWriteAfterClose
        case unexpectedPoints
    }

    public enum Constants {
        public static let defaultSphericalHarmonicDegree: UInt = 3
        public static let defaultBinary = true
        public static let elementBufferSize = 1000 // Write 1000 elements at a time
    }

    private let plyWriter: PLYWriter

    private var totalPointCount = 0
    private var pointsWritten = 0
    private var closed = false

    private var elementBuffer: [PLYElement] = Array.init(repeating: PLYElement(properties: []), count: Constants.elementBufferSize)
    private var elementMapping: ElementOutputMapping?

    public init(to destination: WriterDestination) throws {
        plyWriter = try PLYWriter(to: destination)
    }

    public convenience init(toFileAtPath path: String) throws {
        try self.init(to: .file(URL(fileURLWithPath: path)))
    }

    public func close() async throws {
        guard !closed else { return }
        closed = true
        try await plyWriter.close()
    }

    public var writtenData: Data? {
        get async {
            await plyWriter.writtenData
        }
    }

    public func start(sphericalHarmonicDegree: UInt = Constants.defaultSphericalHarmonicDegree,
                      binary: Bool = Constants.defaultBinary,
                      pointCount: Int) async throws {
        guard elementMapping == nil else {
            throw Error.alreadyStarted
        }

        let elementMapping = ElementOutputMapping(sphericalHarmonicDegree: sphericalHarmonicDegree)
        let header = elementMapping.createHeader(format: binary ? .binaryLittleEndian : .ascii, pointCount: pointCount)
        try await plyWriter.write(header)

        self.totalPointCount = pointCount
        self.elementMapping = elementMapping
    }

    public func write(_ points: [SplatScenePoint]) async throws {
        guard let elementMapping else {
            throw Error.notStarted
        }
        guard !closed else {
            throw Error.cannotWriteAfterClose
        }

        guard points.count + pointsWritten <= totalPointCount else {
            throw Error.unexpectedPoints
        }

        var elementBufferOffset = 0
        for (i, point) in points.enumerated() {
            elementBuffer[elementBufferOffset].set(to: point, with: elementMapping)
            elementBufferOffset += 1
            if elementBufferOffset == elementBuffer.count || i == points.count-1 {
                try await plyWriter.write(elementBuffer, count: elementBufferOffset)
                elementBufferOffset = 0
            }
        }

        pointsWritten += points.count
    }
}

private struct ElementOutputMapping {
    var sphericalHarmonicDegree: UInt

    var indirectColorCount: Int {
        switch sphericalHarmonicDegree {
        case 0: 0
        case 1: 3
        case 2: 3 + 5
        case 3: 3 + 5 + 7
        default: 0
        }
    }

    func createHeader(format: PLYHeader.Format, pointCount: Int) -> PLYHeader {
        var properties: [PLYHeader.Property] = []

        let appendProperty = { (name: String, type: PLYHeader.PrimitivePropertyType) in
            properties.append(.init(name: name, type: .primitive(type)))
        }
        appendProperty(SplatPLYConstants.PropertyName.positionX.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.positionY.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.positionZ.first!, .float32)

        appendProperty(SplatPLYConstants.PropertyName.normalX.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.normalY.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.normalZ.first!, .float32)

        appendProperty(SplatPLYConstants.PropertyName.sh0_r.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.sh0_g.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.sh0_b.first!, .float32)

        for i in 0..<(indirectColorCount*3) {
            appendProperty("\(SplatPLYConstants.PropertyName.sphericalHarmonicsPrefix)\(i)", .float32)
        }
        appendProperty(SplatPLYConstants.PropertyName.opacity.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.scaleX.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.scaleY.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.scaleZ.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.rotation0.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.rotation1.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.rotation2.first!, .float32)
        appendProperty(SplatPLYConstants.PropertyName.rotation3.first!, .float32)

        let element = PLYHeader.Element(name: SplatPLYConstants.ElementName.point.rawValue,
                                        count: UInt32(pointCount),
                                        properties: properties)
        return PLYHeader(format: format, version: "1.0", elements: [ element ])
    }
}

fileprivate extension PLYElement {
    mutating func set(to point: SplatScenePoint, with mapping: ElementOutputMapping) {
        var propertyCount = 0

        func appendProperty(_ value: Float) {
            if properties.count == propertyCount {
                properties.append(.float32(value))
            } else {
                properties[propertyCount] = .float32(value)
            }
            propertyCount += 1
        }

        // Position
        appendProperty(point.position.x)
        appendProperty(point.position.y)
        appendProperty(point.position.z)

        // Normal
        appendProperty(0)
        appendProperty(0)
        appendProperty(1)

        // Color
        let color = point.color.asSphericalHarmonicFloat
        let directColor = color.first ?? .zero
        appendProperty(directColor.x)
        appendProperty(directColor.y)
        appendProperty(directColor.z)

        // PLY format stores SH coefficients channel-by-channel: all R, then all G, then all B.
        // Our internal format is RGB-interleaved, so we need to deinterleave on write.
        for i in 0..<mapping.indirectColorCount {
            let shColorIndex = (1 + i)
            let shColor = shColorIndex >= color.count ? .zero : color[shColorIndex]
            appendProperty(shColor.x)  // R channel
        }
        for i in 0..<mapping.indirectColorCount {
            let shColorIndex = (1 + i)
            let shColor = shColorIndex >= color.count ? .zero : color[shColorIndex]
            appendProperty(shColor.y)  // G channel
        }
        for i in 0..<mapping.indirectColorCount {
            let shColorIndex = (1 + i)
            let shColor = shColorIndex >= color.count ? .zero : color[shColorIndex]
            appendProperty(shColor.z)  // B channel
        }

        // Opacity
        appendProperty(point.opacity.asLogitFloat)

        // Scale
        let scale = point.scale.asExponent
        appendProperty(scale.x)
        appendProperty(scale.y)
        appendProperty(scale.z)

        // Rotation
        appendProperty(point.rotation.real)
        appendProperty(point.rotation.imag.x)
        appendProperty(point.rotation.imag.y)
        appendProperty(point.rotation.imag.z)

        if propertyCount > properties.count {
            properties = properties.dropLast(properties.count - propertyCount)
        }
    }
}
