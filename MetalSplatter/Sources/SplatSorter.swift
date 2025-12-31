import Metal
import simd

@MainActor
class SplatSorter<SplatIndexType: BinaryInteger> {
    private enum State {
        case idle
        case sorting
        case sorted
    }

    struct SplatIndexAndDepth {
        var index: SplatIndexType
        var depth: Float
    }

    private var state = State.idle
    private var bufferPrime: MetalBuffer<SplatIndexType>
    private var orderAndDepthTempSort: [SplatIndexAndDepth] = []

    init(device: MTLDevice) throws {
        bufferPrime = try MetalBuffer<SplatIndexType>(device: device)
    }

    func retrieveSortIfComplete(activeBuffer: inout MetalBuffer<SplatIndexType>) {
        switch state {
        case .idle, .sorting:
            return
        case .sorted:
            swap(&activeBuffer, &bufferPrime)
            state = .idle
        }
    }

    func triggerSort(splatBuffer: MetalBuffer<SplatRenderer.Splat>,
                     cameraWorldPosition: SIMD3<Float>,
                     cameraWorldForward: SIMD3<Float>,
                     onStart: (() -> Void)?,
                     onComplete: ((TimeInterval) -> Void)?) {
        switch state {
        case .idle:
            state = .sorting
        case .sorting, .sorted:
            return
        }

        assert(state == .sorting)

        onStart?()
        let sortStartTime = Date()

        let splatCount = splatBuffer.count
        let bufferPrime = bufferPrime
        var orderAndDepthTempSort = orderAndDepthTempSort

        Task.detached(priority: .high) {
            if bufferPrime.count < splatCount {
                try bufferPrime.ensureCapacity(splatCount)
                for i in bufferPrime.count..<splatCount {
                    bufferPrime.append(SplatIndexType(i))
                }
                assert(bufferPrime.count == splatCount)
            } else if bufferPrime.count > splatCount {
                bufferPrime.count = splatCount
            }

            if orderAndDepthTempSort.count != splatCount {
                orderAndDepthTempSort = Array(repeating: SplatIndexAndDepth(index: 0, depth: 0), count: splatCount)
            }

            if SplatRenderer.Constants.sortByDistance {
                for i in 0..<splatCount {
                    let index = bufferPrime.values[i]
                    orderAndDepthTempSort[i].index = index
                    let splatPosition = splatBuffer.values[Int(index)].position.simd
                    orderAndDepthTempSort[i].depth = (splatPosition - cameraWorldPosition).lengthSquared
                }
            } else {
                for i in 0..<splatCount {
                    let index = bufferPrime.values[i]
                    orderAndDepthTempSort[i].index = index
                    let splatPosition = splatBuffer.values[Int(index)].position.simd
                    orderAndDepthTempSort[i].depth = dot(splatPosition, cameraWorldForward)
                }
            }

            orderAndDepthTempSort.sort { $0.depth > $1.depth }

            do {
                try bufferPrime.ensureCapacity(splatCount)
                bufferPrime.count = splatCount
                for i in 0..<orderAndDepthTempSort.count {
                    bufferPrime.values[i] = orderAndDepthTempSort[i].index
                }
            } catch {
                // TODO: report error
            }

            Task { @MainActor in
                self.state = .sorted
                self.orderAndDepthTempSort = orderAndDepthTempSort
                onComplete?(-sortStartTime.timeIntervalSinceNow)
            }
        }
    }
}

private extension MTLPackedFloat3 {
    var simd: SIMD3<Float> {
        SIMD3(x: x, y: y, z: z)
    }
}

