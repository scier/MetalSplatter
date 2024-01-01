import Accelerate
import Foundation
import Metal
import MetalKit
import SplatIO

public class SplatRenderer {
    enum Constants {
        // Keep in sync with Shaders.metal : maxViewCount
        static let maxViewCount = 2
        // Sort by euclidian distance squared from camera position (true), or along the "forward" vector (false)
        // TODO: compare the behaviour and performance of sortByDistance
        // notes: sortByDistance introduces unstable artifacts when you get close to an object; whereas !sortByDistance introduces artifacts are you turn -- but they're a little subtler maybe?
        static let sortByDistance = false
        // TODO: compare the performance of useAccelerateForSort, both for small and large scenes
        static let useAccelerateForSort = false
        static let renderFrontToBack = true
        static let screenWidth: UInt32 = 1024
    }

    private static let log =
        Logger(subsystem: Bundle.module.bundleIdentifier!,
               category: "SplatRenderer")

    public typealias CameraMatrices = ( projection: simd_float4x4, view: simd_float4x4 )

    // Keep in sync with Shaders.metal : BufferIndex
    enum BufferIndex: NSInteger {
        case uniforms = 0
        case splat    = 1
        case order    = 2
    }

    // Keep in sync with Shaders.metal : SplatAttribute
    enum SplatAttribute: NSInteger, CaseIterable {
        case position     = 0
        case color        = 1
        case scale        = 2
        case rotationQuat = 3
    }

    // Keep in sync with Shaders.metal : Uniforms
    struct Uniforms {
        var projectionMatrix: matrix_float4x4
        var viewMatrix: matrix_float4x4
        var screenSize: SIMD2<UInt32> // Size of screen in pixels
    }

    // Keep in sync with Shaders.metal : UniformsArray
    struct UniformsArray {
        // maxViewCount = 2, so we have 2 entries
        var uniforms0: Uniforms
        var uniforms1: Uniforms

        // The 256 byte aligned size of our uniform structure
        static var alignedSize: Int { (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100 }

        mutating func setUniforms(index: Int, _ uniforms: Uniforms) {
            switch index {
            case 0: uniforms0 = uniforms
            case 1: uniforms1 = uniforms
            default: break
            }
        }
    }

    // Keep in sync with Shaders.metal : Vertex
    struct Splat {
        var position: SIMD3<Float>
        var color: SIMD4<Float>
        var scale: SIMD3<Float>
        var rotation: simd_quatf
    }

    struct SplatIndexAndDepth {
        var index: UInt32
        var depth: Float
    }

    var pipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    public let maxViewCount: Int
    public let maxSimultaneousRenders: Int

    // dynamicUniformBuffers contains maxSimultaneousRenders uniforms buffers,
    // which we round-robin through, one per render; this is managed by switchToNextDynamicBuffer.
    // uniforms = the i'th buffer (where i = uniformBufferIndex, which varies from 0 to maxSimultaneousRenders-1)
    var dynamicUniformBuffers: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<UniformsArray>

    // cameraWorldPosition and Forward vectors are the latest mean camera position across all viewports
    var cameraWorldPosition: SIMD3<Float> = .zero
    var cameraWorldForward: SIMD3<Float> = .init(x: 0, y: 0, z: -1)

    typealias IndexType = UInt32
    // splatBuffer contains one entry for each gaussian splat
    var splatBuffer: MetalBuffer<Splat>
    // orderBuffer indexes into splatBuffer, and is sorted by distance
    var orderBuffer: MetalBuffer<IndexType>

    var sorting = false
    // orderBufferPrime is a copy of orderBuffer, which is not currenly in use for rendering.
    // We use this for sorting, and when we're done, swap it with orderBuffer.
    // There's a good chance that we'll sometimes end up sorting an orderBuffer still in use for
    // rendering;.
    // TODO: Replace this with a more robust multiple-buffer scheme to guarantee we're never actively sorting a buffer still in use for rendering
    var orderBufferPrime: MetalBuffer<IndexType>

    // Sorting via Accelerate
    // While not sorting, we guarantee that orderBufferTempSort remains valid: the count may not match splatCount, but for every i in 0..<orderBufferTempSort.count, orderBufferTempSort should contain exactly one element equal to i
    var orderBufferTempSort: MetalBuffer<UInt>
    // depthBufferTempSort is ordered by vertex index; so depthBufferTempSort[0] -> splatBuffer[0], *not* orderBufferTempSort[0]
    var depthBufferTempSort: MetalBuffer<Float>

