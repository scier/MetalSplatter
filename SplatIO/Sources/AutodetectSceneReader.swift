import Foundation

public class AutodetectSceneReader: SplatSceneReader {
    public enum Error: Swift.Error {
        case cannotDetermineFormat
    }

    private let reader: SplatSceneReader

    public init(_ url: URL) throws {
        switch SplatFileFormat(for: url) {
        case .ply: reader = try SplatPLYSceneReader(url)
        case .dotSplat: reader = try DotSplatSceneReader(url)
        case .spz: reader = try SPZSceneReader(url)
        case .none: throw Error.cannotDetermineFormat
        }
    }

    public func read(to delegate: any SplatSceneReaderDelegate) {
        reader.read(to: delegate)
    }
}
