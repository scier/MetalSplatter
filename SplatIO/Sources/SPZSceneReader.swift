import Foundation
import SPZIO
import simd

/// A reader for Gaussian Splat files in the compressed .spz format
public class SPZSceneReader: SplatSceneReader {
    public enum Error: Swift.Error, LocalizedError {
        case cannotOpenSource(URL)
        case loadFailed(String)
        case invalidData

        public var errorDescription: String? {
            switch self {
            case .cannotOpenSource(let url):
                "Cannot open SPZ file at \(url.path)"
            case .loadFailed(let message):
                "Failed to load SPZ file: \(message)"
            case .invalidData:
                "Invalid SPZ data"
            }
        }
    }

    private let url: URL

    public init(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.cannotOpenSource(url)
        }
        self.url = url
    }

    public func read(to delegate: any SplatSceneReaderDelegate) {
        // Try to get point count first for progress reporting
        var nsError: NSError?
        let pointCount = SPZReader.pointCountInFile(at: url, error: &nsError)

        if let error = nsError {
            delegate.didFailReading(withError: Error.loadFailed(error.localizedDescription))
            return
        }

        delegate.didStartReading(withPointCount: pointCount > 0 ? UInt32(pointCount) : nil)

        // Load the SPZ file with batch processing
        do {
            try SPZReader.loadSPZFile(at: url, batchHandler: { (points, count) in
                let splatPoints = self.convertPoints(points, count: count)
                delegate.didRead(points: splatPoints)
            })
            delegate.didFinishReading()
        } catch {
            delegate.didFailReading(withError: Error.loadFailed(error.localizedDescription))
        }
    }

    private func convertPoints(_ points: UnsafePointer<SPZGaussianPoint>?, count: UInt) -> [SplatScenePoint] {
        guard let points = points else { return [] }

        var result: [SplatScenePoint] = []
        result.reserveCapacity(Int(count))

        for i in 0..<Int(count) {
            let spzPoint = points[i]

            // Convert position (already in correct coordinate system)
            let position = spzPoint.position

            // Convert rotation quaternion from (w, x, y, z) to simd_quatf
            // SPZ stores as (w, x, y, z), simd_quatf expects (x, y, z, w) in vector form
            let rotation = simd_quatf(
                ix: spzPoint.rotation.y,
                iy: spzPoint.rotation.z,
                iz: spzPoint.rotation.w,
                r: spzPoint.rotation.x
            )

            // Convert scale from log scale to exponent format
            let scale = SplatScenePoint.Scale.exponent(spzPoint.scale)

            // Convert color from SH DC component
            // SPZ stores the raw SH coefficient, we pass it through as spherical harmonic
            let color = SplatScenePoint.Color.sphericalHarmonic([spzPoint.color])

            // Convert alpha from logit format
            let opacity = SplatScenePoint.Opacity.logitFloat(spzPoint.alpha)

            let point = SplatScenePoint(
                position: position,
                color: color,
                opacity: opacity,
                scale: scale,
                rotation: rotation
            )

            result.append(point)
        }

        return result
    }
}
