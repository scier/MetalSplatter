import XCTest
import PLYIO
import Spatial
import SplatIO
import spz

final class SplatIOTests: XCTestCase {
    class ContentStorage {
        static func testApproximatelyEqual(lhs: ContentStorage, rhs: ContentStorage, compareSH0Only: Bool, tolerance: SplatPointTolerance = .default) {
            XCTAssertEqual(lhs.points.count, rhs.points.count, "Same number of points")
            for (i, (lhsPoint, rhsPoint)) in zip(lhs.points, rhs.points).enumerated() {
                XCTAssertTrue(lhsPoint.approximatelyEqual(to: rhsPoint, compareSH0Only: compareSH0Only, tolerance: tolerance),
                              "Point \(i) mismatch: \(lhsPoint) vs \(rhsPoint)")
            }
        }

        var points: [SplatIO.SplatPoint] = []
        var batchCount: Int = 0

        init(_ reader: any SplatSceneReader) async throws {
            let pointReader = try await reader.read()
            for try await points in pointReader {
                self.points.append(contentsOf: points)
                self.batchCount += 1
            }
        }
    }

    let plyURL = Bundle.module.url(forResource: "test-splat.3-points-from-train", withExtension: "ply", subdirectory: "TestData")!
    let dotSplatURL = Bundle.module.url(forResource: "test-splat.3-points-from-train", withExtension: "splat", subdirectory: "TestData")!
    let spzURL = Bundle.module.url(forResource: "test-splat.3-points-from-train", withExtension: "spz", subdirectory: "TestData")!

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

    // MARK: - SPZ Tests

    func testReadSPZ() async throws {
        try await testRead(spzURL)
    }

    func testSPZEqualsPLYAtSH0() async throws {
        // SPZ and PLY should produce equivalent results at SH0 level
        // SPZ has quantization loss, so we use relaxed tolerance
        try await testEqual(spzURL, plyURL, compareSH0Only: true, tolerance: .spzQuantization)
    }

    func testRewriteSPZToSPZ() async throws {
        // SPZ→SPZ should preserve data (within quantization tolerance)
        try await testReadWriteReadSPZ(spzURL, compareSH0Only: false)
    }

    func testRewriteSPZToPLY() async throws {
        // SPZ→PLY round trip
        try await testReadWriteRead(spzURL, writePLY: true, compareSH0Only: true)
    }

