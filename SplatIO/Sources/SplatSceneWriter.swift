import Foundation

public protocol SplatSceneWriter {
    func write(_ points: [SplatScenePoint]) async throws
    func close() async throws
    var writtenData: Data? { get async }
}
