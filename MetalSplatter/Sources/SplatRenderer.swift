import Foundation
import Metal
import MetalKit
import os
import SplatIO

#if arch(x86_64)
typealias Float16 = Float
#warning("x86_64 targets are unsupported by MetalSplatter and will fail at runtime. MetalSplatter builds on x86_64 only because Xcode builds Swift Packages as universal binaries and provides no way to override this. When Swift supports Float16 on x86_64, this may be revisited.")
#endif

public final class SplatRenderer: Sendable {
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

        static let tileSize = MTLSize(width: 32, height: 32, depth: 1)

        // When performing the splat locality sort, we need to use quantized positions, meaning we need to compute bounds.
        // It's fine if the bounds doesn't include all the splats, some will be clamped to the outside of the box so will
        // just get a less efficient locality sort. Let's set the bounds to mean +/- N * std.dev., where N is:
        static let boundsStdDeviationsForLocalitySort: Float = 2.5
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

    // Keep in sync with Shaders.metal : BufferIndex
    enum BufferIndex: NSInteger {
        case uniforms   = 0
        case splat      = 1
        case splatIndex = 2
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

    public typealias SplatIndexType = UInt32

    public let device: MTLDevice
    public let colorFormat: MTLPixelFormat
    public let depthFormat: MTLPixelFormat
    public let sampleCount: Int
    public let maxViewCount: Int
    public let maxSimultaneousRenders: Int

    /**
     High-quality depth takes longer, but results in a continuous, more-representative depth buffer result, which is useful for reducing artifacts during Vision Pro's frame reprojection.
     */
    public var highQualityDepth: Bool = true

    private var writeDepth: Bool {
        depthFormat != .invalid
    }

    /**
     The SplatRenderer has two shader pipelines.
     - The single stage has a vertex shader, and a fragment shader. It can produce depth (or not), but the depth it produces is the depth of the nearest splat, whether it's visible or now.
     - The multi-stage pipeline uses a set of shaders which communicate using imageblock tile memory: initialization (which clears the tile memory), draw splats (similar to the single-stage
     pipeline but the end result is tile memory, not color+depth), and a post-process stage which merely copies the tile memory (color and optionally depth) to the frame's buffers.
     This is neccessary so that the primary stage can do its own blending -- of both color and depth -- by reading the previous values and writing new ones, which isn't possible without tile
     memory. Color blending works the same as the hardcoded path, but depth blending uses color alpha and results in mostly-transparent splats contributing only slightly to the depth,
     resulting in a much more continuous and representative depth value, which is important for reprojection on Vision Pro.
     */
    private var useMultiStagePipeline: Bool {
#if targetEnvironment(simulator)
        false
#else
        writeDepth && highQualityDepth
#endif
    }

    public var clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)

    /// Called when a sort starts
    public var onSortStart: (@Sendable () -> Void)? {
        get { sorter.onSortStart }
        set { sorter.onSortStart = newValue }
    }
    /// Called when a sort completes. The TimeInterval is the duration of the sort.
    public var onSortComplete: (@Sendable (TimeInterval) -> Void)? {
        get { sorter.onSortComplete }
        set { sorter.onSortComplete = newValue }
    }

    private let library: MTLLibrary
    // Single-stage pipeline
    private var singleStagePipelineState: MTLRenderPipelineState?
    private var singleStageDepthState: MTLDepthStencilState?
    // Multi-stage pipeline
    private var initializePipelineState: MTLRenderPipelineState?
    private var drawSplatPipelineState: MTLRenderPipelineState?
    private var drawSplatDepthState: MTLDepthStencilState?
    private var postprocessPipelineState: MTLRenderPipelineState?
    private var postprocessDepthState: MTLDepthStencilState?

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

    // splatBuffer contains one entry for each gaussian splat
    var splatBuffer: MetalBuffer<Splat>

    let sorter: SplatSorter<SplatIndexType>

    var triangleVertexIndexBuffer: MetalBuffer<UInt32>

    public var splatCount: Int { splatBuffer.count }

    private var needsLocalitySort: Bool = false

