import ArgumentParser
import Foundation
import PLYIO
import SplatIO

@main
struct SplatConverter: AsyncParsableCommand {
    enum Error: Swift.Error {
        case unknownReadError(String)
        case unknownWriteError(String)
    }

    static let configuration = CommandConfiguration(
        commandName: "SplatConverter",
        abstract: "A utility for converting splat scene files",
        version: "1.0.0"
    )

    @Argument(help: "The input splat scene file")
    var inputFile: String

    @Option(name: .shortAndLong, help: "The output splat scene file")
    var outputFile: String?

    @Option(name: [.customShort("f"), .long], help: "The format of the output file (dotSplat, ply, ply-ascii)")
    var outputFormat: SplatOutputFileFormat?

    @Flag(name: [.long], help: "Describe each of the splats from first to first + count")
    var describe = false

    @Option(name: [.long], help: "Index of first splat to convert")
    var start: Int = 0

    @Option(name: [.long], help: "Maximum number of splats to convert")
    var count: Int?

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose = false

    func run() async throws {
        let reader = try AutodetectSceneReader(URL(fileURLWithPath: inputFile))

        var outputFormat = outputFormat
        if let outputFile, outputFormat == nil {
            outputFormat = .init(defaultFor: SplatFileFormat(for: URL(fileURLWithPath: outputFile)))
            if outputFormat == nil {
                throw ValidationError("No output format specified")
            }
        }

        let delegate = ReaderDelegate(save: outputFile != nil,
                                      start: start,
                                      count: count,
                                      describe: describe,
                                      inputLabel: inputFile,
                                      outputLabel: outputFile)
        let readDuration = try await ContinuousClock().measure {
            let stream = try await reader.read()
            for try await scenePoints in stream {
                delegate.didRead(points: scenePoints)
            }
        }

        if verbose {
            let pointsPerSecond = Double(delegate.readCount) / max(readDuration.asSeconds, 1e-6)
            print("Read \(delegate.readCount) points from \(inputFile) in \(readDuration.asSeconds.formatted(.number.precision(.fractionLength(2)))) seconds (\(pointsPerSecond.formatted(.number.precision(.fractionLength(0)))) points/s)")
        }
        if let error = delegate.error {
            throw error
        }

        if let outputFile, let outputFormat {
            let outputURL = URL(fileURLWithPath: outputFile)
            let writeDuration = try await ContinuousClock().measure {
                switch outputFormat {
                case .dotSplat:
                    let writer = try DotSplatSceneWriter(to: .file(outputURL))
                    try await writer.write(delegate.points)
                    try await writer.close()
                case .binaryPLY:
                    let writer = try SplatPLYSceneWriter(to: .file(outputURL))
                    try await writer.start(sphericalHarmonicDegree: 3, binary: true, pointCount: delegate.points.count)
                    try await writer.write(delegate.points)
                    try await writer.close()
                case .asciiPLY:
                    let writer = try SplatPLYSceneWriter(to: .file(outputURL))
                    try await writer.start(sphericalHarmonicDegree: 3, binary: false, pointCount: delegate.points.count)
                    try await writer.write(delegate.points)
                    try await writer.close()
                }
            }

            if verbose {
                let pointsPerSecond = Double(delegate.points.count) / max(writeDuration.asSeconds, 1e-6)
                print("Wrote \(delegate.points.count) points to \(outputFile) in  \(writeDuration.asSeconds.formatted(.number.precision(.fractionLength(2)))) seconds (\(pointsPerSecond.formatted(.number.precision(.fractionLength(0)))) points/s)")
            }

        }
    }

    class ReaderDelegate {
        let save: Bool
        let start: Int
        let count: Int?
        let describe: Bool
        let inputLabel: String
        let outputLabel: String?
        var error: Swift.Error?

        var points: [SplatScenePoint] = []
        var currentOffset = 0
        var readCount = 0

        init(save: Bool,
             start: Int,
             count: Int?,
             describe: Bool,
             inputLabel: String,
             outputLabel: String?) {
            self.save = save
            self.start = start
            self.count = count
            self.describe = describe
            self.inputLabel = inputLabel
            self.outputLabel = outputLabel
        }

        func didRead(points: [SplatIO.SplatScenePoint]) {
            readCount += points.count

            let newCurrentOffset = currentOffset + points.count
            defer {
                currentOffset = newCurrentOffset
            }

            var points = points
            if start > currentOffset {
                let relativeStart = start - currentOffset
                if relativeStart >= points.count {
                    return
                }

                points = Array(points.suffix(points.count - relativeStart))

                // The deferred currentOffset = newCurrentOffset will set currentOffset to be ready for the next
                // call to didRead(), but we need to set it temporarily in the meantime
                currentOffset = start
            }

            if let count {
                let countRemaining = start + count - currentOffset
                if countRemaining <= 0 {
                    return
                }
                if countRemaining < points.count {
                    points = Array(points.prefix(countRemaining))
                }
            }

            if save {
                self.points.append(contentsOf: points)
            }

            if describe {
                for i in 0..<points.count {
                    print("\(currentOffset + i): \(points[i].description)")
                }
            }
        }
    }
}

enum SplatOutputFileFormat: ExpressibleByArgument {
    case asciiPLY
    case binaryPLY
    case dotSplat

    public init?(argument: String) {
        switch argument.lowercased() {
        case "dotsplat": self = .dotSplat
        case "ply": self.init(defaultFor: .ply)
        case "plybinary", "ply-binary", "binaryply", "binary-ply": self = .binaryPLY
        case "plyascii", "ply-ascii", "asciiply", "ascii-ply": self = .asciiPLY
        default: return nil
        }
    }

    public init?(defaultFor format: SplatFileFormat?) {
        switch format {
        case .dotSplat: self = .dotSplat
        case .ply: self = .binaryPLY
        case .none: return nil
        }
    }
}

fileprivate extension Duration {
    var asSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
