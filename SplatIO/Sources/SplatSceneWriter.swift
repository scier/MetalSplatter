import Foundation

public protocol SplatSceneWriter {
    func write(_ points: [SplatScenePoint]) throws
    func close() throws
}
