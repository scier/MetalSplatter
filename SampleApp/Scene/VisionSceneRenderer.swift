#if os(visionOS)

import CompositorServices
import Metal
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import SplatIO
import SwiftUI

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

/// VisionSceneRenderer manages rendering for visionOS immersive spaces.
/// It's marked @unchecked Sendable because it manages thread safety manually:
/// - LayerRenderer access is confined to the render thread
/// - Model loading uses async/await
/// - State changes are synchronized through the RendererTaskExecutor
final class VisionSceneRenderer: @unchecked Sendable {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "VisionSceneRenderer")

    let layerRenderer: LayerRenderer
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private var model: ModelIdentifier?
    private var modelRenderer: (any ModelRenderer)?

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    private var lastRotationUpdateTimestamp: Date? = nil
    private var rotation: Angle = .zero

    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider

    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!

        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
    }

    /// Static entry point for starting the renderer.
    static func startRendering(_ layerRenderer: LayerRenderer, model: ModelIdentifier?) {
        let renderer = VisionSceneRenderer(layerRenderer)
        Task {
            do {
                try await renderer.load(model)
            } catch {
                log.error("Error loading model: \(error.localizedDescription)")
            }
            renderer.startRenderLoop()
        }
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        self.model = model

        modelRenderer = nil
        switch model {
        case .gaussianSplat(let url):
            let splat = try SplatRenderer(device: device,
                                          colorFormat: layerRenderer.configuration.colorFormat,
                                          depthFormat: layerRenderer.configuration.depthFormat,
                                          sampleCount: 1,
                                          maxViewCount: layerRenderer.properties.viewCount,
                                          maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            let reader = try AutodetectSceneReader(url)
            let points = try await reader.readAll()
            let chunk = try SplatChunk(device: device, from: points)
            await splat.addChunk(chunk)
            modelRenderer = splat
        case .sampleBox:
            modelRenderer = try SampleBoxRenderer(device: device,
                                                  colorFormat: layerRenderer.configuration.colorFormat,
                                                  depthFormat: layerRenderer.configuration.depthFormat,
                                                  sampleCount: 1,
                                                  maxViewCount: layerRenderer.properties.viewCount,
                                                  maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        case .none:
            break
        }
    }

    func startRenderLoop() {
        Task(executorPreference: RendererTaskExecutor.shared) {
            do {
                try await self.arSession.run([self.worldTracking])
            } catch {
                fatalError("Failed to initialize ARSession")
            }

            self.renderLoop()
        }
    }

    private func viewports(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) -> [ModelRendererViewportDescriptor] {
        let rotationMatrix = matrix4x4_rotation(radians: Float(rotation.radians),
                                                axis: Constants.rotationAxis)
        let translationMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        return drawable.views.enumerated().map { (index, view) in
            let userViewpointMatrix = (simdDeviceAnchor * view.transform).inverse
            let projectionMatrix = drawable.computeProjection(viewIndex: index)
            let screenSize = SIMD2(x: Int(view.textureMap.viewport.width),
                                   y: Int(view.textureMap.viewport.height))
            return ModelRendererViewportDescriptor(viewport: view.textureMap.viewport,
                                                   projectionMatrix: projectionMatrix,
                                                   viewMatrix: userViewpointMatrix * translationMatrix * rotationMatrix * commonUpCalibration,
                                                   screenSize: screenSize)
        }
    }

    private func updateRotation() {
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }

        guard let lastRotationUpdateTimestamp else { return }
        rotation += Constants.rotationPerSecond * now.timeIntervalSince(lastRotationUpdateTimestamp)
    }

    func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        frame.startSubmission()

        updateRotation()

        // Use first drawable for timing/anchor calculations
        let primaryDrawable = drawables[0]
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: primaryDrawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)

        for (index, drawable) in drawables.enumerated() {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                fatalError("Failed to create command buffer")
            }

            drawable.deviceAnchor = deviceAnchor

            // Signal semaphore when the last drawable's command buffer completes
            if index == drawables.count - 1 {
                let semaphore = inFlightSemaphore
                commandBuffer.addCompletedHandler { _ in
                    semaphore.signal()
                }
            }

            let viewports = self.viewports(drawable: drawable, deviceAnchor: deviceAnchor)

            let didRender: Bool
            do {
                didRender = try modelRenderer?.render(viewports: viewports,
                                                      colorTexture: drawable.colorTextures[0],
                                                      colorStoreAction: .store,
                                                      depthTexture: drawable.depthTextures[0],
                                                      rasterizationRateMap: drawable.rasterizationRateMaps.first,
                                                      renderTargetArrayLength: layerRenderer.configuration.layout == .layered ? drawable.views.count : 1,
                                                      to: commandBuffer) ?? false
            } catch {
                Self.log.error("Unable to render scene: \(error.localizedDescription)")
                didRender = false
            }

            // Only present if rendering occurred; otherwise drop the frame
            if didRender {
                drawable.encodePresent(commandBuffer: commandBuffer)
            }

            commandBuffer.commit()
        }

        frame.endSubmission()
    }

    func renderLoop() {
        while true {
            autoreleasepool {
                if layerRenderer.state == .invalidated {
                    Self.log.warning("Layer is invalidated")
                    return
                } else if layerRenderer.state == .paused {
                    layerRenderer.waitUntilRunning()
                    return
                } else {
                    self.renderFrame()
                }
            }
            if layerRenderer.state == .invalidated {
                return
            }
        }
    }
}

final class RendererTaskExecutor: TaskExecutor {
    static let shared = RendererTaskExecutor()
    private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    nonisolated func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

#endif // os(visionOS)

