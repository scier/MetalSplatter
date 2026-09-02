#if os(iOS) || os(macOS)

import Metal
import MetalKit
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import SplatIO
import SwiftUI

@MainActor
class MetalKitSceneRenderer: NSObject, MTKViewDelegate {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.metalsplatter.sampleapp",
               category: "MetalKitSceneRenderer")

    let metalKitView: MTKView
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var model: ModelIdentifier?
    var modelRenderer: (any ModelRenderer)?
    var proceduralSplatController: ProceduralSplatController?

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    var lastRotationUpdateTimestamp: Date? = nil
    var rotation: Angle = .zero

    // Orbit camera. `rotation` above is the idle auto-spin, which folds into
    // cameraYaw and stops as soon as the user takes control.
    var autoRotate = true
    var cameraYaw: Float = 0
    var cameraPitch: Float = 0
    var cameraDistance: Float = -Constants.modelCenterZ
    var cameraTarget: SIMD3<Float> = .zero
    /// Whether to apply the built-in 180-degrees-about-Z up-axis calibration.
    /// Toggle at runtime rather than guessing the convention of a given file.
    var applyUpCalibration = true
    /// Camera-relative fly input: x = right, y = up, z = forward. Unit length.
    var moveInput: SIMD3<Float> = .zero
    /// Speed multiplier while the modifier key is held.
    var moveBoost: Float = 1
    /// Keyboard look input: x = right, y = down (matching mouse delta signs).
    var lookInput: SIMD2<Float> = .zero

    var drawableSize: CGSize = .zero

    init?(_ metalKitView: MTKView) {
        self.device = metalKitView.device!
        guard let queue = self.device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.metalKitView = metalKitView
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        self.model = model

        modelRenderer = nil
        proceduralSplatController = nil
        switch model {
        case .gaussianSplat(let url):
            let splat = try SplatRenderer(device: device,
                                          colorFormat: metalKitView.colorPixelFormat,
                                          depthFormat: metalKitView.depthStencilPixelFormat,
                                          sampleCount: metalKitView.sampleCount,
                                          maxViewCount: 1,
                                          maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            let reader = try AutodetectSceneReader(url)
            let points = try await reader.readAll()
            let chunk = try SplatChunk(device: device, from: points)
            await splat.addChunk(chunk)
            modelRenderer = splat
        case .proceduralSplat:
            let controller = try await ProceduralSplatController(
                device: device,
                colorFormat: metalKitView.colorPixelFormat,
                depthFormat: metalKitView.depthStencilPixelFormat,
                sampleCount: metalKitView.sampleCount,
                maxViewCount: 1,
                maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            proceduralSplatController = controller
            modelRenderer = controller.splatRenderer
        case .sampleBox:
            modelRenderer = try! SampleBoxRenderer(device: device,
                                                   colorFormat: metalKitView.colorPixelFormat,
                                                   depthFormat: metalKitView.depthStencilPixelFormat,
                                                   sampleCount: metalKitView.sampleCount,
                                                   maxViewCount: 1,
                                                   maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        case .none:
            break
        }
    }

    private var viewport: ModelRendererViewportDescriptor {
        let projectionMatrix = matrix_perspective_right_hand(fovyRadians: Float(Constants.fovy.radians),
                                                             aspectRatio: Float(drawableSize.width / drawableSize.height),
                                                             nearZ: max(0.01, cameraDistance * 0.002),
                                                             farZ: max(100, cameraDistance * 20))

        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = applyUpCalibration
            ? matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
            : matrix_identity_float4x4

        // view = inverse(target * yaw * pitch * dolly)
        let viewMatrix = matrix4x4_translation(0, 0, -cameraDistance)
            * matrix4x4_rotation(radians: -cameraPitch, axis: SIMD3<Float>(1, 0, 0))
            * matrix4x4_rotation(radians: -(cameraYaw + Float(rotation.radians)), axis: Constants.rotationAxis)
            * matrix4x4_translation(-cameraTarget.x, -cameraTarget.y, -cameraTarget.z)
            * commonUpCalibration

        let viewport = MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1)

        return ModelRendererViewportDescriptor(viewport: viewport,
                                               projectionMatrix: projectionMatrix,
                                               viewMatrix: viewMatrix,
                                               screenSize: SIMD2(x: Int(drawableSize.width), y: Int(drawableSize.height)))
    }

    private func updateRotation() {
        let now = Date()
        let deltaTime = lastRotationUpdateTimestamp.map { now.timeIntervalSince($0) } ?? 0
        lastRotationUpdateTimestamp = now

        if autoRotate {
            rotation += Constants.rotationPerSecond * deltaTime
        }
        // Clamp dt so a stall (window drag, model load) doesn't teleport the camera.
        let dt = Float(min(deltaTime, 0.1))
        applyLook(deltaTime: dt)
        applyMovement(deltaTime: dt)
    }

    private func applyLook(deltaTime: Float) {
        guard lookInput != .zero, deltaTime > 0 else { return }
        let d = Constants.lookSpeed * deltaTime
        look(dx: lookInput.x * d, dy: lookInput.y * d)
    }

    /// Fly the orbit target through the scene. Moving the target carries the camera
    /// with it, since the camera is derived as target + rotation * (0, 0, distance).
    private func applyMovement(deltaTime: Float) {
        guard moveInput != .zero, deltaTime > 0 else { return }
        takeManualControl()

        let basis = cameraBasis
        let right   =  SIMD3<Float>(basis.columns.0.x, basis.columns.0.y, basis.columns.0.z)
        let up      =  SIMD3<Float>(basis.columns.1.x, basis.columns.1.y, basis.columns.1.z)
        let forward = -SIMD3<Float>(basis.columns.2.x, basis.columns.2.y, basis.columns.2.z)

        // Scale by distance so flying feels the same zoomed in or out.
        let speed = max(0.05, cameraDistance) * Constants.movementSpeed * moveBoost * deltaTime
        cameraTarget += (right * moveInput.x + up * moveInput.y + forward * moveInput.z) * speed
    }

    // MARK: - Camera interaction

    /// Freeze the idle spin at its current angle and hand control to the user.
    private func takeManualControl() {
        guard autoRotate else { return }
        autoRotate = false
        cameraYaw += Float(rotation.radians)
        rotation = .zero
    }

    func toggleAutoRotate() {
        if autoRotate { takeManualControl() } else { autoRotate = true }
    }

    /// Camera orientation as a rotation matrix: columns are right, up, and backward.
    private var cameraBasis: matrix_float4x4 {
        matrix4x4_rotation(radians: cameraYaw + Float(rotation.radians), axis: Constants.rotationAxis)
      * matrix4x4_rotation(radians: cameraPitch, axis: SIMD3<Float>(1, 0, 0))
    }

    /// Where the eye actually sits. The orbit target is the pivot, not the camera.
    private var cameraPosition: SIMD3<Float> {
        let backward = SIMD3<Float>(cameraBasis.columns.2.x, cameraBasis.columns.2.y, cameraBasis.columns.2.z)
        return cameraTarget + backward * cameraDistance
    }

    private func applyRotationDelta(dx: Float, dy: Float) {
        let sensitivity: Float = 0.006
        cameraYaw += dx * sensitivity
        let limit = Float.pi / 2 - 0.01
        cameraPitch = min(limit, max(-limit, cameraPitch - dy * sensitivity))
    }

    /// Turntable orbit: swings the eye around the pivot, so the eye moves.
    func orbit(dx: Float, dy: Float) {
        takeManualControl()
        applyRotationDelta(dx: dx, dy: dy)
    }

    /// Free-look: re-aims the camera while the eye stays put. Same rotation as
    /// `orbit`, but the pivot is moved afterwards to hold the eye in place.
    func look(dx: Float, dy: Float) {
        takeManualControl()
        let eye = cameraPosition
        applyRotationDelta(dx: dx, dy: dy)
        let backward = SIMD3<Float>(cameraBasis.columns.2.x, cameraBasis.columns.2.y, cameraBasis.columns.2.z)
        cameraTarget = eye - backward * cameraDistance
    }

    /// Slide the orbit target across the camera plane. Scaled by distance so it
    /// feels the same whether you're across the room or up against a surface.
    func pan(dx: Float, dy: Float) {
        takeManualControl()
        let basis = cameraBasis
        let right = SIMD3<Float>(basis.columns.0.x, basis.columns.0.y, basis.columns.0.z)
        let up    = SIMD3<Float>(basis.columns.1.x, basis.columns.1.y, basis.columns.1.z)
        let scale = cameraDistance * 0.0015
        cameraTarget += (-right * dx + up * dy) * scale
    }

    /// Multiplicative dolly, so each notch moves a constant fraction of the way in.
    func zoom(_ factor: Float) {
        cameraDistance = min(1000, max(0.01, cameraDistance * factor))
    }

    func toggleUpCalibration() {
        applyUpCalibration.toggle()
        Self.log.info("up-axis calibration: \(self.applyUpCalibration ? "on (default)" : "off (flipped)")")
    }

    func resetCamera() {
        autoRotate = true
        rotation = .zero
        cameraYaw = 0
        cameraPitch = 0
        cameraDistance = -Constants.modelCenterZ
        cameraTarget = .zero
    }

    func draw(in view: MTKView) {
        guard let modelRenderer, modelRenderer.isReadyToRender else { return }
        guard let drawable = view.currentDrawable else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { @Sendable _ in
            semaphore.signal()
        }

        updateRotation()
        proceduralSplatController?.update()

        let didRender: Bool
        do {
            didRender = try modelRenderer.render(viewports: [viewport],
                                                 colorTexture: view.multisampleColorTexture ?? drawable.texture,
                                                 colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
                                                 depthTexture: view.depthStencilTexture,
                                                 rasterizationRateMap: nil,
                                                 renderTargetArrayLength: 0,
                                                 to: commandBuffer)
        } catch {
            Self.log.error("Unable to render scene: \(error.localizedDescription)")
            didRender = false
        }

        if didRender {
            commandBuffer.present(drawable)
        }

        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }
}

#endif // os(iOS) || os(macOS)
