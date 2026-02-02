import Foundation

@available(*, deprecated, message: "Use SplatSceneReader.readAll() instead")
public struct SplatMemoryBuffer {
    public var points: [SplatPoint] = []

    public init() {}

    /** Replace the content of points with the content read from the given SplatSceneReader. */
    mutating public func read(from reader: SplatSceneReader) async throws {
        points = try await reader.readAll()
    }
}
