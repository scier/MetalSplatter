import Foundation
import Metal
import MetalKit
import os
import SplatIO

#if arch(x86_64)
typealias Float16 = Float
#warning("x86_64 targets are unsupported by MetalSplatter and will fail at runtime. MetalSplatter builds on x86_64 only because Xcode builds Swift Packages as universal binaries and provides no way to override this. When Swift supports Float16 on x86_64, this may be revisited.")
#endif

public class SplatRenderer {
    enum Constants {
        // Keep in sync with Shaders.metal : maxViewCount
        static let maxViewCount = 2
        // Sort by euclidian distance squared from camera position (true), or along the "forward" vector (false)
        // TODO: compare the behaviour and performance of sortByDistance
        // notes: sortByDistance introduces unstable artifacts when you get close to an object; whereas !sortByDistance introduces artifacts are you turn -- but they're a little subtler maybe?
        static let sortByDistance = true
        // Only store indices for 1024 splats; for the remainder, use instancing of these existing indices.
        // Setting to 1 uses only instancing (with a significant performance penalty); setting to a number higher than the splat count
        // uses only indexing (with a significant memory penalty for th elarge index array, and a small performance penalty
        // because that can't be cached as easiliy). Anywhere within an order of magnitude (or more?) of 1k seems to be the sweet spot,
        // with effectively no memory penalty compated to instancing, and slightly better performance than even using all indexing.
        static let maxIndexedSplatCount = 1024
    }

    private static let log =
        Logger(subsystem: Bundle.module.bundleIdentifier!,
               category: "SplatRenderer")

    public struct ViewportDescriptor {
        public var viewport: MTLViewport
        public var projectionMatrix: simd_float4x4
        public var viewMatrix: simd_float4x4
        public var screenSize: SIMD2<Int>

        public init(viewport: MTLViewport, projectionMatrix: simd_float4x4, viewMatrix: simd_float4x4, screenSize: SIMD2<Int>) {
            self.viewport = viewport
            self.projectionMatrix = projectionMatrix
            self.viewMatrix = viewMatrix
            self.screenSize = screenSize
        }
    }

    // Keep in sync with Shaders.metal : PreprocessBufferIndex
    enum PreprocessBufferIndex: NSInteger {
        case uniforms = 0
        case splat    = 1
        case preprocessedSplat = 2
    }

    // Keep in sync with Shaders.metal : VertexBufferIndex
    enum VertexBufferIndex: NSInteger {
        case uniforms = 0
        case splat    = 1
        case preprocessedSplat = 2
    }

    // Keep in sync with Shaders.metal : Uniforms
    struct Uniforms {
        var projectionMatrix: matrix_float4x4
        var viewMatrix: matrix_float4x4
        var screenSize: SIMD2<UInt32> // Size of screen in pixels
        var splatCount: UInt32
        var indexedSplatCount: UInt32
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

    struct PackedHalf3 {
        var x: Float16
        var y: Float16
        var z: Float16
    }

    struct PackedRGBHalf4 {
        var r: Float16
        var g: Float16
        var b: Float16
        var a: Float16
    }

    // Keep in sync with Shaders.metal : Splat
    struct Splat {
        var position: MTLPackedFloat3
        var color: PackedRGBHalf4
        var covA: PackedHalf3
        var covB: PackedHalf3
    }

    // Keep in sync with Shaders.metal : PreprocessedSplat
    struct PreprocessedSplat {
        var projectedPosition: SIMD4<Float16>
        var scaledAxis1: SIMD2<Float16>
        var scaledAxis2: SIMD2<Float16>
        var color: SIMD4<Float16>
    }

    struct SplatIndexAndDepth {
        var index: UInt32
        var depth: Float
    }

    public let device: MTLDevice
    public let colorFormat: MTLPixelFormat
    public let depthFormat: MTLPixelFormat
    public let stencilFormat: MTLPixelFormat
    public let sampleCount: Int
    public let maxViewCount: Int
    public let maxSimultaneousRenders: Int

