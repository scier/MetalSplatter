import Foundation
import SwiftUI

enum Constants {
    static let maxSimultaneousRenders = 3
    static let rotationPerSecond = Angle(degrees: 7)
    static let rotationAxis = SIMD3<Float>(0, 1, 0)
#if !os(visionOS)
    static let fovy = Angle(degrees: 65)
#endif
    static let modelCenterZ: Float = -8
    /// Fly speed, as a fraction of the current camera distance per second.
    static let movementSpeed: Float = 0.9
    /// Multiplier while the speed modifier (shift) is held.
    static let movementBoost: Float = 3
    /// Keyboard look rate, in mouse-pixel equivalents per second.
    static let lookSpeed: Float = 260

    // Procedural splat geometry
    static let proceduralCubeSize: Float = 1.0
    static let proceduralCubeDistance: Float = 1.0
    static let proceduralCubeGridSizes: [Int] = [10, 20, 50]
    static let proceduralCubeSplatRelativeRadius: Float = 0.1
    static let proceduralCubeSwapDelay: TimeInterval = 2.0
}

