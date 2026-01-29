import XCTest
import PLYIO
import Spatial
import SplatIO

final class SplatIOTests: XCTestCase {
    class ContentStorage {
        static func testApproximatelyEqual(lhs: ContentStorage, rhs: ContentStorage) {
            XCTAssertEqual(lhs.points.count, rhs.points.count, "Same number of points")
            for (lhsPoint, rhsPoint) in zip(lhs.points, rhs.points) {
                XCTAssertTrue(lhsPoint ~= rhsPoint)
            }
        }

        var points: [SplatIO.SplatScenePoint] = []

        init(_ reader: any SplatSceneReader) async throws {
            let pointReader = try await reader.read()
            for try await points in pointReader {
                self.points.append(contentsOf: points)
            }
        }
    }

    let plyURL = Bundle.module.url(forResource: "test-splat.3-points-from-train", withExtension: "ply", subdirectory: "TestData")!
    let dotSplatURL = Bundle.module.url(forResource: "test-splat.3-points-from-train", withExtension: "splat", subdirectory: "TestData")!

    func testReadPLY() async throws {
        try await testRead(plyURL)
    }

    func textReadDotSplat() async throws {
        try await testRead(dotSplatURL)
    }

    func testFormatsEqual() async throws {
        try await testEqual(plyURL, dotSplatURL)
    }

    func testRewritePLY() async throws {
        try await testReadWriteRead(plyURL, writePLY: true)
        try await testReadWriteRead(plyURL, writePLY: false)
    }

    func testRewriteDotSplat() async throws {
        try await testReadWriteRead(dotSplatURL, writePLY: true)
        try await testReadWriteRead(dotSplatURL, writePLY: false)
    }

    func testEqual(_ urlA: URL, _ urlB: URL) async throws {
        let readerA = try AutodetectSceneReader(urlA)
        let contentA = try await ContentStorage(readerA)

        let readerB = try AutodetectSceneReader(urlB)
        let contentB = try await ContentStorage(readerB)

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB)
    }

    func testReadWriteRead(_ url: URL, writePLY: Bool) async throws {
        let readerA = try AutodetectSceneReader(url)
        let contentA = try await ContentStorage(readerA)

        let writtenData: Data
        switch writePLY {
        case true:
            let plyWriter = try SplatPLYSceneWriter(to: .memory)
            try await plyWriter.start(pointCount: contentA.points.count)
            try await plyWriter.write(contentA.points)
            try await plyWriter.close()
            guard let data = await plyWriter.writtenData else {
                XCTFail("Failed to get written data from memory writer")
                return
            }
            writtenData = data
        case false:
            let splatWriter = try DotSplatSceneWriter(to: .memory)
            try await splatWriter.write(contentA.points)
            try await splatWriter.close()
            guard let data = await splatWriter.writtenData else {
                XCTFail("Failed to get written data from memory writer")
                return
            }
            writtenData = data
        }

        let readerB: any SplatSceneReader = writePLY ? try SplatPLYSceneReader(writtenData) : try DotSplatSceneReader(writtenData)
        let contentB = try await ContentStorage(readerB)

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB)
    }

    func testRead(_ url: URL) async throws {
        let reader = try AutodetectSceneReader(url)

        _ = try await reader.read()
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