    public var storeDepth: Bool = false {
        didSet {
            if storeDepth != oldValue {
                resetPipelines()
            }
        }
    }

    public var renderFrontToBack: Bool = false {
        didSet {
            if renderFrontToBack != oldValue {
                resetPipelines()
            }
        }
    }

    public var clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)

    public var onSortStart: (() -> Void)?
    public var onSortComplete: ((TimeInterval) -> Void)?

    private let library: MTLLibrary
    private var preprocessPipelineState: MTLComputePipelineState?
    private var renderPipelineState: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?

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
    // splatBufferPrime is a copy of splatBuffer, which is not currenly in use for rendering.
    // We use this for sorting, and when we're done, swap it with splatBuffer.
    // There's a good chance that we'll sometimes end up sorting a splatBuffer still in use for
    // rendering.
    // TODO: Replace this with a more robust multiple-buffer scheme to guarantee we're never actively sorting a buffer still in use for rendering
    var splatBufferPrime: MetalBuffer<Splat>
    // preprocessedSplatBuffer contains one entry for each gaussian splat per viewport
    var preprocessedSplatBuffer: MetalBuffer<PreprocessedSplat>

    var indexBuffer: MetalBuffer<UInt32>

    public var splatCount: Int { splatBuffer.count }

    var sorting = false
    var orderAndDepthTempSort: [SplatIndexAndDepth] = []

    public init(device: MTLDevice,
                colorFormat: MTLPixelFormat,
                depthFormat: MTLPixelFormat,
                stencilFormat: MTLPixelFormat,
                sampleCount: Int,
                maxViewCount: Int,
                maxSimultaneousRenders: Int) throws {
#if arch(x86_64)
        fatalError("MetalSplatter is unsupported on Intel architecture (x86_64)")
#endif

        self.device = device

        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.stencilFormat = stencilFormat
        self.sampleCount = sampleCount
        self.maxViewCount = min(maxViewCount, Constants.maxViewCount)
        self.maxSimultaneousRenders = maxSimultaneousRenders

        let dynamicUniformBuffersSize = UniformsArray.alignedSize * maxSimultaneousRenders
        self.dynamicUniformBuffers = device.makeBuffer(length: dynamicUniformBuffersSize,
                                                       options: .storageModeShared)!
        self.dynamicUniformBuffers.label = "Uniform Buffers"
        self.uniforms = UnsafeMutableRawPointer(dynamicUniformBuffers.contents()).bindMemory(to: UniformsArray.self, capacity: 1)

        self.splatBuffer = try MetalBuffer(device: device)
        self.splatBufferPrime = try MetalBuffer(device: device)
        self.preprocessedSplatBuffer = try MetalBuffer(device: device)
        self.indexBuffer = try MetalBuffer(device: device)

        do {
            library = try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            fatalError("Unable to initialize SplatRenderer: \(error)")
        }
    }

    public func reset() {
        splatBuffer.count = 0
        try? splatBuffer.setCapacity(0)
        preprocessedSplatBuffer.count = 0
        try? preprocessedSplatBuffer.setCapacity(0)
    }

    public func read(from url: URL) async throws {
        var newPoints = SplatMemoryBuffer()
        try await newPoints.read(from: try AutodetectSceneReader(url))
        try add(newPoints.points)
    }

    private func resetPipelines() {
        preprocessPipelineState = nil
        renderPipelineState = nil
        depthState = nil
    }

    private func buildPipelinesIfNeeded() throws {
        if preprocessPipelineState == nil {
            preprocessPipelineState = try buildPreprocessPipeline()
        }
        if renderPipelineState == nil {
            renderPipelineState = try buildRenderPipeline()
        }
        if depthState == nil {
            depthState = try buildDepthState()
        }
    }

    private func buildPreprocessPipeline() throws -> MTLComputePipelineState {
        try device.makeComputePipelineState(function: library.makeRequiredFunction(name: "splatPreprocessShader"))
    }

