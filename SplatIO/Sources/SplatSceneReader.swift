import Foundation

public protocol SplatSceneReader {
    func read() async throws -> AsyncThrowingStream<[SplatScenePoint], Error>
}
