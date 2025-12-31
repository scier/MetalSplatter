import XCTest
import PLYIO
import Spatial

final class PLYIOTests: XCTestCase {
    class ContentStorage {
        static func testApproximatelyEqual(lhs: ContentStorage, rhs: ContentStorage) {
            var rhsForgedHeader = rhs.header
            rhsForgedHeader?.format = lhs.header?.format ?? .ascii
            XCTAssertEqual(lhs.header, rhsForgedHeader)

            XCTAssertEqual(lhs.elements.count, rhs.elements.count, "Same number of elements")
            for elementTypeIndex in 0..<lhs.elements.count {
                let lhsElements = lhs.elements[elementTypeIndex]
                let rhsElements = rhs.elements[elementTypeIndex]
                XCTAssertEqual(lhsElements.count, rhsElements.count, "Same number of instances of element type index \(elementTypeIndex)")
                for (lhsElement, rhsElement) in zip(lhsElements, rhsElements) {
                    XCTAssertEqual(lhsElement.properties.count, rhsElement.properties.count, "Same number of properties in element type index \(elementTypeIndex)")
                    for (lhsProperty, rhsProperty) in zip(lhsElement.properties, rhsElement.properties) {
                        XCTAssertTrue(lhsProperty ~= rhsProperty, "Property \(lhsProperty) != \(rhsProperty)")
                    }
                }
            }
        }

        var header: PLYHeader? = nil
        var elements: [[PLYElement]] = []

        init(_ reader: PLYReader) async throws {
            let (header, elementStream) = try await reader.read()
            self.header = header
            self.elements = Array(repeating: [], count: header.self.elements.count)
            for try await elementSeries in elementStream {
                elements[elementSeries.typeIndex].append(contentsOf: elementSeries.elements)
            }
        }
    }

    let asciiURL = Bundle.module.url(forResource: "beetle.ascii", withExtension: "ply", subdirectory: "TestData")!
    let binaryURL = Bundle.module.url(forResource: "beetle.binary", withExtension: "ply", subdirectory: "TestData")!

    func testReadASCII() async throws {
        try await testRead(asciiURL)
    }

    func testReadBinary() async throws {
        try await testRead(binaryURL)
    }

    func testASCIIBinaryEqual() async throws {
        try await testEqual(asciiURL, binaryURL)
    }

    func testRewriteASCII() async throws {
        try await testReadWriteRead(asciiURL, writeFormat: .ascii)
        try await testReadWriteRead(asciiURL, writeFormat: .binaryBigEndian)
        try await testReadWriteRead(asciiURL, writeFormat: .binaryLittleEndian)
    }

    func testRewriteBinary() async throws {
        try await testReadWriteRead(binaryURL, writeFormat: .ascii)
        try await testReadWriteRead(binaryURL, writeFormat: .binaryBigEndian)
        try await testReadWriteRead(binaryURL, writeFormat: .binaryLittleEndian)
    }

    func testEqual(_ urlA: URL, _ urlB: URL) async throws {
        let readerA = try PLYReader(urlA)
        let contentA = try await ContentStorage(readerA)

        let readerB = try PLYReader(urlB)
        let contentB = try await ContentStorage(readerB)

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB)
    }

    func testReadWriteRead(_ url: URL, writeFormat: PLYHeader.Format) async throws {
        let readerA = try PLYReader(url)
        let contentA = try await ContentStorage(readerA)

        let writer = try PLYWriter(to: .memory)
        guard var header = contentA.header else {
            XCTFail("Failed to read input from \(url)")
            return
        }
        header.format = writeFormat
        let elements = Array(contentA.elements.joined())
        try await writer.write(header)
        try await writer.write(elements)
        try await writer.close()
        guard let writtenData = await writer.writtenData else {
            XCTFail("Failed to get written data from memory writer")
            return
        }

        let readerB = try PLYReader(writtenData)
        let contentB = try await ContentStorage(readerB)

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB)
    }

    func testRead(_ url: URL) async throws {
        let reader = try PLYReader(url)

        let (header, elements) = try await reader.read()
        var elementCounts: [Int] = Array.init(repeating: 0, count: header.elements.count)
        for try await elementSeries in elements {
            XCTAssertGreaterThanOrEqual(elementSeries.typeIndex, 0)
            XCTAssertLessThan(elementSeries.typeIndex, header.elements.count)
            elementCounts[elementSeries.typeIndex] += elementSeries.elements.count
        }
        for (elementTypeIndex, element) in header.elements.enumerated() {
            XCTAssertEqual(Int(element.count), elementCounts[elementTypeIndex])
        }
    }
}

fileprivate let float32Tolerance: Float = 1e-10
fileprivate let float64Tolerance: Double = 1e-20

extension PLYElement.Property {
    public static func ~= (lhs: PLYElement.Property, rhs: PLYElement.Property) -> Bool {
        switch (lhs, rhs) {
        case let (.int8(lhsValue), .int8(rhsValue)): lhsValue == rhsValue
        case let (.uint8(lhsValue), .uint8(rhsValue)): lhsValue == rhsValue
        case let (.int16(lhsValue), .int16(rhsValue)): lhsValue == rhsValue
        case let (.uint16(lhsValue), .uint16(rhsValue)): lhsValue == rhsValue
        case let (.int32(lhsValue), .int32(rhsValue)): lhsValue == rhsValue
        case let (.uint32(lhsValue), .uint32(rhsValue)): lhsValue == rhsValue
        case let (.float32(lhsValue), .float32(rhsValue)): abs(lhsValue - rhsValue) < float32Tolerance
        case let (.float64(lhsValue), .float64(rhsValue)): abs(lhsValue - rhsValue) < float64Tolerance
        case let (.listInt8(lhsValues), .listInt8(rhsValues)): lhsValues == rhsValues
        case let (.listUInt8(lhsValues), .listUInt8(rhsValues)): lhsValues == rhsValues
        case let (.listInt16(lhsValues), .listInt16(rhsValues)): lhsValues == rhsValues
        case let (.listUInt16(lhsValues), .listUInt16(rhsValues)): lhsValues == rhsValues
        case let (.listInt32(lhsValues), .listInt32(rhsValues)): lhsValues == rhsValues
        case let (.listUInt32(lhsValues), .listUInt32(rhsValues)): lhsValues == rhsValues
        case let (.listFloat32(lhsValues), .listFloat32(rhsValues)):
            lhsValues.count == rhsValues.count &&
            zip(lhsValues, rhsValues).allSatisfy { abs($0.1 - $0.0) < float32Tolerance }
        case let (.listFloat64(lhsValues), .listFloat64(rhsValues)):
            lhsValues.count == rhsValues.count &&
            zip(lhsValues, rhsValues).allSatisfy { abs($0.1 - $0.0) < float64Tolerance }
        default:
            false
        }
    }
}
