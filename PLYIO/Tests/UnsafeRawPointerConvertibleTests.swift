import XCTest
import PLYIO

final class UnsafeRawPointerConvertibleTests: XCTestCase {
    static let floatValue: Float = 42.17
    static let floatValueLittleEndianData = Data([ 0x14, 0xae, 0x28, 0x42 ])
    static let floatValueBigEndianData = Data([ 0x42, 0x28, 0xae, 0x14 ])
    static let floatValuesCount = 1024
    static let floatValuesLittleEndianData = Data([ 0x00 ]) + (0..<floatValuesCount).reduce(Data(), { data, _ in data + floatValueLittleEndianData })
    static let floatValuesBigEndianData = Data([ 0x00 ]) + (0..<floatValuesCount).reduce(Data(), { data, _ in data + floatValueBigEndianData })

    func testFloat() {
        test(floatValuesData: Self.floatValuesLittleEndianData, bigEndian: false)
        test(floatValuesData: Self.floatValuesBigEndianData, bigEndian: true)
    }

    func test(floatValuesData: Data, bigEndian: Bool) {
        for _ in 0..<10000 {
        floatValuesData.withUnsafeBytes { unsafeDataBufferPointer in
            XCTAssertEqual(Float(unsafeDataBufferPointer.baseAddress!, from: 1, bigEndian: bigEndian),
                           Self.floatValue)
            XCTAssertEqual(Float(unsafeDataBufferPointer.baseAddress!, from: 1 + Self.floatValuesCount/2, bigEndian: bigEndian),
                           Self.floatValue)
            XCTAssertEqual(Float(unsafeDataBufferPointer.baseAddress! + 1, bigEndian: bigEndian),
                           Self.floatValue)

            let arrayA = Float.array(unsafeDataBufferPointer.baseAddress!, from: 1 + Float.byteWidth*10, count: Self.floatValuesCount-10, bigEndian: bigEndian)
            XCTAssert(arrayA.count == Self.floatValuesCount-10)
            XCTAssertEqual(arrayA[arrayA.count-1], Self.floatValue)

            let arrayB = Float.array(unsafeDataBufferPointer.baseAddress! + 1, count: Self.floatValuesCount, bigEndian: bigEndian)
            XCTAssert(arrayB.count == Self.floatValuesCount)
            XCTAssertEqual(arrayB[arrayB.count-1], Self.floatValue)
        }
        }
    }
}