    // Sorting on CPU
    // While not sorting, we guarantee that orderAndDepthTempSort remains valid: the count may not match splatCount, but the array should contain all indices.
    // So for every i in 0..<orderAndDepthTempSort.count, orderAndDepthTempSort should contain exactly one element with .index = i
    var orderAndDepthTempSort: [SplatIndexAndDepth] = []

    public init(device: MTLDevice,
                colorFormat: MTLPixelFormat,
                depthFormat: MTLPixelFormat,
                stencilFormat: MTLPixelFormat,
                sampleCount: Int,
                maxViewCount: Int,
                maxSimultaneousRenders: Int) throws {
        self.maxViewCount = min(maxViewCount, Constants.maxViewCount)
        self.maxSimultaneousRenders = maxSimultaneousRenders

        let dynamicUniformBuffersSize = UniformsArray.alignedSize * maxSimultaneousRenders
        self.dynamicUniformBuffers = device.makeBuffer(length: dynamicUniformBuffersSize,
                                                       options: .storageModeShared)!
        self.dynamicUniformBuffers.label = "Uniform Buffers"
        self.uniforms = UnsafeMutableRawPointer(dynamicUniformBuffers.contents()).bindMemory(to: UniformsArray.self, capacity: 1)

        self.splatBuffer = try MetalBuffer(device: device)
        self.orderBuffer = try MetalBuffer(device: device)
        self.orderBufferPrime = try MetalBuffer(device: device)
        self.orderBufferTempSort = try MetalBuffer(device: device)
        self.depthBufferTempSort = try MetalBuffer(device: device)

        do {
            pipelineState = try Self.buildRenderPipelineWithDevice(device: device,
                                                                   colorFormat: colorFormat,
                                                                   depthFormat: depthFormat,
                                                                   stencilFormat: stencilFormat,
                                                                   sampleCount: sampleCount,
                                                                   maxViewCount: self.maxViewCount)
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.lessEqual
        depthStateDescriptor.isDepthWriteEnabled = false
        self.depthState = device.makeDepthStencilState(descriptor:depthStateDescriptor)!
    }

    public func reset() {
        splatBuffer.count = 0
        orderBuffer.count = 0
        orderBufferPrime.count = 0
        orderBufferTempSort.count = 0
        depthBufferTempSort.count = 0
        orderAndDepthTempSort = []
    }

    public func readPLY(from url: URL) {
        SplatPLYSceneReader(url).read(to: self)
    }

    private class func buildRenderPipelineWithDevice(device: MTLDevice,
                                                     colorFormat: MTLPixelFormat,
                                                     depthFormat: MTLPixelFormat,
                                                     stencilFormat: MTLPixelFormat,
                                                     sampleCount: Int,
                                                     maxViewCount: Int) throws -> MTLRenderPipelineState {
        let library = try device.makeDefaultLibrary(bundle: Bundle.module)

        let vertexFunction = library.makeFunction(name: "splatVertexShader")
        let fragmentFunction = library.makeFunction(name: "splatFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction

        pipelineDescriptor.rasterSampleCount = sampleCount

        let colorAttachment = pipelineDescriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = colorFormat
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        if Constants.renderFrontToBack {
            colorAttachment.sourceRGBBlendFactor = .oneMinusDestinationAlpha
            colorAttachment.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
            colorAttachment.destinationRGBBlendFactor = .one
            colorAttachment.destinationAlphaBlendFactor = .one
        } else {
            colorAttachment.sourceRGBBlendFactor = .one
            colorAttachment.sourceAlphaBlendFactor = .one
            colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        pipelineDescriptor.colorAttachments[0] = colorAttachment

        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat
        pipelineDescriptor.stencilAttachmentPixelFormat = stencilFormat

        pipelineDescriptor.maxVertexAmplificationCount = maxViewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    public func ensureAdditionalCapacity(_ pointCount: Int) throws {
        try splatBuffer.ensureCapacity(splatBuffer.count + pointCount)
    }

    public func add(_ point: SplatScenePoint) throws {
        do {
            try ensureAdditionalCapacity(1)
        } catch {
            Self.log.error("Failed to grow buffers: \(error)")
            return
        }

        let scale = SIMD3<Float>(exp(point.scale.x),
                                 exp(point.scale.y),
                                 exp(point.scale.z))
        let rotation = point.rotation.normalized
        let SH_C0: Float = 0.28209479177387814
        let color = SIMD3<Float>(x: max(0, min(1, 0.5 + SH_C0 * point.color.x)),
                                 y: max(0, min(1, 0.5 + SH_C0 * point.color.y)),
                                 z: max(0, min(1, 0.5 + SH_C0 * point.color.z)))
        let opacity = 1 / (1 + exp(-point.opacity))
        let splat = Splat(position: point.position,
                          color: .init(x: color.x, y: color.y, z: color.z, w: opacity),
                          scale: scale,
                          rotation: rotation)

        splatBuffer.append([ splat ])
    }

    public func willRender(viewportCameras: [CameraMatrices]) {}

    private func switchToNextDynamicBuffer() {
        uniformBufferIndex = (uniformBufferIndex + 1) % maxSimultaneousRenders
        uniformBufferOffset = UniformsArray.alignedSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffers.contents() + uniformBufferOffset).bindMemory(to: UniformsArray.self, capacity: 1)
    }

    private func updateUniforms(forViewportCameras viewportCameras: [CameraMatrices]) {
        for (i, viewportCamera) in viewportCameras.enumerated() where i <= maxViewCount {
            let screenWidth = Constants.screenWidth
            let screenHeight = UInt32(round(Float(screenWidth) * viewportCamera.projection[0][0] / viewportCamera.projection[1][1]))
            let screenSize = SIMD2<UInt32>(x: screenWidth, y: screenHeight)
            let uniforms = Uniforms(projectionMatrix: viewportCamera.projection, viewMatrix: viewportCamera.view, screenSize: screenSize)
            self.uniforms.pointee.setUniforms(index: i, uniforms)
        }

        cameraWorldPosition = viewportCameras.map { Self.cameraWorldPosition(forViewMatrix: $0.view) }.mean ?? .zero
        cameraWorldForward = viewportCameras.map { Self.cameraWorldForward(forViewMatrix: $0.view) }.mean?.normalized ?? .init(x: 0, y: 0, z: -1)

        if !sorting {
            resortIndices()
        }
    }

    private static func cameraWorldForward(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: -1, w: 0)).xyz
    }

    private static func cameraWorldPosition(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: 0, w: 1)).xyz
    }

