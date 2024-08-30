import XCTest
import PLYIO
import Spatial

final class PLYIOTests: XCTestCase {
    class ContentCounter: PLYReaderDelegate {
        var header: PLYHeader? = nil
        var elements: [Int] = []
        var didFinish = false
        var didFail = false

        func reset() {
            header = nil
            elements = []
            didFinish = false
            didFail = false
        }

        func didStartReading(withHeader header: PLYHeader) {
            self.header = header
            elements = Array(repeating: 0, count: header.elements.count)
        }

        func didRead(element: PLYIO.PLYElement, typeIndex: Int, withHeader elementHeader: PLYIO.PLYHeader.Element) {
            // XCTAssertEqual(elementHeader.name, header?.elements[typeIndex].name)
            elements[typeIndex] += 1
        }

        func didFinishReading() {
            didFinish = true
        }

        func didFailReading(withError error: Error?) {
            didFail = true
        }
    }

    class ContentStorage: PLYReaderDelegate {
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
        var didFinish = false
        var didFail = false

        func reset() {
            header = nil
            elements = []
            didFinish = false
            didFail = false
        }

        func didStartReading(withHeader header: PLYHeader) {
            self.header = header
            elements = Array(repeating: [], count: header.elements.count)
        }

        func didRead(element: PLYIO.PLYElement, typeIndex: Int, withHeader elementHeader: PLYIO.PLYHeader.Element) {
            // XCTAssertEqual(elementHeader.name, header?.elements[typeIndex].name)
            elements[typeIndex].append(element)
        }

        func didFinishReading() {
            didFinish = true
        }

        func didFailReading(withError error: Error?) {
            didFail = true
        }
    }

    let asciiURL = Bundle.module.url(forResource: "beetle.ascii", withExtension: "ply", subdirectory: "TestData")!
    let binaryURL = Bundle.module.url(forResource: "beetle.binary", withExtension: "ply", subdirectory: "TestData")!

    func testReadASCII() throws {
        try testRead(asciiURL)
    }

    func testReadBinary() throws {
        try testRead(binaryURL)
    }

    func testASCIIBinaryEqual() throws {
        try testEqual(asciiURL, binaryURL)
    }

    func testRewriteASCII() throws {
        try testReadWriteRead(asciiURL, writeFormat: .ascii)
        try testReadWriteRead(asciiURL, writeFormat: .binaryBigEndian)
        try testReadWriteRead(asciiURL, writeFormat: .binaryLittleEndian)
    }

    func testRewriteBinary() throws {
        try testReadWriteRead(binaryURL, writeFormat: .ascii)
        try testReadWriteRead(binaryURL, writeFormat: .binaryBigEndian)
        try testReadWriteRead(binaryURL, writeFormat: .binaryLittleEndian)
    }

    func testEqual(_ urlA: URL, _ urlB: URL) throws {
        let readerA = try PLYReader(urlA)
        let contentA = ContentStorage()
        readerA.read(to: contentA)

        let readerB = try PLYReader(urlB)
        let contentB = ContentStorage()
        readerB.read(to: contentB)

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB)
    }

    func testReadWriteRead(_ url: URL, writeFormat: PLYHeader.Format) throws {
        let readerA = try PLYReader(url)
        let contentA = ContentStorage()
        readerA.read(to: contentA)

        let memoryOutput = DataOutputStream()
        memoryOutput.open()
        let writer = PLYWriter(memoryOutput)
        guard var header = contentA.header else {
            XCTFail("Failed to read input from \(url)")
            return
        }
        header.format = writeFormat
        let elements = Array(contentA.elements.joined())
        try writer.write(header)
        try writer.write(elements)

        let memoryInput = InputStream(data: memoryOutput.data)
        memoryInput.open()

        let readerB = PLYReader(memoryInput)
        let contentB = ContentStorage()
        readerB.read(to: contentB)

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB)
    }

    func testRead(_ url: URL) throws {
        let reader = try PLYReader(url)

        let content = ContentCounter()
        reader.read(to: content)
        XCTAssertTrue(content.didFinish)
        XCTAssertFalse(content.didFail)
        XCTAssertNotNil(content.header)
        if let header = content.header {
            XCTAssertEqual(header.elements.count, content.elements.count)
            for (elementTypeIndex, element) in header.elements.enumerated() where elementTypeIndex < content.elements.count {
                XCTAssertEqual(Int(element.count), content.elements[elementTypeIndex])
            }
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

private class DataOutputStream: OutputStream {
    var data = Data()

    override func open() {}
    override func close() {}
    override var hasSpaceAvailable: Bool { true }

    override func write(_ buffer: UnsafePointer<UInt8>, maxLength length: Int) -> Int {
        data.append(buffer, count: length)
        return length
    }
}
