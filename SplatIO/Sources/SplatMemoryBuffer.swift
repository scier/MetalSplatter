import Foundation

public struct SplatMemoryBuffer {
    private class BufferReader: SplatSceneReaderDelegate {
        enum Error: Swift.Error {
            case unknown
        }

        private let continuation: CheckedContinuation<[SplatScenePoint], Swift.Error>
        private var points: [SplatScenePoint] = []

        public init(continuation: CheckedContinuation<[SplatScenePoint], Swift.Error>) {
            self.continuation = continuation
        }

        public func didStartReading(withPointCount pointCount: UInt32?) {}

        public func didRead(points: [SplatIO.SplatScenePoint]) {
            self.points.append(contentsOf: points)
        }

        public func didFinishReading() {
            continuation.resume(returning: points)
        }

        public func didFailReading(withError error: Swift.Error?) {
            continuation.resume(throwing: error ?? BufferReader.Error.unknown)
        }
    }

    public var points: [SplatScenePoint] = []

    public init() {}

    /** Replace the content of points with the content read from the given SplatSceneReader. */
    mutating public func read(from reader: SplatSceneReader) async throws {
        points = try await withCheckedThrowingContinuation { continuation in
            reader.read(to: BufferReader(continuation: continuation))
        }
    }
}
