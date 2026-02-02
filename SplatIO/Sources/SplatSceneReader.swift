import Foundation

public protocol SplatSceneReader {
    func read() async throws -> AsyncThrowingStream<[SplatScenePoint], Error>
}

extension SplatSceneReader {
    /// Read all points from the reader into an array.
    public func readAll() async throws -> [SplatScenePoint] {
        var points: [SplatScenePoint] = []
        for try await batch in try await read() {
            points.append(contentsOf: batch)
        }
        return points
    }
}