    @MainActor
    public init(device: MTLDevice,
                colorFormat: MTLPixelFormat,
                depthFormat: MTLPixelFormat,
                sampleCount: Int,
                maxViewCount: Int,
                maxSimultaneousRenders: Int) throws {
#if arch(x86_64)
        fatalError("MetalSplatter is unsupported on Intel architecture (x86_64)")
#endif

        self.device = device

        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.sampleCount = sampleCount
        self.maxViewCount = min(maxViewCount, Constants.maxViewCount)
        self.maxSimultaneousRenders = maxSimultaneousRenders

        let dynamicUniformBuffersSize = UniformsArray.alignedSize * maxSimultaneousRenders
        self.dynamicUniformBuffers = device.makeBuffer(length: dynamicUniformBuffersSize,
                                                       options: .storageModeShared)!
        self.dynamicUniformBuffers.label = "Uniform Buffers"
        self.uniforms = UnsafeMutableRawPointer(dynamicUniformBuffers.contents()).bindMemory(to: UniformsArray.self, capacity: 1)

        self.splatBuffer = try MetalBuffer(device: device)
        self.triangleVertexIndexBuffer = try MetalBuffer(device: device)

        self.sorter = try SplatSorter(device: device)

        do {
            library = try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            fatalError("Unable to initialize SplatRenderer: \(error)")
        }
    }

    public func reset() {
        splatBuffer.count = 0
        try? splatBuffer.setCapacity(0)
        sorter.setSplatBuffer(nil)
    }

    public func read(from url: URL) async throws {
        var newPoints = SplatMemoryBuffer()
        try await newPoints.read(from: try AutodetectSceneReader(url))
        try add(newPoints.points)
    }

    private func resetPipelineStates() {
        singleStagePipelineState = nil
        initializePipelineState = nil
        drawSplatPipelineState = nil
        drawSplatDepthState = nil
        postprocessPipelineState = nil
        postprocessDepthState = nil
    }

    private func buildSingleStagePipelineStatesIfNeeded() throws {
        guard singleStagePipelineState == nil else { return }

        singleStagePipelineState = try buildSingleStagePipelineState()
        singleStageDepthState = try buildSingleStageDepthState()
    }

    private func buildMultiStagePipelineStatesIfNeeded() throws {
        guard initializePipelineState == nil else { return }

        initializePipelineState = try buildInitializePipelineState()
        drawSplatPipelineState = try buildDrawSplatPipelineState()
        drawSplatDepthState = try buildDrawSplatDepthState()
        postprocessPipelineState = try buildPostprocessPipelineState()
        postprocessDepthState = try buildPostprocessDepthState()
    }

    private func buildSingleStagePipelineState() throws -> MTLRenderPipelineState {
        assert(!useMultiStagePipeline)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()

        pipelineDescriptor.label = "SingleStagePipeline"
        pipelineDescriptor.vertexFunction = library.makeRequiredFunction(name: "singleStageSplatVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeRequiredFunction(name: "singleStageSplatFragmentShader")

        pipelineDescriptor.rasterSampleCount = sampleCount

        let colorAttachment = pipelineDescriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = colorFormat
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        colorAttachment.sourceRGBBlendFactor = .one
        colorAttachment.sourceAlphaBlendFactor = .one
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0] = colorAttachment

        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = maxViewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private func buildSingleStageDepthState() throws -> MTLDepthStencilState {
        assert(!useMultiStagePipeline)

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptor.isDepthWriteEnabled = writeDepth
        return device.makeDepthStencilState(descriptor: depthStateDescriptor)!
    }

    private func buildInitializePipelineState() throws -> MTLRenderPipelineState {
        assert(useMultiStagePipeline)

        let pipelineDescriptor = MTLTileRenderPipelineDescriptor()

        pipelineDescriptor.label = "InitializePipeline"
        pipelineDescriptor.tileFunction = library.makeRequiredFunction(name: "initializeFragmentStore")
        pipelineDescriptor.threadgroupSizeMatchesTileSize = true;
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat

        return try device.makeRenderPipelineState(tileDescriptor: pipelineDescriptor, options: [], reflection: nil)
    }

    private func buildDrawSplatPipelineState() throws -> MTLRenderPipelineState {
        assert(useMultiStagePipeline)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()

        pipelineDescriptor.label = "DrawSplatPipeline"
        pipelineDescriptor.vertexFunction = library.makeRequiredFunction(name: "multiStageSplatVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeRequiredFunction(name: "multiStageSplatFragmentShader")

        pipelineDescriptor.rasterSampleCount = sampleCount

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = maxViewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private func buildDrawSplatDepthState() throws -> MTLDepthStencilState {
        assert(useMultiStagePipeline)

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptor.isDepthWriteEnabled = writeDepth
        return device.makeDepthStencilState(descriptor: depthStateDescriptor)!
    }

    private func buildPostprocessPipelineState() throws -> MTLRenderPipelineState {
        assert(useMultiStagePipeline)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()

        pipelineDescriptor.label = "PostprocessPipeline"
        pipelineDescriptor.vertexFunction =
            library.makeRequiredFunction(name: "postprocessVertexShader")
        pipelineDescriptor.fragmentFunction =
            writeDepth
            ? library.makeRequiredFunction(name: "postprocessFragmentShader")
            : library.makeRequiredFunction(name: "postprocessFragmentShaderNoDepth")

        pipelineDescriptor.colorAttachments[0]!.pixelFormat = colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = maxViewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private func buildPostprocessDepthState() throws -> MTLDepthStencilState {
        assert(useMultiStagePipeline)

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptor.isDepthWriteEnabled = writeDepth
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
        needsLocalitySort = true

        sorter.setSplatBuffer(splatBuffer)
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
    }

    private static func cameraWorldForward(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: -1, w: 0)).xyz
    }

    private static func cameraWorldPosition(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: 0, w: 1)).xyz
    }

