import Foundation

public class AutodetectSceneReader: SplatSceneReader {
    public enum Error: Swift.Error {
        case cannotDetermineFormat
    }

    private let url: URL

    public init(_ url: URL) throws {
        self.url = url
    }

    public func read() async throws -> AsyncThrowingStream<[SplatScenePoint], Swift.Error> {
        let reader: SplatSceneReader =
        switch SplatFileFormat(for: url) {
        case .ply: try SplatPLYSceneReader(url)
        case .dotSplat: try DotSplatSceneReader(url)
        case .none: throw Error.cannotDetermineFormat
        }

        return try await reader.read()
    }
}
