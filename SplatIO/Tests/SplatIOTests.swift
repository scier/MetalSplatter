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

        func didStartReading(withPointCount pointCount: UInt32?) {
            XCTAssertNil(expectedPointCount)
            XCTAssertFalse(didFinish)
            XCTAssertFalse(didFail)
            expectedPointCount = pointCount
        }

        func didRead(points: [SplatIO.SplatScenePoint]) {
            pointCount += UInt32(points.count)
        }

        func didFinishReading() {
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

    class ContentStorage: SplatSceneReaderDelegate {
        var points: [SplatIO.SplatScenePoint] = []
        var didFinish = false
        var didFail = false

        func reset() {
            points = []
            didFinish = false
            didFail = false
        }

        func didStartReading(withPointCount pointCount: UInt32?) {
            XCTAssertTrue(points.isEmpty)
            XCTAssertFalse(didFinish)
            XCTAssertFalse(didFail)
        }

        func didRead(points: [SplatScenePoint]) {
            self.points.append(contentsOf: points)
        }

        func didFinishReading() {
            XCTAssertFalse(didFinish)
            XCTAssertFalse(didFail)
            didFinish = true
        }

        func didFailReading(withError error: Error?) {
            XCTAssertFalse(didFinish)
            XCTAssertFalse(didFail)
            didFail = true
        }

        static func testApproximatelyEqual(lhs: ContentStorage, rhs: ContentStorage) {
            XCTAssertEqual(lhs.points.count, rhs.points.count, "Same number of points")
            for (lhsPoint, rhsPoint) in zip(lhs.points, rhs.points) {
                XCTAssertTrue(lhsPoint ~= rhsPoint)
            }
        }
    }

    let plyURL = Bundle.module.url(forResource: "test-splat.3-points-from-train", withExtension: "ply", subdirectory: "TestData")!
    let dotSplatURL = Bundle.module.url(forResource: "test-splat.3-points-from-train", withExtension: "splat", subdirectory: "TestData")!

    func testReadPLY() throws {
        try testRead(plyURL)
    }

    func textReadDotSplat() throws {
        try testRead(dotSplatURL)
    }

    func testFormatsEqual() throws {
        try testEqual(plyURL, dotSplatURL)
    }

    func testRewritePLY() throws {
        try testReadWriteRead(plyURL, writePLY: true)
        try testReadWriteRead(plyURL, writePLY: false)
    }

    func testRewriteDotSplat() throws {
        try testReadWriteRead(dotSplatURL, writePLY: true)
        try testReadWriteRead(dotSplatURL, writePLY: false)
    }

    func testEqual(_ urlA: URL, _ urlB: URL) throws {
        let readerA = try AutodetectSceneReader(urlA)
        let contentA = ContentStorage()
        readerA.read(to: contentA)

        let readerB = try AutodetectSceneReader(urlB)
        let contentB = ContentStorage()
        readerB.read(to: contentB)

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB)
    }

    func testReadWriteRead(_ url: URL, writePLY: Bool) throws {
        let readerA = try AutodetectSceneReader(url)
        let contentA = ContentStorage()
        readerA.read(to: contentA)

        let memoryOutput = DataOutputStream()
        memoryOutput.open()
        let writer: any SplatSceneWriter
        switch writePLY {
        case true:
            let plyWriter = SplatPLYSceneWriter(memoryOutput)
            try plyWriter.start(pointCount: contentA.points.count)
            writer = plyWriter
        case false:
            writer = DotSplatSceneWriter(memoryOutput)
        }
        try writer.write(contentA.points)

        let memoryInput = InputStream(data: memoryOutput.data)
        memoryInput.open()

        let readerB: any SplatSceneReader = writePLY ? SplatPLYSceneReader(memoryInput) : DotSplatSceneReader(memoryInput)
        let contentB = ContentStorage()
        readerB.read(to: contentB)

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB)
    }

    func testRead(_ url: URL) throws {
        let reader = try AutodetectSceneReader(url)

        let content = ContentCounter()
        reader.read(to: content)
        XCTAssertTrue(content.didFinish)
        XCTAssertFalse(content.didFail)
        if let expectedPointCount = content.expectedPointCount {
            XCTAssertEqual(expectedPointCount, content.pointCount)
        }
    }
}

extension SplatScenePoint {
    enum Tolerance {
        static let position: Float = 1e-10
        static let color: Float = 1.0 / 256
        static let opacity: Float = 1.0 / 256
        static let scale: Float = 1e-10
        static let rotation: Float = 2.0 / 128
    }

    public static func ~= (lhs: SplatScenePoint, rhs: SplatScenePoint) -> Bool {
        (lhs.position - rhs.position).isWithin(tolerance: Tolerance.position) &&
        lhs.color ~= rhs.color &&
        lhs.opacity ~= rhs.opacity &&
        lhs.scale ~= rhs.scale &&
        (lhs.rotation.normalized.vector - rhs.rotation.normalized.vector).isWithin(tolerance: Tolerance.rotation)
    }
}

extension SplatScenePoint.Color {
    public static func ~= (lhs: SplatScenePoint.Color, rhs: SplatScenePoint.Color) -> Bool {
        (lhs.asLinearFloat - rhs.asLinearFloat).isWithin(tolerance: SplatScenePoint.Tolerance.color)
    }
}

extension SplatScenePoint.Opacity {
    public static func ~= (lhs: SplatScenePoint.Opacity, rhs: SplatScenePoint.Opacity) -> Bool {
        abs(lhs.asLinearFloat - rhs.asLinearFloat) <= SplatScenePoint.Tolerance.opacity
    }
}

extension SplatScenePoint.Scale {
    public static func ~= (lhs: SplatScenePoint.Scale, rhs: SplatScenePoint.Scale) -> Bool {
        (lhs.asLinearFloat - rhs.asLinearFloat).isWithin(tolerance: SplatScenePoint.Tolerance.scale)
    }
}

extension SIMD3 where Scalar: Comparable & SignedNumeric {
    public func isWithin(tolerance: Scalar) -> Bool {
        abs(x) <= tolerance && abs(y) <= tolerance && abs(z) <= tolerance
    }
}

extension SIMD4 where Scalar: Comparable & SignedNumeric {
    public func isWithin(tolerance: Scalar) -> Bool {
        abs(x) <= tolerance && abs(y) <= tolerance && abs(z) <= tolerance && abs(w) <= tolerance
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

private extension SIMD3 where Scalar == Float {
    var magnitude: Scalar {
        sqrt(x*x + y*y + z*z)
    }
}

private extension SIMD4 where Scalar == Float {
    var magnitude: Scalar {
        sqrt(x*x + y*y + z*z + w*w)
    }
}