    func renderEncoder(multiStage: Bool,
                       viewports: [ViewportDescriptor],
                       colorTexture: MTLTexture,
                       colorStoreAction: MTLStoreAction,
                       depthTexture: MTLTexture?,
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
            renderPassDescriptor.depthAttachment.storeAction = .store
            renderPassDescriptor.depthAttachment.clearDepth = 0.0
        }
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        renderPassDescriptor.renderTargetArrayLength = renderTargetArrayLength

        renderPassDescriptor.tileWidth  = Constants.tileSize.width
        renderPassDescriptor.tileHeight = Constants.tileSize.height

        if multiStage {
            if let initializePipelineState {
                renderPassDescriptor.imageblockSampleLength = initializePipelineState.imageblockSampleLength
            } else {
                Self.log.error("initializePipeline == nil in renderEncoder()")
            }
        }

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

    /// Renders the gaussian splats to the given command buffer.
    ///
    /// - Parameters:
    ///   - viewports: The viewport descriptors for rendering (supports multiple viewports for stereo on visionOS)
    ///   - colorTexture: The texture to render color output to
    ///   - colorStoreAction: The store action for the color attachment
    ///   - depthTexture: Optional depth texture for depth output
    ///   - rasterizationRateMap: Optional rasterization rate map for variable rate shading
    ///   - renderTargetArrayLength: The render target array length (for layered rendering)
    ///   - sortTimeout: Maximum time to block the caller in order to wait for a valid sorted index buffer to be available. This does not cause the method to wait for the latest sort to complete, it only causes it to block if no sort at all has completed since the last time the sort was invalidated (e.g. if the splats butter was changed). Passing 0 disables blocking, but may result in a flash after a splat update instead of a dropped frame. Defaults to blocking 0.1s.
    ///   - commandBuffer: The command buffer to encode rendering commands into
    public func render(viewports: [ViewportDescriptor],
                       colorTexture: MTLTexture,
                       colorStoreAction: MTLStoreAction,
                       depthTexture: MTLTexture?,
                       rasterizationRateMap: MTLRasterizationRateMap?,
                       renderTargetArrayLength: Int,
                       sortTimeout: TimeInterval = 0.1,
                       to commandBuffer: MTLCommandBuffer) throws {
        if needsLocalitySort {
            sortSplatsByLocality()
            needsLocalitySort = false
        }

        // Update camera pose for sorting
        sorter.updateCameraPose(position: cameraWorldPosition, forward: cameraWorldForward)

        // Try to get sorted indices, optionally waiting up to sortTimeout
        var splatIndexBuffer = sorter.tryObtainSortedIndices()
        if splatIndexBuffer == nil && sortTimeout > 0 {
            let deadline = Date().addingTimeInterval(sortTimeout)
            while splatIndexBuffer == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
                splatIndexBuffer = sorter.tryObtainSortedIndices()
            }
        }
        guard let splatIndexBuffer else { return }
        defer { sorter.releaseSortedIndices(splatIndexBuffer) }

