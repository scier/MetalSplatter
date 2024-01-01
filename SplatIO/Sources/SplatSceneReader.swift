import Foundation

public protocol SplatSceneReaderDelegate: AnyObject {
    func didStartReading(withPointCount pointCount: UInt32)
    func didRead(points: [SplatScenePoint])
    func didFinishReading()
    func didFailReading(withError error: Error?)
}

public protocol SplatSceneReader {
    func read(to delegate: SplatSceneReaderDelegate)
}
