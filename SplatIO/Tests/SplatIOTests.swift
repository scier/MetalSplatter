import XCTest
import Spatial
import SplatIO

final class SplatIOTests: XCTestCase {
    class ContentCounter: SplatSceneReaderDelegate {
        var expectedPointCount: UInt32?
        var pointCount: UInt32 = 0
        var didFinish = false
        var didFail = false

        func reset() {
            expectedPointCount = nil
            pointCount = 0
            didFinish = false
            didFail = false
        }

        func didStartReading(withPointCount pointCount: UInt32) {
            XCTAssertNil(expectedPointCount)
            XCTAssertFalse(didFinish)
            XCTAssertFalse(didFail)
            expectedPointCount = pointCount
        }

        func didRead(points: [SplatIO.SplatScenePoint]) {
            pointCount += UInt32(points.count)
        }

        func didFinishReading() {
            XCTAssertNotNil(expectedPointCount)
            XCTAssertFalse(didFinish)
            XCTAssertFalse(didFail)
            didFinish = true
        }

        func didFailReading(withError error: Error?) {
            XCTAssertFalse(didFinish)
            XCTAssertFalse(didFail)
            didFail = true
        }
    }

    let trainURL = Bundle.module.url(forResource: "test-splat.3-points-from-train", withExtension: "ply", subdirectory: "TestData")!

    func testReadTrain() throws {
        try testRead(trainURL)
    }

    func testRead(_ url: URL) throws {
        let reader = SplatPLYSceneReader(url)

        let content = ContentCounter()
        reader.read(to: content)
        XCTAssertNotNil(content.expectedPointCount)
        XCTAssertTrue(content.didFinish)
        XCTAssertFalse(content.didFail)
        if let expectedPointCount = content.expectedPointCount {
            XCTAssertEqual(expectedPointCount, content.pointCount)
        }
    }
}