    private func buildRenderPipeline() throws -> MTLRenderPipelineState {
        let pipelineDescriptor = MTLRenderPipelineDescriptor()

        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = library.makeRequiredFunction(name: "splatVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeRequiredFunction(name: "splatFragmentShader")

        pipelineDescriptor.rasterSampleCount = sampleCount

        let colorAttachment = pipelineDescriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = colorFormat
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        if renderFrontToBack {
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

    private func buildDepthState() throws -> MTLDepthStencilState {
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptor.isDepthWriteEnabled = storeDepth
        return device.makeDepthStencilState(descriptor: depthStateDescriptor)!
    }

    public func ensureAdditionalCapacity(_ pointCount: Int) throws {
        try splatBuffer.ensureCapacity(splatBuffer.count + pointCount)
    }

    public func add(_ points: [SplatScenePoint]) throws {
        do {
            try ensureAdditionalCapacity(points.count)
        } catch {
            Self.log.error("Failed to grow buffers: \(error)")
            return
        }

        splatBuffer.append(points.map { Splat($0) })
    }

    public func add(_ point: SplatScenePoint) throws {
        try add([ point ])
    }

    private func switchToNextDynamicBuffer() {
        uniformBufferIndex = (uniformBufferIndex + 1) % maxSimultaneousRenders
        uniformBufferOffset = UniformsArray.alignedSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffers.contents() + uniformBufferOffset).bindMemory(to: UniformsArray.self, capacity: 1)
    }

    private func updateUniforms(forViewports viewports: [ViewportDescriptor],
                                splatCount: UInt32,
                                indexedSplatCount: UInt32) {
        for (i, viewport) in viewports.enumerated() where i <= maxViewCount {
            let uniforms = Uniforms(projectionMatrix: viewport.projectionMatrix,
                                    viewMatrix: viewport.viewMatrix,
                                    screenSize: SIMD2(x: UInt32(viewport.screenSize.x), y: UInt32(viewport.screenSize.y)),
                                    splatCount: splatCount,
                                    indexedSplatCount: indexedSplatCount)
            self.uniforms.pointee.setUniforms(index: i, uniforms)
        }

        cameraWorldPosition = viewports.map { Self.cameraWorldPosition(forViewMatrix: $0.viewMatrix) }.mean ?? .zero
        cameraWorldForward = viewports.map { Self.cameraWorldForward(forViewMatrix: $0.viewMatrix) }.mean?.normalized ?? .init(x: 0, y: 0, z: -1)

        if !sorting {
            resort()
        }
    }

    private static func cameraWorldForward(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: -1, w: 0)).xyz
    }