    public func render(viewportCameras: [CameraMatrices], to renderEncoder: MTLRenderCommandEncoder) {
        guard splatBuffer.count != 0 else { return }

        switchToNextDynamicBuffer()
        updateUniforms(forViewportCameras: viewportCameras)

        renderEncoder.pushDebugGroup("Draw Splat Model")

        renderEncoder.setRenderPipelineState(pipelineState)

        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffers, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(splatBuffer.buffer, offset: 0, index: BufferIndex.splat.rawValue)
        renderEncoder.setVertexBuffer(orderBuffer.buffer, offset: 0, index: BufferIndex.order.rawValue)

        renderEncoder.drawPrimitives(type: .triangleStrip,
                                     vertexStart: 0,
                                     vertexCount: 4,
                                     instanceCount: splatBuffer.count)

        renderEncoder.popDebugGroup()
    }

    // Set indicesPrime to a depth-sorted version of indices, then swap indices and indicesPrime
    public func resortIndices() {
        if Constants.useAccelerateForSort {
            resortIndicesViaAccelerate()
        } else {
            resortIndicesOnCPU()
        }
    }

    public func resortIndicesOnCPU() {
        guard !sorting else { return }
        sorting = true

        let splatCount = splatBuffer.count

        if orderAndDepthTempSort.count != splatCount {
            orderAndDepthTempSort = Array(repeating: SplatIndexAndDepth(index: .max, depth: 0), count: splatCount)
            for i in 0..<splatCount {
                orderAndDepthTempSort[i].index = UInt32(i)
            }
        }

        let cameraWorldForward = cameraWorldForward
        let cameraWorldPosition = cameraWorldPosition

        let t0 = Date()
        Task(priority: .high) {
            defer {
                sorting = false
            }

            // We maintain the old order in indicesAndDepthTempSort in order to provide the opportunity to optimize the sort performance
            for i in 0..<splatCount {
                let index = orderAndDepthTempSort[i].index
                let splatPosition = splatBuffer.values[Int(index)].position
                if Constants.sortByDistance {
                    orderAndDepthTempSort[i].depth = (splatPosition - cameraWorldPosition).lengthSquared
                } else {
                    orderAndDepthTempSort[i].depth = dot(splatPosition, cameraWorldForward)
                }
            }

            let t1 = Date()
            if Constants.renderFrontToBack {
                orderAndDepthTempSort.sort { $0.depth < $1.depth }
            } else {
                orderAndDepthTempSort.sort { $0.depth > $1.depth }
            }
            let t2 = Date()

            do {
                orderBufferPrime.count = 0
                try orderBufferPrime.ensureCapacity(splatCount)
                for i in 0..<splatCount {
                    orderBufferPrime.append(orderAndDepthTempSort[i].index)
                }
                let t3 = Date()
                Self.log.info("Sorted \(self.orderAndDepthTempSort.count) elements via Array.sort in \(t3.timeIntervalSince(t0)) seconds (\(t2.timeIntervalSince(t1)) in sort itself)")
                
                swap(&orderBuffer, &orderBufferPrime)
            } catch {
                // TODO: report error
            }
        }
    }
    