        let splatCount = splatIndexBuffer.count
        guard splatCount != 0 else { return }
        let indexedSplatCount = min(splatCount, Constants.maxIndexedSplatCount)
        let instanceCount = (splatCount + indexedSplatCount - 1) / indexedSplatCount

        switchToNextDynamicBuffer()
        updateUniforms(forViewports: viewports, splatCount: UInt32(splatCount), indexedSplatCount: UInt32(indexedSplatCount))

        let multiStage = useMultiStagePipeline
        if multiStage {
            try buildMultiStagePipelineStatesIfNeeded()
        } else {
            try buildSingleStagePipelineStatesIfNeeded()
        }

        let renderEncoder = renderEncoder(multiStage: multiStage,
                                          viewports: viewports,
                                          colorTexture: colorTexture,
                                          colorStoreAction: colorStoreAction,
                                          depthTexture: depthTexture,
                                          rasterizationRateMap: rasterizationRateMap,
                                          renderTargetArrayLength: renderTargetArrayLength,
                                          for: commandBuffer)

        let triangleVertexCount = indexedSplatCount * 6
        if triangleVertexIndexBuffer.count < triangleVertexCount {
            do {
                try triangleVertexIndexBuffer.ensureCapacity(triangleVertexCount)
            } catch {
                return
            }
            triangleVertexIndexBuffer.count = triangleVertexCount
            for i in 0..<indexedSplatCount {
                triangleVertexIndexBuffer.values[i * 6 + 0] = UInt32(i * 4 + 0)
                triangleVertexIndexBuffer.values[i * 6 + 1] = UInt32(i * 4 + 1)
                triangleVertexIndexBuffer.values[i * 6 + 2] = UInt32(i * 4 + 2)
                triangleVertexIndexBuffer.values[i * 6 + 3] = UInt32(i * 4 + 1)
                triangleVertexIndexBuffer.values[i * 6 + 4] = UInt32(i * 4 + 2)
                triangleVertexIndexBuffer.values[i * 6 + 5] = UInt32(i * 4 + 3)
            }
        }

        if multiStage {
            guard let initializePipelineState,
                  let drawSplatPipelineState
            else { return }

            renderEncoder.pushDebugGroup("Initialize")
            renderEncoder.setRenderPipelineState(initializePipelineState)
            renderEncoder.dispatchThreadsPerTile(Constants.tileSize)
            renderEncoder.popDebugGroup()

            renderEncoder.pushDebugGroup("Draw Splats")
            renderEncoder.setRenderPipelineState(drawSplatPipelineState)
            renderEncoder.setDepthStencilState(drawSplatDepthState)
        } else {
            guard let singleStagePipelineState
            else { return }

            renderEncoder.pushDebugGroup("Draw Splats")
            renderEncoder.setRenderPipelineState(singleStagePipelineState)
            renderEncoder.setDepthStencilState(singleStageDepthState)
        }

        renderEncoder.setVertexBuffer(dynamicUniformBuffers, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(splatBuffer.buffer, offset: 0, index: BufferIndex.splat.rawValue)
        renderEncoder.setVertexBuffer(splatIndexBuffer.buffer, offset: 0, index: BufferIndex.splatIndex.rawValue)

        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: triangleVertexCount,
                                            indexType: .uint32,
                                            indexBuffer: triangleVertexIndexBuffer.buffer,
                                            indexBufferOffset: 0,
                                            instanceCount: instanceCount)

        if multiStage {
            guard let postprocessPipelineState
            else { return }

            renderEncoder.popDebugGroup()

            renderEncoder.pushDebugGroup("Postprocess")
            renderEncoder.setRenderPipelineState(postprocessPipelineState)
            renderEncoder.setDepthStencilState(postprocessDepthState)
            renderEncoder.setCullMode(.none)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            renderEncoder.popDebugGroup()
        } else {
            renderEncoder.popDebugGroup()
        }

