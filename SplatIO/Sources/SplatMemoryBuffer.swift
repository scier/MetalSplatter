import Foundation

public struct SplatMemoryBuffer {
    public var points: [SplatScenePoint] = []

    public init() {}

    /** Replace the content of points with the content read from the given SplatSceneReader. */
    mutating public func read(from reader: SplatSceneReader) async throws {
        points.removeAll()
        for try await batch in try await reader.read() {
            points.append(contentsOf: batch)
        }
    }
}