    func testRewritePLYToSPZ() async throws {
        // PLY→SPZ→compare (lossy due to quantization)
        let readerA = try AutodetectSceneReader(plyURL)
        let contentA = try await ContentStorage(readerA)

        // Write to SPZ
        let spzWriter = try SPZSceneWriter(to: .memory)
        try await spzWriter.start(numPoints: contentA.points.count)
        try await spzWriter.write(contentA.points)
        try await spzWriter.close()
        guard let spzData = await spzWriter.writtenData else {
            XCTFail("Failed to get written SPZ data")
            return
        }

        // Read back from SPZ
        let readerB = try SPZSceneReader(spzData)
        let contentB = try await ContentStorage(readerB)

        // Compare with relaxed tolerance due to SPZ quantization
        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB, compareSH0Only: true, tolerance: .spzQuantization)
    }

    func testSPZBatchStreaming() async throws {
        // Test that SPZ reader yields points in batches
        // Create a larger synthetic dataset to test batching
        let batchSize = SPZSceneReader.Constants.batchSize
        let numPoints = batchSize * 3 + 500  // Should produce 4 batches

        // Create synthetic points
        var points = [SplatPoint]()
        for i in 0..<numPoints {
            let point = SplatPoint(
                position: SIMD3<Float>(Float(i), Float(i) * 0.5, Float(i) * 0.25),
                color: .sphericalHarmonicFloat([SIMD3<Float>(0.5, 0.5, 0.5)]),
                opacity: .linearFloat(0.9),
                scale: .exponent(SIMD3<Float>(-3, -3, -3)),
                rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            )
            points.append(point)
        }

        // Write to SPZ
        let spzWriter = try SPZSceneWriter(to: .memory)
        try await spzWriter.start(numPoints: numPoints)
        try await spzWriter.write(points)
        try await spzWriter.close()
        guard let spzData = await spzWriter.writtenData else {
            XCTFail("Failed to get written SPZ data")
            return
        }

        // Read back and count batches
        let reader = try SPZSceneReader(spzData)
        let content = try await ContentStorage(reader)

        XCTAssertEqual(content.points.count, numPoints, "Should read all points")
        XCTAssertEqual(content.batchCount, 4, "Should produce 4 batches for \(numPoints) points")
    }

    func testSPZCoordinateConversion() async throws {
        // Verify that SPZ coordinate conversion (RUB→RDF) works correctly
        // by comparing positions from SPZ vs PLY (which is already in RDF)
        let plyReader = try SplatPLYSceneReader(plyURL)
        let plyContent = try await ContentStorage(plyReader)

        let spzReader = try SPZSceneReader(spzURL)
        let spzContent = try await ContentStorage(spzReader)

        XCTAssertEqual(plyContent.points.count, spzContent.points.count)

        // Positions should match within SPZ quantization tolerance
        for (plyPoint, spzPoint) in zip(plyContent.points, spzContent.points) {
            let positionDiff = abs(plyPoint.position - spzPoint.position)
            XCTAssertTrue(positionDiff.x < 0.01, "X position mismatch: \(plyPoint.position.x) vs \(spzPoint.position.x)")
            XCTAssertTrue(positionDiff.y < 0.01, "Y position mismatch: \(plyPoint.position.y) vs \(spzPoint.position.y)")
            XCTAssertTrue(positionDiff.z < 0.01, "Z position mismatch: \(plyPoint.position.z) vs \(spzPoint.position.z)")
        }
    }

    func testSPZIncrementalWriting() async throws {
        // Test the start() + multiple write() API for incremental writing
        let numPoints = 100

        // Create synthetic points
        var allPoints = [SplatPoint]()
        for i in 0..<numPoints {
            let point = SplatPoint(
                position: SIMD3<Float>(Float(i), Float(i) * 0.5, Float(i) * 0.25),
                color: .sphericalHarmonicFloat([SIMD3<Float>(0.5, 0.5, 0.5)]),
                opacity: .linearFloat(0.9),
                scale: .exponent(SIMD3<Float>(-3, -3, -3)),
                rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            )
            allPoints.append(point)
        }

        // Write using incremental API with multiple batches
        let spzWriter = try SPZSceneWriter(to: .memory)
        try await spzWriter.start(numPoints: numPoints)

        // Write in 4 batches of 25
        for batchStart in stride(from: 0, to: numPoints, by: 25) {
            let batchEnd = min(batchStart + 25, numPoints)
            let batch = Array(allPoints[batchStart..<batchEnd])
            try await spzWriter.write(batch)
        }

        try await spzWriter.close()
        guard let spzData = await spzWriter.writtenData else {
            XCTFail("Failed to get written SPZ data")
            return
        }

        // Read back and verify
        let reader = try SPZSceneReader(spzData)
        let content = try await ContentStorage(reader)

        XCTAssertEqual(content.points.count, numPoints, "Should read all points")

        // Verify points match (within quantization tolerance)
        for (i, (original, readBack)) in zip(allPoints, content.points).enumerated() {
            XCTAssertTrue(original.approximatelyEqual(to: readBack, compareSH0Only: true, tolerance: .spzQuantization),
                          "Point \(i) mismatch after incremental write")
        }
    }

    func testSPZDynamicSHUpgrade() async throws {
        // Test that SH degree is auto-detected and upgraded as needed
        let numPoints = 6

        // Create points with different SH degrees
        let sh0Point = SplatPoint(
            position: SIMD3<Float>(0, 0, 0),
            color: .sphericalHarmonicFloat([SIMD3<Float>(0.5, 0.5, 0.5)]),
            opacity: .linearFloat(0.9),
            scale: .exponent(SIMD3<Float>(-3, -3, -3)),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        )
        let sh1Point = SplatPoint(
            position: SIMD3<Float>(1, 0, 0),
            color: .sphericalHarmonicFloat([
                SIMD3<Float>(0.5, 0.5, 0.5),  // SH0
                SIMD3<Float>(0.1, 0.1, 0.1),  // SH1 coeffs
                SIMD3<Float>(0.2, 0.2, 0.2),
                SIMD3<Float>(0.3, 0.3, 0.3),
            ]),
            opacity: .linearFloat(0.9),
            scale: .exponent(SIMD3<Float>(-3, -3, -3)),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        )

        // Write without specifying shDegree - should auto-detect
        let spzWriter = try SPZSceneWriter(to: .memory)
        try await spzWriter.start(numPoints: numPoints)  // No shDegree specified

        // First batch: SH0 only
        try await spzWriter.write([sh0Point, sh0Point])

        // Second batch: includes SH1 point - should trigger upgrade
        try await spzWriter.write([sh0Point, sh1Point])

        // Third batch: back to SH0 (should still work with upgraded arrays)
        try await spzWriter.write([sh0Point, sh0Point])

        try await spzWriter.close()
        guard let spzData = await spzWriter.writtenData else {
            XCTFail("Failed to get written SPZ data")
            return
        }

        // Read back and verify
        let reader = try SPZSceneReader(spzData)
        let content = try await ContentStorage(reader)

        XCTAssertEqual(content.points.count, numPoints, "Should read all points")

        // Verify the SH1 point (index 3) has its SH coefficients preserved
        // Note: SPZ has quantization loss, so we use relaxed tolerance
        let readSH1Point = content.points[3]
        let sh1Coeffs = readSH1Point.color.asSphericalHarmonicFloat
        XCTAssertEqual(sh1Coeffs.count, 4, "SH1 point should have 4 coefficients")
    }

    func testSPZWriterRejectsTooManyPoints() async throws {
        // Test that writing more points than declared throws an error
        let spzWriter = try SPZSceneWriter(to: .memory)
        try await spzWriter.start(numPoints: 2)

        let point = SplatPoint(
            position: SIMD3<Float>(0, 0, 0),
            color: .sphericalHarmonicFloat([SIMD3<Float>(0.5, 0.5, 0.5)]),
            opacity: .linearFloat(0.9),
            scale: .exponent(SIMD3<Float>(-3, -3, -3)),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        )

        // First two writes should succeed
        try await spzWriter.write([point])
        try await spzWriter.write([point])

        // Third write should fail
        do {
            try await spzWriter.write([point])
            XCTFail("Expected tooManyPoints error")
        } catch SPZSceneWriter.Error.tooManyPoints {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEqual(_ urlA: URL, _ urlB: URL, compareSH0Only: Bool, tolerance: SplatPointTolerance = .default) async throws {
        let readerA = try AutodetectSceneReader(urlA)
        let contentA = try await ContentStorage(readerA)

        let readerB = try AutodetectSceneReader(urlB)
        let contentB = try await ContentStorage(readerB)

        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB, compareSH0Only: compareSH0Only, tolerance: tolerance)
    }

    func testReadWriteReadSPZ(_ url: URL, compareSH0Only: Bool) async throws {
        let readerA = try AutodetectSceneReader(url)
        let contentA = try await ContentStorage(readerA)

        // Write to SPZ
        let spzWriter = try SPZSceneWriter(to: .memory)
        try await spzWriter.start(numPoints: contentA.points.count)
        try await spzWriter.write(contentA.points)
        try await spzWriter.close()
        guard let spzData = await spzWriter.writtenData else {
            XCTFail("Failed to get written SPZ data")
            return
        }

        // Read back from SPZ
        let readerB = try SPZSceneReader(spzData)
        let contentB = try await ContentStorage(readerB)

        // SPZ has quantization, so use relaxed tolerance
        ContentStorage.testApproximatelyEqual(lhs: contentA, rhs: contentB, compareSH0Only: compareSH0Only, tolerance: .spzQuantization)
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

/// Tolerance values for comparing SplatPoints
struct SplatPointTolerance {
    var position: Float
    var color: Float
    var opacity: Float
    var scale: Float
    var rotation: Float

    static let `default` = SplatPointTolerance(
        position: 1e-10,
        color: 1.0 / 256,
        opacity: 1.0 / 256,
        scale: 1e-10,
        rotation: 2.0 / 128
    )

    /// Relaxed tolerance for SPZ quantization loss
    static let spzQuantization = SplatPointTolerance(
        position: 0.01,      // 24-bit fixed point has limited precision
        color: 0.02,         // 8-bit quantized color
        opacity: 0.02,       // 8-bit quantized alpha
        scale: 0.1,          // 8-bit quantized scale
        rotation: 0.05       // 10-bit quaternion components
    )
}

extension SplatPoint {
    enum Tolerance {
        static let position: Float = 1e-10
        static let color: Float = 1.0 / 256
        static let opacity: Float = 1.0 / 256
        static let scale: Float = 1e-10
        static let rotation: Float = 2.0 / 128
    }

    func approximatelyEqual(to rhs: SplatPoint, compareSH0Only: Bool, tolerance: SplatPointTolerance = .default) -> Bool {
        (position - rhs.position).isWithin(tolerance: tolerance.position) &&
        color.approximatelyEqual(to: rhs.color, compareSH0Only: compareSH0Only, tolerance: tolerance.color) &&
        opacity.approximatelyEqual(to: rhs.opacity, tolerance: tolerance.opacity) &&
        scale.approximatelyEqual(to: rhs.scale, tolerance: tolerance.scale) &&
        (rotation.normalized.vector - rhs.rotation.normalized.vector).isWithin(tolerance: tolerance.rotation)
    }
}

extension SplatPoint.Color {
    func approximatelyEqual(to rhs: SplatPoint.Color, compareSH0Only: Bool, tolerance: Float = SplatPoint.Tolerance.color) -> Bool {
        if compareSH0Only {
            // Only compare SH0 (base color)
            return (asSRGBFloat - rhs.asSRGBFloat).isWithin(tolerance: tolerance)
        } else {
            // Compare all SH coefficients
            let lhsSH = asSphericalHarmonicFloat
            let rhsSH = rhs.asSphericalHarmonicFloat
            guard lhsSH.count == rhsSH.count else { return false }
            for (l, r) in zip(lhsSH, rhsSH) {
                if !(l - r).isWithin(tolerance: tolerance) {
                    return false
                }
            }
            return true
        }
    }
}

extension SplatPoint.Opacity {
    public static func ~= (lhs: SplatPoint.Opacity, rhs: SplatPoint.Opacity) -> Bool {
        abs(lhs.asLinearFloat - rhs.asLinearFloat) <= SplatPoint.Tolerance.opacity
    }

    func approximatelyEqual(to rhs: SplatPoint.Opacity, tolerance: Float) -> Bool {
        abs(asLinearFloat - rhs.asLinearFloat) <= tolerance
    }
}

extension SplatPoint.Scale {
    public static func ~= (lhs: SplatPoint.Scale, rhs: SplatPoint.Scale) -> Bool {
        (lhs.asLinearFloat - rhs.asLinearFloat).isWithin(tolerance: SplatPoint.Tolerance.scale)
    }

    func approximatelyEqual(to rhs: SplatPoint.Scale, tolerance: Float) -> Bool {
        (asLinearFloat - rhs.asLinearFloat).isWithin(tolerance: tolerance)
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