        renderEncoder.endEncoding()
    }

    // Define a bounding box which doesn't quite include all the splats, just most of them
    private func bounds(withinSigmaMultiple sigmaMultiple: Float) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var sum = SIMD3<Float>.zero
        var sumOfSquares = SIMD3<Float>.zero
        let count = Float(splatBuffer.count)
        for i in 0..<splatBuffer.count {
            let p = splatBuffer.values[i].position
            let position = SIMD3<Float>(p.x, p.y, p.z)
            sum += position
            sumOfSquares += position * position
        }
        let mean = sum / count
        let variance = sumOfSquares / count - mean * mean
        let sigma = SIMD3<Float>(x: sqrt(variance.x), y: sqrt(variance.y), z: sqrt(variance.z))

        let minBounds = mean - sigmaMultiple * sigma
        let maxBounds = mean + sigmaMultiple * sigma

        return (min: minBounds, max: maxBounds)
    }

    /// Sorts splatBuffer by their position's Morton code, in order to improve memory locality: adjacent splats in memory will tend to be nearby in space as well.
    /// This helps improve the tiling/cache performance of the vertex shader.
    private func sortSplatsByLocality() {
        guard splatBuffer.count > 3 else { return }

        let (minBounds, maxBounds) = bounds(withinSigmaMultiple: Constants.boundsStdDeviationsForLocalitySort)
        let boundsSize = maxBounds - minBounds
        guard boundsSize.x > 0 && boundsSize.y > 0 && boundsSize.z > 0 else {
            return
        }
        let invBoundsSize = 1/boundsSize

        // Quantize a value into a 10-bit unsigned integers
        func quantize(_ value: Float, _ minBounds: Float, _ invBoundsSize: Float) -> UInt32 {
            let normalizedValue = (value - minBounds) * invBoundsSize
            let clamped = max(min(normalizedValue, 1), 0)
            return UInt32(clamped * 1023.0)
        }
        // Quantize a splat position into 10-bit unsigned integers per axis
        func quantize(_ p: SIMD3<Float>) -> SIMD3<UInt32> {
            SIMD3<UInt32>(quantize(p.x, minBounds.x, invBoundsSize.x),
                          quantize(p.y, minBounds.y, invBoundsSize.y),
                          quantize(p.z, minBounds.z, invBoundsSize.z))
        }

        // Encode quantized coordinate into a single Morton code
        func morton3D(_ p: SIMD3<UInt32>) -> UInt32 {
            var result: UInt32 = 0
            for i in 0..<10 {
                result |= ((p.x >> i) & 1) << (3 * i + 0)
                result |= ((p.y >> i) & 1) << (3 * i + 1)
                result |= ((p.z >> i) & 1) << (3 * i + 2)
            }
            return result
        }

        // Create array of (index, morton code) pairs by directly accessing splatBuffer.values
        let indicesWithMortonCodes: [(Int, UInt32)] = (0..<splatBuffer.count).map { i in
            let position = splatBuffer.values[i].position
            let simdPosition = SIMD3<Float>(x: position.x, y: position.y, z: position.z)
            let morton = morton3D(quantize(simdPosition))
            return (i, morton)
        }

        // Sort indices by their Morton code
        let sorted = indicesWithMortonCodes.sorted { $0.1 < $1.1 }.map(\.0)

        // Reorder splatBuffer's values according to sorted indices
        splatBuffer.values.reorderInPlace(fromSourceIndices: sorted)

        // Invalidate sorted index buffers since splat positions have been reordered
        sorter.invalidateAllBuffers()
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

extension SIMD3 where Scalar: BinaryFloatingPoint, Scalar.RawSignificand: FixedWidthInteger {
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

extension UnsafeMutablePointer {
    /// Reorder elements so that `self[i] = originalSelf[sortedIndices[i]]`.
    mutating func reorderInPlace(fromSourceIndices sourceIndices: [Int]) {
        let count = sourceIndices.count
        var visited = [Bool](repeating: false, count: count)

        for i in 0..<count {
            guard !visited[i] else { continue }

            var current = i
            let temp = advanced(by: sourceIndices[current]).move()

            while true {
                visited[current] = true
                let next = sourceIndices[current]

                if visited[next] {
                    advanced(by: current).initialize(to: temp)
                    break
                } else {
                    advanced(by: current).moveUpdate(from: advanced(by: next), count: 1)
                    current = next
                }
            }
        }
    }
}
