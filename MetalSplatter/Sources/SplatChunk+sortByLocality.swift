import Foundation

fileprivate enum SplatChunk_sortByLocality_Constants {
    // When performing the splat locality sort, we need to use quantized positions, meaning we need to compute bounds.
    // It's fine if the bounds doesn't include all the splats, some will be clamped to the outside of the box so will
    // just get a less efficient locality sort. Let's set the bounds to mean +/- N * std.dev., where N is:
    static let boundsStdDeviationsForLocalitySort: Float = 2.5
}

extension SplatChunk {
    /// Sorts splats by their position's Morton code to improve memory locality: adjacent splats in memory will tend to be
    /// nearby in space as well. This helps improve the tiling/cache performance of the vertex shader.
    func sortByLocality() {
        let splatBuffer = splats
        guard splatBuffer.count > 3 else { return }
        
        let (minBounds, maxBounds) = splatBuffer.bounds(withinSigmaMultiple: SplatChunk_sortByLocality_Constants.boundsStdDeviationsForLocalitySort)
        let boundsSize = maxBounds - minBounds
        guard boundsSize.x > 0 && boundsSize.y > 0 && boundsSize.z > 0 else {
            return
        }
        let invBoundsSize = 1/boundsSize
        
        // Quantize a value into a 10-bit unsigned integer
        func quantize(_ value: Float, _ minBounds: Float, _ invBoundsSize: Float) -> UInt32 {
            let normalizedValue = (value - minBounds) * invBoundsSize
            let clamped = max(min(normalizedValue, 1), 0)
            return UInt32(clamped * 1023.0)
        }
        // Quantize a splat position into 10-bit unsigned integers per axis
        func quantize(_ p: SIMD3<Float>) -> SIMD3<UInt32> {
            SIMD3<UInt32>(quantize(p.x, minBounds.x, invBoundsSize.x),
                          quantize(p.y, minBounds.y, invBoundsSize.y),
                          quantize(p.z, minBounds.z, invBoundsSize.z))
        }
        
        // Encode quantized coordinate into a single Morton code
        func morton3D(_ p: SIMD3<UInt32>) -> UInt32 {
            var result: UInt32 = 0
            for i in 0..<10 {
                result |= ((p.x >> i) & 1) << (3 * i + 0)
                result |= ((p.y >> i) & 1) << (3 * i + 1)
                result |= ((p.z >> i) & 1) << (3 * i + 2)
            }
            return result
        }
        
        // Create array of (index, morton code) pairs
        let indicesWithMortonCodes: [(Int, UInt32)] = (0..<splatBuffer.count).map { i in
            let position = splatBuffer.values[i].position
            let simdPosition = SIMD3<Float>(x: position.x, y: position.y, z: position.z)
            let morton = morton3D(quantize(simdPosition))
            return (i, morton)
        }
        
        // Sort indices by their Morton code
        let sorted = indicesWithMortonCodes.sorted { $0.1 < $1.1 }.map(\.0)
        // Reorder splat buffer according to sorted indices
        splatBuffer.values.reorderInPlace(fromSourceIndices: sorted)
    }
}

fileprivate extension MetalBuffer where T == EncodedSplat {
    // Define a bounding box which doesn't quite include all the splats, just most of them
    func bounds(withinSigmaMultiple sigmaMultiple: Float) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var sum = SIMD3<Float>.zero
        var sumOfSquares = SIMD3<Float>.zero
        let count = Float(count)
        for i in 0..<self.count {
            let p = values[i].position
            let position = SIMD3<Float>(p.x, p.y, p.z)
            sum += position
            sumOfSquares += position * position
        }
        let mean = sum / count
        let variance = sumOfSquares / count - mean * mean
        let sigma = SIMD3<Float>(x: sqrt(variance.x), y: sqrt(variance.y), z: sqrt(variance.z))
        
        let minBounds = mean - sigmaMultiple * sigma
        let maxBounds = mean + sigmaMultiple * sigma
        
        return (min: minBounds, max: maxBounds)
    }
}
