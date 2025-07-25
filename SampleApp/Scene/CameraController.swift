#if os(macOS)
import simd

final class CameraController: ObservableObject {
    @Published var yaw: Float = 0
    @Published var pitch: Float = 0
    @Published var distance: Float = -Constants.modelCenterZ

    private let minDistance: Float = 1
    private let maxDistance: Float = 50
    private let pitchLimit: Float = .pi / 2 - 0.01

    func rotate(deltaX: Float, deltaY: Float) {
        yaw += deltaX
        pitch = max(-pitchLimit, min(pitchLimit, pitch + deltaY))
    }

    func zoom(delta: Float) {
        distance = max(minDistance, min(maxDistance, distance - delta))
    }

    var viewMatrix: simd_float4x4 {
        let translation = matrix4x4_translation(0, 0, -distance)
        let pitchMatrix = matrix4x4_rotation(radians: pitch, axis: SIMD3<Float>(1, 0, 0))
        let yawMatrix = matrix4x4_rotation(radians: yaw, axis: SIMD3<Float>(0, 1, 0))
        return translation * pitchMatrix * yawMatrix
    }
}
#endif
