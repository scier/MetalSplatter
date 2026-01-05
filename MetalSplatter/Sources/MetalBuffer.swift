import Foundation
import Metal
import os

fileprivate let log =
    Logger(subsystem: Bundle.module.bundleIdentifier ?? "MetalSplatter",
           category: "MetalBuffer")

class MetalBuffer<T> {
    enum Error: LocalizedError {
        case capacityGreatedThanMaxCapacity(requested: Int, max: Int)
        case bufferCreationFailed

        var errorDescription: String? {
            switch self {
            case .capacityGreatedThanMaxCapacity(let requested, let max):
                "Requested metal buffer size (\(requested)) exceeds device maximum (\(max))"
            case .bufferCreationFailed:
                "Failed to create metal buffer"
            }
        }
    }

    let device: MTLDevice

    var capacity: Int = 0
    var count: Int = 0
    var buffer: MTLBuffer
    var values: UnsafeMutablePointer<T>

    init(device: MTLDevice, capacity: Int = 1) throws {
        let capacity = max(capacity, 1)
        guard capacity <= Self.maxCapacity(for: device) else {
            throw Error.capacityGreatedThanMaxCapacity(requested: capacity, max: Self.maxCapacity(for: device))
        }

        self.device = device

        self.capacity = capacity
        self.count = 0
        guard let buffer = device.makeBuffer(length: MemoryLayout<T>.stride * self.capacity,
                                             options: .storageModeShared) else {
            throw Error.bufferCreationFailed
        }
        self.buffer = buffer
        self.values = UnsafeMutableRawPointer(self.buffer.contents()).bindMemory(to: T.self, capacity: self.capacity)
    }

    static func maxCapacity(for device: MTLDevice) -> Int {
        device.maxBufferLength / MemoryLayout<T>.stride
    }

    var maxCapacity: Int {
        device.maxBufferLength / MemoryLayout<T>.stride
    }

    func setCapacity(_ newCapacity: Int) throws {
        let newCapacity = max(newCapacity, 1)
        guard newCapacity != capacity else { return }
        guard capacity <= maxCapacity else {
            throw Error.capacityGreatedThanMaxCapacity(requested: capacity, max: maxCapacity)
        }

        log.info("Allocating a new buffer of size \(MemoryLayout<T>.stride) * \(newCapacity) = \(Float(MemoryLayout<T>.stride * newCapacity) / (1024.0 * 1024.0))mb")
        guard let newBuffer = device.makeBuffer(length: MemoryLayout<T>.stride * newCapacity,
                                                options: .storageModeShared) else {
            throw Error.bufferCreationFailed
        }
        let newValues = UnsafeMutableRawPointer(newBuffer.contents()).bindMemory(to: T.self, capacity: newCapacity)
        let newCount = min(count, newCapacity)
        if newCount > 0 {
            memcpy(newValues, values, MemoryLayout<T>.stride * newCount)
        }

        self.capacity = newCapacity
        self.count = newCount
        self.buffer = newBuffer
        self.values = newValues
    }

    func ensureCapacity(_ minimumCapacity: Int) throws {
        guard capacity < minimumCapacity else { return }
        try setCapacity(minimumCapacity)
    }

    /// Assumes capacity is available
    /// Returns the index of the value
    @discardableResult
    func append(_ element: T) -> Int {
        (values + count).pointee = element
        defer { count += 1 }
        return count
    }

    /// Assumes capacity is available.
    /// Returns the index of the first values.
    @discardableResult
    func append(_ elements: [T]) -> Int {
        (values + count).update(from: elements, count: elements.count)
        defer { count += elements.count }
        return count
    }

    /// Assumes capacity is available
    /// Returns the index of the value
    @discardableResult
    func append(_ otherBuffer: MetalBuffer<T>, fromIndex: Int) -> Int {
        (values + count).pointee = (otherBuffer.values + fromIndex).pointee
        defer { count += 1 }
        return count
    }
}