    public func resortIndicesViaAccelerate() {
        guard !sorting else { return }
        sorting = true

        let splatCount = splatBuffer.count

        if orderBufferTempSort.count != splatCount {
            do {
                try orderBufferTempSort.ensureCapacity(splatCount)
                orderBufferTempSort.count = splatCount
                try depthBufferTempSort.ensureCapacity(splatCount)
                depthBufferTempSort.count = splatCount

                for i in 0..<splatCount {
                    orderBufferTempSort.values[i] = UInt(i)
                }
            } catch {
                // TODO: report error
                sorting = false
                return
            }
        }

        let cameraWorldForward = cameraWorldForward
        let cameraWorldPosition = cameraWorldPosition

        let t0 = Date()
        Task(priority: .high) {
            defer {
                sorting = false
            }

            // TODO: use Accelerate to calculate the depth
            // We maintain the old order in indicesTempSort in order to provide the opportunity to optimize the sort performance
            for index in 0..<splatCount {
                let splatPosition = splatBuffer.values[Int(index)].position
                if Constants.sortByDistance {
                    depthBufferTempSort.values[index] = (splatPosition - cameraWorldPosition).lengthSquared
                } else {
                    depthBufferTempSort.values[index] = dot(splatPosition, cameraWorldForward)
                }
            }

            let t1 = Date()
            vDSP_vsorti(depthBufferTempSort.values,
                        orderBufferTempSort.values,
                        nil,
                        vDSP_Length(splatCount),
                        Constants.renderFrontToBack ? 1 : -1)
            let t2 = Date()

            do {
                orderBufferPrime.count = 0
                try orderBufferPrime.ensureCapacity(splatCount)
                for i in 0..<splatCount {
                    orderBufferPrime.append(UInt32(orderBufferTempSort.values[i]))
                }
                let t3 = Date()
                Self.log.info("Sorted via Accelerate.vDSP_vsorti in \(t3.timeIntervalSince(t0)) seconds (\(t2.timeIntervalSince(t1)) in sort itself)")

                swap(&orderBuffer, &orderBufferPrime)
            } catch {
                // TODO: report error
            }
        }
    }}

extension SplatRenderer: SplatSceneReaderDelegate {
    public func didStartReading(withPointCount pointCount: UInt32) {
        Self.log.info("Will read \(pointCount) points")
        try? ensureAdditionalCapacity(Int(pointCount))
    }

    public func didRead(points: [SplatIO.SplatScenePoint]) {
        for point in points {
            try? add(point)
        }
    }

    public func didFinishReading() {
        Self.log.info("Finished reading points")
    }

    public func didFailReading(withError error: Error?) {
        Self.log.error("Failed to read points: \(error)")
    }
}

protocol MTLIndexTypeProvider {
    static var asMTLIndexType: MTLIndexType { get }
}

extension UInt32: MTLIndexTypeProvider {
    static var asMTLIndexType: MTLIndexType { .uint32 }
}
extension UInt16: MTLIndexTypeProvider {
    static var asMTLIndexType: MTLIndexType { .uint16 }
}

extension Array where Element == SIMD3<Float> {
    var mean: SIMD3<Float>? {
        guard !isEmpty else { return nil }
        return reduce(.zero, +) / Float(count)
    }
}

private extension SIMD3 where Scalar: BinaryFloatingPoint, Scalar.RawSignificand: FixedWidthInteger {
    var normalized: SIMD3<Scalar> {
        self / Scalar(sqrt(lengthSquared))
    }

    var lengthSquared: Scalar {
        x*x + y*y + z*z
    }

    func vector4(w: Scalar) -> SIMD4<Scalar> {
        SIMD4<Scalar>(x: x, y: y, z: z, w: w)
    }

    static func random(in range: Range<Scalar>) -> SIMD3<Scalar> {
        Self(x: Scalar.random(in: range), y: .random(in: range), z: .random(in: range))
    }
}

private extension SIMD4 where Scalar: BinaryFloatingPoint {
    var xyz: SIMD3<Scalar> {
        .init(x: x, y: y, z: z)
    }
}
