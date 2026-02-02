import Foundation
import simd
import spz

/// A reader for Gaussian Splat files in the SPZ format
public class SPZSceneReader: SplatSceneReader {
    public enum Error: Swift.Error {
        case cannotOpenSource(URL)
        case readError(Swift.Error)
    }

    public enum Constants {
        /// Number of points to unpack and yield per batch.
        public static let batchSize = 10_000
    }

    private let source: Source

    private enum Source {
        case url(URL)
        case data(Data)
    }

    public init(_ url: URL) throws {
        guard url.isFileURL else {
            throw Error.cannotOpenSource(url)
        }
        self.source = .url(url)
    }

    public init(_ data: Data) throws {
        self.source = .data(data)
    }

    public func read() throws -> AsyncThrowingStream<[SplatScenePoint], Swift.Error> {
        // Load the packed SPZ data (decompressed but not unpacked)
        let packed: PackedGaussians
        do {
            switch source {
            case .url(let url):
                packed = try loadSpzPacked(from: url)
            case .data(let data):
                packed = try loadSpzPacked(data)
            }
        } catch {
            throw Error.readError(error)
        }

        let numPoints = Int(packed.numPoints)
        let shDegree = packed.shDegree

        // Create coordinate converter: SPZ uses RUB internally, we want RDF to match PLY convention
        let converter = coordinateConverter(from: .rub, to: .rdf)

        // Stream unpacked points in batches
        return AsyncThrowingStream { continuation in
            var offset = 0
            while offset < numPoints {
                let end = min(offset + Constants.batchSize, numPoints)
                var batch = [SplatScenePoint]()
                batch.reserveCapacity(end - offset)

                for i in offset..<end {
                    let unpacked = packed.unpack(Int32(i), converter: converter)
                    let point = self.convertUnpackedToSplatScenePoint(unpacked, shDegree: shDegree)
                    batch.append(point)
                }

                continuation.yield(batch)
                offset = end
            }
            continuation.finish()
        }
    }

    /// Convert an UnpackedGaussian to a SplatScenePoint.
    private func convertUnpackedToSplatScenePoint(_ unpacked: UnpackedGaussian, shDegree: Int32) -> SplatScenePoint {
        // Position
        let position = unpacked.position

        // Color: DC component (sh0) + higher order SH coefficients
        var shCoeffs: [SIMD3<Float>] = []
        shCoeffs.append(unpacked.color)  // DC component

        // Higher order SH coefficients
        let shDim = shDimForDegree(shDegree)
        for j in 0..<shDim {
            let coeff = SIMD3<Float>(
                unpacked.shR[j],
                unpacked.shG[j],
                unpacked.shB[j]
            )
            shCoeffs.append(coeff)
        }

        let color = SplatScenePoint.Color.sphericalHarmonicFloat(shCoeffs)

        // Opacity (stored as logit in SPZ)
        let opacity = SplatScenePoint.Opacity.logitFloat(unpacked.alpha)

        // Scale (stored as log/exponent in SPZ)
        let scale = SplatScenePoint.Scale.exponent(unpacked.scale)

        // Rotation: UnpackedGaussian stores as [x, y, z, w]
        let rotation = simd_quatf(
            ix: unpacked.rotation.x,
            iy: unpacked.rotation.y,
            iz: unpacked.rotation.z,
            r: unpacked.rotation.w
        )

        return SplatScenePoint(
            position: position,
            color: color,
            opacity: opacity,
            scale: scale,
            rotation: rotation
        )
    }

    /// Get the number of higher-order SH coefficients per point for a given degree.
    private func shDimForDegree(_ degree: Int32) -> Int {
        switch degree {
        case 0: return 0
        case 1: return 3
        case 2: return 8
        case 3: return 15
        default: return 0
        }
    }
}
