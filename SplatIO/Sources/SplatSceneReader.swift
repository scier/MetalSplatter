import Foundation

public protocol SplatSceneReader {
    func read() async throws -> AsyncThrowingStream<[SplatPoint], Error>
}

extension SplatSceneReader {
    /// Read all points from the reader into an array.
    public func readAll() async throws -> [SplatPoint] {
        var points: [SplatPoint] = []
        for try await batch in try await read() {
            points.append(contentsOf: batch)
        }
        return points
    }
}