    private static func cameraWorldPosition(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: 0, w: 1)).xyz
    }

    func renderEncoder(viewports: [ViewportDescriptor],
                       colorTexture: MTLTexture,
                       colorStoreAction: MTLStoreAction,
                       depthTexture: MTLTexture?,
                       stencilTexture: MTLTexture?,
                       rasterizationRateMap: MTLRasterizationRateMap?,
                       renderTargetArrayLength: Int,
                       for commandBuffer: MTLCommandBuffer) -> MTLRenderCommandEncoder {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = colorTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = colorStoreAction
        renderPassDescriptor.colorAttachments[0].clearColor = clearColor
        if let depthTexture {
            renderPassDescriptor.depthAttachment.texture = depthTexture
            renderPassDescriptor.depthAttachment.loadAction = .clear
            renderPassDescriptor.depthAttachment.storeAction = storeDepth ? .store : .dontCare
            renderPassDescriptor.depthAttachment.clearDepth = 0.0
        }
        if let stencilTexture {
            renderPassDescriptor.stencilAttachment.texture = stencilTexture
            renderPassDescriptor.stencilAttachment.loadAction = .clear
            renderPassDescriptor.stencilAttachment.storeAction = .dontCare
            renderPassDescriptor.stencilAttachment.clearStencil = 0
        }
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        renderPassDescriptor.renderTargetArrayLength = renderTargetArrayLength

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }

        renderEncoder.label = "Primary Render Encoder"

        renderEncoder.setViewports(viewports.map(\.viewport))

        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        return renderEncoder
    }

    public func render(viewports: [ViewportDescriptor],
                       colorTexture: MTLTexture,
                       colorStoreAction: MTLStoreAction,
                       depthTexture: MTLTexture?,
                       stencilTexture: MTLTexture?,
                       rasterizationRateMap: MTLRasterizationRateMap?,
                       renderTargetArrayLength: Int,
                       to commandBuffer: MTLCommandBuffer) {
        let splatCount = splatBuffer.count
        guard splatBuffer.count != 0 else { return }
        let indexedSplatCount = min(splatCount, Constants.maxIndexedSplatCount)
        let instanceCount = (splatCount + indexedSplatCount - 1) / indexedSplatCount

        switchToNextDynamicBuffer()
        updateUniforms(forViewports: viewports, splatCount: UInt32(splatCount), indexedSplatCount: UInt32(indexedSplatCount))

        try? buildPipelinesIfNeeded()
        guard let preprocessPipelineState, let renderPipelineState, let depthState else { return }

        let preprocessedSplatCount = splatCount * viewports.count
        do {
            try preprocessedSplatBuffer.setCapacity(preprocessedSplatCount)
        } catch {
            return
        }

        let preprocessEncoder = commandBuffer.makeComputeCommandEncoder()!
        preprocessEncoder.setComputePipelineState(preprocessPipelineState)
        preprocessEncoder.setBuffer(dynamicUniformBuffers, offset: uniformBufferOffset, index: PreprocessBufferIndex.uniforms.rawValue)
        preprocessEncoder.setBuffer(splatBuffer.buffer, offset: 0, index: PreprocessBufferIndex.splat.rawValue)
        preprocessEncoder.setBuffer(preprocessedSplatBuffer.buffer, offset: 0, index: PreprocessBufferIndex.preprocessedSplat.rawValue)
        if device.supportsFamily(.common3) {
            preprocessEncoder.dispatchThreads(MTLSize(width: splatCount, height: viewports.count, depth: 1),
                                              threadsPerThreadgroup: MTLSize(width: preprocessPipelineState.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        } else {
            preprocessEncoder.dispatchThreadgroups(MTLSize(width: splatCount, height: viewports.count, depth: 1),
                                                   threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }
        preprocessEncoder.endEncoding()

        let renderEncoder = renderEncoder(viewports: viewports,
                                          colorTexture: colorTexture,
                                          colorStoreAction: colorStoreAction,
                                          depthTexture: depthTexture,
                                          stencilTexture: stencilTexture,
                                          rasterizationRateMap: rasterizationRateMap,
                                          renderTargetArrayLength: renderTargetArrayLength,
                                          for: commandBuffer)

        let indexCount = indexedSplatCount * 6
        if indexBuffer.count < indexCount {
            do {
                try indexBuffer.ensureCapacity(indexCount)
            } catch {
                return
            }
            indexBuffer.count = indexCount
            for i in 0..<indexedSplatCount {
                indexBuffer.values[i * 6 + 0] = UInt32(i * 4 + 0)
                indexBuffer.values[i * 6 + 1] = UInt32(i * 4 + 1)
                indexBuffer.values[i * 6 + 2] = UInt32(i * 4 + 2)
                indexBuffer.values[i * 6 + 3] = UInt32(i * 4 + 1)
                indexBuffer.values[i * 6 + 4] = UInt32(i * 4 + 2)
                indexBuffer.values[i * 6 + 5] = UInt32(i * 4 + 3)
            }
        }

        renderEncoder.pushDebugGroup("Draw Splat Model")

        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffers, offset: uniformBufferOffset, index: VertexBufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(preprocessedSplatBuffer.buffer, offset: 0, index: VertexBufferIndex.preprocessedSplat.rawValue)

        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: indexCount,
                                            indexType: .uint32,
                                            indexBuffer: indexBuffer.buffer,
                                            indexBufferOffset: 0,
                                            instanceCount: instanceCount)

        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }

    // Sort splatBuffer (read-only), storing the results in splatBuffer (write-only) then swap splatBuffer and splatBufferPrime
    public func resort() {
        guard !sorting else { return }
        sorting = true
        onSortStart?()
        let sortStartTime = Date()

        let splatCount = splatBuffer.count

        let cameraWorldForward = cameraWorldForward
        let cameraWorldPosition = cameraWorldPosition

        Task(priority: .high) {
            defer {
                sorting = false
                onSortComplete?(-sortStartTime.timeIntervalSinceNow)
            }

            if orderAndDepthTempSort.count != splatCount {
                orderAndDepthTempSort = Array(repeating: SplatIndexAndDepth(index: .max, depth: 0), count: splatCount)
            }

            if Constants.sortByDistance {
                for i in 0..<splatCount {
                    orderAndDepthTempSort[i].index = UInt32(i)
                    let splatPosition = splatBuffer.values[i].position.simd
                    orderAndDepthTempSort[i].depth = (splatPosition - cameraWorldPosition).lengthSquared
                }
            } else {
                for i in 0..<splatCount {
                    orderAndDepthTempSort[i].index = UInt32(i)
                    let splatPosition = splatBuffer.values[i].position.simd
                    orderAndDepthTempSort[i].depth = dot(splatPosition, cameraWorldForward)
                }
            }

            if renderFrontToBack {
                orderAndDepthTempSort.sort { $0.depth < $1.depth }
            } else {
                orderAndDepthTempSort.sort { $0.depth > $1.depth }
            }

            do {
                try splatBufferPrime.setCapacity(splatCount)
                splatBufferPrime.count = 0
                for newIndex in 0..<orderAndDepthTempSort.count {
                    let oldIndex = Int(orderAndDepthTempSort[newIndex].index)
                    splatBufferPrime.append(splatBuffer, fromIndex: oldIndex)
                }

                swap(&splatBuffer, &splatBufferPrime)
            } catch {
                // TODO: report error
            }
        }
    }
}

extension SplatRenderer.Splat {
    init(_ splat: SplatScenePoint) {
        self.init(position: splat.position,
                  color: .init(splat.color.asLinearFloat.sRGBToLinear, splat.opacity.asLinearFloat),
                  scale: splat.scale.asLinearFloat,
                  rotation: splat.rotation.normalized)
    }

    init(position: SIMD3<Float>,
         color: SIMD4<Float>,
         scale: SIMD3<Float>,
         rotation: simd_quatf) {
        let transform = simd_float3x3(rotation) * simd_float3x3(diagonal: scale)
        let cov3D = transform * transform.transpose
        self.init(position: MTLPackedFloat3Make(position.x, position.y, position.z),
                  color: SplatRenderer.PackedRGBHalf4(r: Float16(color.x), g: Float16(color.y), b: Float16(color.z), a: Float16(color.w)),
                  covA: SplatRenderer.PackedHalf3(x: Float16(cov3D[0, 0]), y: Float16(cov3D[0, 1]), z: Float16(cov3D[0, 2])),
                  covB: SplatRenderer.PackedHalf3(x: Float16(cov3D[1, 1]), y: Float16(cov3D[1, 2]), z: Float16(cov3D[2, 2])))
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

private extension MTLPackedFloat3 {
    var simd: SIMD3<Float> {
        SIMD3(x: x, y: y, z: z)
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

private extension MTLLibrary {
    func makeRequiredFunction(name: String) -> MTLFunction {
        guard let result = makeFunction(name: name) else {
            fatalError("Unable to load required shader function: \"\(name)\"")
        }
        return result
    }
}
