import Foundation

public class AutodetectSceneReader: SplatSceneReader {
    public enum Error: Swift.Error {
        case unknownPathExtension
    }

    private let reader: SplatSceneReader

    public init(_ url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "ply": reader = SplatPLYSceneReader(url)
        case "splat": reader = DotSplatSceneReader(url)
        default: throw Error.unknownPathExtension
        }
    }

    public func read(to delegate: any SplatSceneReaderDelegate) {
        reader.read(to: delegate)
    }
}
