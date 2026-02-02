import Foundation
import simd
import spz
import PLYIO // Needed for WriterDestination

/// A writer for Gaussian Splat files in the SPZ format.
///
/// Usage:
/// ```swift
/// let writer = try SPZSceneWriter(to: .memory)
/// try await writer.start(numPoints: 1000)
/// try await writer.write(points)  // Can be called multiple times
/// try await writer.close()
/// let data = await writer.writtenData
/// ```
public class SPZSceneWriter: SplatSceneWriter {
    public enum Error: Swift.Error {
        case cannotWriteToFile(URL)
        case writeError(Swift.Error)
        case cannotWriteAfterClose
        case notStarted
        case alreadyStarted
        case tooManyPoints
    }

    private let destination: WriterDestination
    private var cloud: GaussianCloud?
    private var currentShDegree: SHDegree = .sh0
    private var shDim: Int = 0
    private var totalPoints: Int = 0
    private var pointsWritten: Int = 0
    private var closed = false
    private var _writtenData: Data?

    public init(to destination: WriterDestination) throws {
        self.destination = destination
    }

    public convenience init(toFileAtPath path: String) throws {
        try self.init(to: .file(URL(fileURLWithPath: path)))
    }

    public var writtenData: Data? {
        get async {
            _writtenData
        }
    }

    /// Initialize the writer with the expected number of points.
    ///
    /// This pre-allocates internal arrays to avoid accumulating `SplatScenePoint` objects.
    /// Must be called before `write()`.
    ///
    /// The spherical harmonics degree is auto-detected from the points written and upgraded
    /// as needed. If you need to truncate points to a lower SH degree, do so before writing.
    ///
    /// - Parameter numPoints: Total number of points that will be written.
    public func start(numPoints: Int) async throws {
        guard cloud == nil else {
            throw Error.alreadyStarted
        }

        self.totalPoints = numPoints
        self.currentShDegree = .sh0
        self.shDim = 0

        var newCloud = GaussianCloud()
        newCloud.numPoints = Int32(numPoints)
        newCloud.shDegree = 0
        newCloud.antialiased = false

        // Pre-allocate arrays (sh array starts empty, allocated on first higher-order point)
        newCloud.positions = Array(repeating: 0, count: numPoints * 3)
        newCloud.scales = Array(repeating: 0, count: numPoints * 3)
        newCloud.rotations = Array(repeating: 0, count: numPoints * 4)
        newCloud.alphas = Array(repeating: 0, count: numPoints)
        newCloud.colors = Array(repeating: 0, count: numPoints * 3)
        newCloud.sh = []

        self.cloud = newCloud
    }

    /// Write points to the SPZ file. Can be called multiple times. `start()` must be called first.
    ///
    /// Points are packed directly into pre-allocated arrays. If the SH degree was not specified
    /// in `start()`, it will be auto-detected and upgraded as needed based on the points written.
    ///
    /// - Parameter points: Points to write.
    public func write(_ points: [SplatScenePoint]) async throws {
        guard !closed else {
            throw Error.cannotWriteAfterClose
        }

        guard var cloud = self.cloud else {
            throw Error.notStarted
        }

        guard pointsWritten + points.count <= totalPoints else {
            throw Error.tooManyPoints
        }

        // Check if we need to upgrade SH degree based on incoming points
        let batchMaxDegree = points.reduce(currentShDegree) { max($0, $1.color.shDegree) }
        if batchMaxDegree > currentShDegree {
            upgradeShDegree(to: batchMaxDegree, cloud: &cloud)
        }

        // Pack points directly into cloud arrays
        for point in points {
            let i = pointsWritten

            // Position
            cloud.positions[i * 3 + 0] = point.position.x
            cloud.positions[i * 3 + 1] = point.position.y
            cloud.positions[i * 3 + 2] = point.position.z

            // Scale (as exponent/log)
            let scaleExp = point.scale.asExponent
            cloud.scales[i * 3 + 0] = scaleExp.x
            cloud.scales[i * 3 + 1] = scaleExp.y
            cloud.scales[i * 3 + 2] = scaleExp.z

            // Rotation: simd_quatf stores as (ix, iy, iz, r) which maps to (x, y, z, w)
            cloud.rotations[i * 4 + 0] = point.rotation.imag.x
            cloud.rotations[i * 4 + 1] = point.rotation.imag.y
            cloud.rotations[i * 4 + 2] = point.rotation.imag.z
            cloud.rotations[i * 4 + 3] = point.rotation.real

            // Alpha (as logit)
            cloud.alphas[i] = point.opacity.asLogitFloat

            // Color: Extract SH coefficients
            let shCoeffs = point.color.asSphericalHarmonicFloat

            // DC component (sh0) goes to colors array
            let dc = shCoeffs.first ?? SIMD3<Float>(0, 0, 0)
            cloud.colors[i * 3 + 0] = dc.x
            cloud.colors[i * 3 + 1] = dc.y
            cloud.colors[i * 3 + 2] = dc.z

            // Higher order SH coefficients go to sh array (interleaved RGB)
            if shDim > 0 {
                let shStart = i * shDim * 3
                for j in 0..<shDim {
                    // Get coefficient j+1 (skip DC which is at index 0)
                    let coeff: SIMD3<Float>
                    if j + 1 < shCoeffs.count {
                        coeff = shCoeffs[j + 1]
                    } else {
                        coeff = SIMD3<Float>(0, 0, 0)  // Pad with zeros if source has fewer coefficients
                    }
                    cloud.sh[shStart + j * 3 + 0] = coeff.x
                    cloud.sh[shStart + j * 3 + 1] = coeff.y
                    cloud.sh[shStart + j * 3 + 2] = coeff.z
                }
            }

            pointsWritten += 1
        }

        self.cloud = cloud
    }

    /// Finalize and write the SPZ file. This performs the actual compression and I/O.
    public func close() async throws {
        guard !closed else { return }
        closed = true

        guard let cloud = self.cloud else {
            // Nothing to write
            return
        }

        // Save to SPZ format (RDF coordinate system to match PLY convention)
        do {
            let data = try saveSpz(cloud, options: PackOptions(from: .rdf))

            switch destination {
            case .file(let url):
                try data.write(to: url)
            case .memory:
                _writtenData = data
            }
        } catch {
            throw Error.writeError(error)
        }

        // Release cloud memory
        self.cloud = nil
    }

    /// Upgrade the SH degree, reallocating and copying existing data as needed.
    private func upgradeShDegree(to newDegree: SHDegree, cloud: inout GaussianCloud) {
        let newShDim = shDimForDegree(Int32(newDegree.rawValue))
        guard newShDim > shDim else { return }

        // Create new sh array (zeros by default)
        var newSh = Array(repeating: Float(0), count: totalPoints * newShDim * 3)

        // Copy existing coefficients for already-written points
        if shDim > 0 {
            for i in 0..<pointsWritten {
                let oldStart = i * shDim * 3
                let newStart = i * newShDim * 3
                for j in 0..<(shDim * 3) {
                    newSh[newStart + j] = cloud.sh[oldStart + j]
                }
            }
        }

        cloud.sh = newSh
        cloud.shDegree = Int32(newDegree.rawValue)
        currentShDegree = newDegree
        shDim = newShDim
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

