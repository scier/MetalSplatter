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
        static let sortByDistance = true
        // TODO: compare the performance of useAccelerateForSort, both for small and large scenes
        static let useAccelerateForSort = false
        static let renderFrontToBack = true
    }

    private static let log =
        Logger(subsystem: Bundle.module.bundleIdentifier!,
               category: "SplatRenderer")

    public struct CameraDescriptor {
        public var projectionMatrix: simd_float4x4
        public var viewMatrix: simd_float4x4
        public var screenSize: SIMD2<Int>

        public init(projectionMatrix: simd_float4x4, viewMatrix: simd_float4x4, screenSize: SIMD2<Int>) {
            self.projectionMatrix = projectionMatrix
            self.viewMatrix = viewMatrix
            self.screenSize = screenSize
        }
    }

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

    public var onSortStart: (() -> Void)?
    public var onSortComplete: ((TimeInterval) -> Void)?

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

    public var splatCount: Int { splatBuffer.count }

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

    private var readFailure: Error?

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

    public func readPLY(from url: URL) throws {
        readFailure = nil
        SplatPLYSceneReader(url).read(to: self)
        if let readFailure {
            self.readFailure = nil
            throw readFailure
        }
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

        var color: SIMD3<Float>
        switch point.color {
        case let .sphericalHarmonic(r, g, b, _), let .firstOrderSphericalHarmonic(r, g, b):
            let SH_C0: Float = 0.28209479177387814
            color = SIMD3(x: max(0, min(1, 0.5 + SH_C0 * r)),
                          y: max(0, min(1, 0.5 + SH_C0 * g)),
                          z: max(0, min(1, 0.5 + SH_C0 * b)))
        case .linearFloat(let r, let g, let b):
            color = SIMD3(x: r / 255.0, y: g / 255.0, z: b / 255.0)
        case .linearUInt8(let r, let g, let b):
            color = SIMD3(x: Float(r) / 255.0, y: Float(g) / 255.0, z: Float(b) / 255.0)
        case .none:
            color = .zero
        }

        let opacity = 1 / (1 + exp(-point.opacity))

        let splat = Splat(position: point.position,
                          color: .init(color.sRGBToLinear, opacity),
                          scale: scale,
                          rotation: rotation)

        splatBuffer.append([ splat ])
    }

    public func willRender(viewportCameras: [CameraDescriptor]) {}

    private func switchToNextDynamicBuffer() {
        uniformBufferIndex = (uniformBufferIndex + 1) % maxSimultaneousRenders
        uniformBufferOffset = UniformsArray.alignedSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffers.contents() + uniformBufferOffset).bindMemory(to: UniformsArray.self, capacity: 1)
    }

    private func updateUniforms(forViewportCameras viewportCameras: [CameraDescriptor]) {
        for (i, viewportCamera) in viewportCameras.enumerated() where i <= maxViewCount {
            let uniforms = Uniforms(projectionMatrix: viewportCamera.projectionMatrix,
                                    viewMatrix: viewportCamera.viewMatrix,
                                    screenSize: SIMD2(x: UInt32(viewportCamera.screenSize.x), y: UInt32(viewportCamera.screenSize.y)))
            self.uniforms.pointee.setUniforms(index: i, uniforms)
        }

        cameraWorldPosition = viewportCameras.map { Self.cameraWorldPosition(forViewMatrix: $0.viewMatrix) }.mean ?? .zero
        cameraWorldForward = viewportCameras.map { Self.cameraWorldForward(forViewMatrix: $0.viewMatrix) }.mean?.normalized ?? .init(x: 0, y: 0, z: -1)

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

    public func render(viewportCameras: [CameraDescriptor], to renderEncoder: MTLRenderCommandEncoder) {
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
        onSortStart?()
        let sortStartTime = Date()

        let splatCount = splatBuffer.count

        if orderAndDepthTempSort.count != splatCount {
            orderAndDepthTempSort = Array(repeating: SplatIndexAndDepth(index: .max, depth: 0), count: splatCount)
            for i in 0..<splatCount {
                orderAndDepthTempSort[i].index = UInt32(i)
            }
        }

        let cameraWorldForward = cameraWorldForward
        let cameraWorldPosition = cameraWorldPosition

        Task(priority: .high) {
            defer {
                sorting = false
                onSortComplete?(-sortStartTime.timeIntervalSinceNow)
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

            if Constants.renderFrontToBack {
                orderAndDepthTempSort.sort { $0.depth < $1.depth }
            } else {
                orderAndDepthTempSort.sort { $0.depth > $1.depth }
            }

            do {
                orderBufferPrime.count = 0
                try orderBufferPrime.ensureCapacity(splatCount)
                for i in 0..<splatCount {
                    orderBufferPrime.append(orderAndDepthTempSort[i].index)
                }

                swap(&orderBuffer, &orderBufferPrime)
            } catch {
                // TODO: report error
            }
        }
    }
    
    public func resortIndicesViaAccelerate() {
        guard !sorting else { return }
        sorting = true
        onSortStart?()
        let sortStartTime = Date()

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

        Task(priority: .high) {
            defer {
                sorting = false
                onSortComplete?(-sortStartTime.timeIntervalSinceNow)
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

            vDSP_vsorti(depthBufferTempSort.values,
                        orderBufferTempSort.values,
                        nil,
                        vDSP_Length(splatCount),
                        Constants.renderFrontToBack ? 1 : -1)

            do {
                orderBufferPrime.count = 0
                try orderBufferPrime.ensureCapacity(splatCount)
                for i in 0..<splatCount {
                    orderBufferPrime.append(UInt32(orderBufferTempSort.values[i]))
                }

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
        readFailure = error
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

private extension SIMD3<Float> {
    var sRGBToLinear: SIMD3<Float> {
        SIMD3(x: pow(x, 2.2), y: pow(y, 2.2), z: pow(z, 2.2))
    }
}

private extension SIMD4 where Scalar: BinaryFloatingPoint {
    var xyz: SIMD3<Scalar> {
        .init(x: x, y: y, z: z)
    }
}
