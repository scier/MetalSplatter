import XCTest
import PLYIO
import Spatial
import SplatIO

final class SplatIOTests: XCTestCase {
    class ContentStorage {
        static func testApproximatelyEqual(lhs: ContentStorage, rhs: ContentStorage, compareSH0Only: Bool) {
            XCTAssertEqual(lhs.points.count, rhs.points.count, "Same number of points")
            for (lhsPoint, rhsPoint) in zip(lhs.points, rhs.points) {
                XCTAssertTrue(lhsPoint.approximatelyEqual(to: rhsPoint, compareSH0Only: compareSH0Only))
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

    func testFormatsEqualSH0() async throws {
        // PLY and .splat formats can only be compared at SH0 level since .splat doesn't support higher SH
        try await testEqual(plyURL, dotSplatURL, compareSH0Only: true)
    }

    func testRewritePLYToPLY() async throws {
        // PLY→PLY should preserve all SH coefficients
        try await testReadWriteRead(plyURL, writePLY: true, compareSH0Only: false)
    }

    func testRewritePLYToSplat() async throws {
        // PLY→.splat loses higher SH coefficients, only compare SH0
        try await testReadWriteRead(plyURL, writePLY: false, compareSH0Only: true)
    }

    func testRewriteDotSplatToPLY() async throws {
        // .splat→PLY: .splat only has SH0, PLY writer adds zeros for higher SH
        // Only compare SH0 since that's all the original had
        try await testReadWriteRead(dotSplatURL, writePLY: true, compareSH0Only: true)
    }

    func testRewriteDotSplatToSplat() async throws {
        // .splat→.splat should preserve SH0 exactly
        try await testReadWriteRead(dotSplatURL, writePLY: false, compareSH0Only: false)
    }

    func testEqual(_ urlA: URL, _ urlB: URL, compareSH0Only: Bool) async throws {
        let readerA = try AutodetectSceneReader(urlA)
        let contentA = try await ContentStorage(readerA)

        let readerB = try AutodetectSceneReader(urlB)
        let contentB = try await ContentStorage(readerB)

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB, compareSH0Only: compareSH0Only)
    }

    func testReadWriteRead(_ url: URL, writePLY: Bool, compareSH0Only: Bool) async throws {
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

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB, compareSH0Only: compareSH0Only)
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

    func approximatelyEqual(to rhs: SplatScenePoint, compareSH0Only: Bool) -> Bool {
        (position - rhs.position).isWithin(tolerance: Tolerance.position) &&
        color.approximatelyEqual(to: rhs.color, compareSH0Only: compareSH0Only) &&
        opacity ~= rhs.opacity &&
        scale ~= rhs.scale &&
        (rotation.normalized.vector - rhs.rotation.normalized.vector).isWithin(tolerance: Tolerance.rotation)
    }
}

extension SplatScenePoint.Color {
    func approximatelyEqual(to rhs: SplatScenePoint.Color, compareSH0Only: Bool) -> Bool {
        if compareSH0Only {
            // Only compare SH0 (base color)
            return (asSRGBFloat - rhs.asSRGBFloat).isWithin(tolerance: SplatScenePoint.Tolerance.color)
        } else {
            // Compare all SH coefficients
            let lhsSH = asSphericalHarmonicFloat
            let rhsSH = rhs.asSphericalHarmonicFloat
            guard lhsSH.count == rhsSH.count else { return false }
            for (l, r) in zip(lhsSH, rhsSH) {
                if !(l - r).isWithin(tolerance: SplatScenePoint.Tolerance.color) {
                    return false
                }
            }
            return true
        }
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
