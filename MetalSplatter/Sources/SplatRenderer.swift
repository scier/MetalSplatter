import Foundation
@preconcurrency import Metal
import MetalKit
import os
import SplatIO
import Synchronization

public final class SplatRenderer: @unchecked Sendable {
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

        // Chunk indices are UInt16 in ChunkedSplatIndex and ChunkTable.enabledChunkCount,
        // so the maximum number of simultaneously enabled chunks is UInt16.max.
        static let maxEnabledChunks = Int(UInt16.max)

        static let tileSize = MTLSize(width: 32, height: 32, depth: 1)
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
        case uniforms    = 0
        case chunkTable  = 1
        case splatIndex  = 2
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

    // Keep in sync with Shaders.metal : ChunkTable
    // Expected layout: pointer (8 bytes), enabledChunkCount (2 bytes), padding (6 bytes) = 16 bytes
    struct GPUChunkTableHeader {
        var chunksPointer: UInt64  // GPU address of ChunkInfo array
        var enabledChunkCount: UInt16
        var _padding: UInt16
        var _padding2: UInt32
    }

    // Keep in sync with Shaders.metal : ChunkInfo
    // Expected layout: pointer (8 bytes), splatCount (4 bytes), padding (4 bytes) = 16 bytes
    struct GPUChunkInfo {
        var splatsPointer: UInt64  // device pointer
        var splatCount: UInt32
        var _padding: UInt32
    }

    public let device: MTLDevice
    public let colorFormat: MTLPixelFormat
    public let depthFormat: MTLPixelFormat
    public let sampleCount: Int
    public let maxViewCount: Int
    public let maxSimultaneousRenders: Int

    /**
     High-quality depth takes longer, but results in a continuous, more-representative depth buffer result, which is useful for reducing artifacts during Vision Pro's frame reprojection.
     */
    public let highQualityDepth: Bool

    /**
     The color to clear the render target to before rendering splats.
     */
    public let clearColor: MTLClearColor

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

    // MARK: - Chunk Storage

    /// Internal storage for a chunk
    private struct ChunkEntry {
        let id: ChunkID
        var chunk: SplatChunk
        var isEnabled: Bool
    }

    private var chunks: [ChunkID: ChunkEntry] = [:]
    private var nextChunkID: UInt = 0

    /// Maps ChunkID to the contiguous chunk index used by the sorter and shaders.
    /// Updated when chunks are added, removed, or enabled/disabled.
    private var chunkIDToIndex: [ChunkID: UInt16] = [:]

    private let sorter: SplatSorter

    /// Uniform buffer storage - contains maxSimultaneousRenders uniform buffers that we round-robin through.
    private let dynamicUniformBuffers: MTLBuffer

    /// State accessed only during render() execution.
    /// Protected by serial render() enforcement via `isRendering` flag in AccessState.
    private struct RenderState {
        // Pipeline caches - lazily built, thread-safe for concurrent GPU use

        // Single-stage pipeline
        var singleStagePipelineState: MTLRenderPipelineState?
        var singleStageDepthState: MTLDepthStencilState?

        // Multi-stage pipeline
        var initializePipelineState: MTLRenderPipelineState?
        var drawSplatPipelineState: MTLRenderPipelineState?
        var drawSplatDepthState: MTLDepthStencilState?
        var postprocessPipelineState: MTLRenderPipelineState?
        var postprocessDepthState: MTLDepthStencilState?

        // Uniform buffer management - which slot in the ring buffer we're using
        var uniformBufferOffset: Int = 0
        var uniformBufferIndex: Int = 0
        var uniforms: UnsafeMutablePointer<UniformsArray>

        // Index buffer for triangle vertices (grown as needed)
        var triangleVertexIndexBuffer: MetalBuffer<UInt32>

        init(uniforms: UnsafeMutablePointer<UniformsArray>,
             triangleVertexIndexBuffer: MetalBuffer<UInt32>) {
            self.uniforms = uniforms
            self.triangleVertexIndexBuffer = triangleVertexIndexBuffer
        }
    }
    private var renderState: RenderState

    /// State for coordinating render access and chunk modifications.
    private struct AccessState: ~Copyable {
        /// Number of render operations currently in flight (submitted but not yet completed by GPU).
        var inFlightRenderCount: Int = 0
        /// When true, render() is currently executing (encoding commands). Ensures serial render execution.
        var isRendering: Bool = false
        /// When true, a caller has exclusive access for modifying chunks.
        var hasExclusiveAccess: Bool = false
        /// Queue of continuations waiting for exclusive access. First waiter gets access next.
        var exclusiveAccessWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let accessState: Mutex<AccessState>

    private enum BufferTag { case chunkTable }
    private let bufferPool = MTLBufferPool<BufferTag>()

    /// Returns true if exclusive access is currently held. Used for precondition checks.
    private var hasExclusiveAccess: Bool {
        accessState.withLock { $0.hasExclusiveAccess }
    }

    /// Total splat count across all enabled chunks
    public var splatCount: Int {
        chunks.values
            .filter { $0.isEnabled }
            .reduce(0) { $0 + $1.chunk.splatCount }
    }

    public init(device: MTLDevice,
                colorFormat: MTLPixelFormat,
                depthFormat: MTLPixelFormat,
                sampleCount: Int,
                maxViewCount: Int,
                maxSimultaneousRenders: Int,
                highQualityDepth: Bool = true,
                clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) throws {
#if arch(x86_64)
        fatalError("MetalSplatter is unsupported on Intel architecture (x86_64)")
#endif

        self.device = device

        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.sampleCount = sampleCount
        self.maxViewCount = min(maxViewCount, Constants.maxViewCount)
        self.maxSimultaneousRenders = maxSimultaneousRenders
        self.highQualityDepth = highQualityDepth
        self.clearColor = clearColor

        let dynamicUniformBuffersSize = UniformsArray.alignedSize * maxSimultaneousRenders
        self.dynamicUniformBuffers = device.makeBuffer(length: dynamicUniformBuffersSize,
                                                       options: .storageModeShared)!
        self.dynamicUniformBuffers.label = "Uniform Buffers"

        let uniformsPointer = UnsafeMutableRawPointer(dynamicUniformBuffers.contents())
            .bindMemory(to: UniformsArray.self, capacity: 1)
        let triangleVertexIndexBuffer = try MetalBuffer<UInt32>(device: device)
        self.renderState = RenderState(uniforms: uniformsPointer,
                                        triangleVertexIndexBuffer: triangleVertexIndexBuffer)

        self.sorter = try SplatSorter(device: device)

        self.accessState = Mutex(AccessState())

        do {
            library = try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            fatalError("Unable to initialize SplatRenderer: \(error)")
        }
    }

    // MARK: - Chunk Management

    /// Adds a chunk to the renderer. The chunk should not be modified after this method returns, except during withChunkAccess {...}.
    /// - Parameters:
    ///   - chunk: The chunk to add
    ///   - sortByLocality: If true (the default), reorders splats by Morton code to improve cache performance during rendering.
    ///     Set to false if you need to preserve the original splat ordering, or if you'd like to control performance by calling
    ///     SplatChunk.sortByLocality() yourself prior to to caling this method.
    /// - Returns: The assigned chunk ID
    @discardableResult
    public func addChunk(_ chunk: SplatChunk, sortByLocality: Bool = true) async -> ChunkID {
        if sortByLocality {
            chunk.sortByLocality()
        }

        return await withChunkAccess {
            let id = ChunkID(rawValue: nextChunkID)
            nextChunkID += 1

            chunks[id] = ChunkEntry(
                id: id,
                chunk: chunk,
                isEnabled: true
            )

            updateSorterChunks()
            return id
        }
    }

    /// Removes a chunk from the renderer.
    /// - Parameter id: The chunk ID to remove
    public func removeChunk(_ id: ChunkID) async {
        await withChunkAccess {
            chunks.removeValue(forKey: id)
            updateSorterChunks()
        }
    }

    /// Removes all chunks from the renderer.
    public func removeAllChunks() async {
        await withChunkAccess {
            chunks.removeAll()
            sorter.setChunks([])
        }
    }

    /// Enables or disables a chunk for rendering.
    /// - Parameters:
    ///   - id: The chunk ID
    ///   - enabled: Whether the chunk should be rendered
    public func setChunkEnabled(_ id: ChunkID, enabled: Bool) async {
        await withChunkAccess {
            chunks[id]?.isEnabled = enabled
            updateSorterChunks()
        }
    }

    /// Returns whether a chunk is enabled.
    /// - Parameter id: The chunk ID
    /// - Returns: true if the chunk is enabled, false otherwise
    public func isChunkEnabled(_ id: ChunkID) -> Bool {
        chunks[id]?.isEnabled ?? false
    }


    // MARK: - Private Chunk Helpers

    /// Provides exclusive access to modify chunks.
    ///
    /// This method ensures that no renders are in flight before executing the body,
    /// and prevents new renders from starting until the body completes.
    /// The calling task suspends (without blocking a thread) until exclusive access is available.
    /// Multiple concurrent callers are queued and granted access in order.
    private func withChunkAccess<T>(_ body: () throws -> T) async rethrows -> T {
        await withCheckedContinuation { continuation in
            let readyNow = accessState.withLock { state -> Bool in
                if !state.hasExclusiveAccess && state.inFlightRenderCount == 0 {
                    state.hasExclusiveAccess = true
                    return true
                }
                state.exclusiveAccessWaiters.append(continuation)
                return false
            }
            if readyNow {
                continuation.resume()
            }
        }

        defer {
            let nextWaiter = accessState.withLock { state -> CheckedContinuation<Void, Never>? in
                if !state.exclusiveAccessWaiters.isEmpty && state.inFlightRenderCount == 0 {
                    // Pass access directly to next waiter (hasExclusiveAccess stays true)
                    return state.exclusiveAccessWaiters.removeFirst()
                }
                state.hasExclusiveAccess = false
                return nil
            }
            nextWaiter?.resume()
        }

        return try body()
    }

    private func updateSorterChunks() {
        // Build the list of enabled chunks for the sorter
        // Assign contiguous chunk indices for this sort/render cycle
        var chunkReferences: [SplatSorter.ChunkReference] = []
        var newChunkIDToIndex: [ChunkID: UInt16] = [:]
        var index: UInt16 = 0

        for entry in chunks.values where entry.isEnabled {
            if Int(index) >= Constants.maxEnabledChunks {
                Self.log.warning("Maximum enabled chunk count (\(Constants.maxEnabledChunks)) exceeded; additional chunks will not be rendered")
                break
            }

            chunkReferences.append(SplatSorter.ChunkReference(
                chunkIndex: index,
                buffer: entry.chunk.splats
            ))
            newChunkIDToIndex[entry.id] = index
            index += 1
        }

        chunkIDToIndex = newChunkIDToIndex
        sorter.setChunks(chunkReferences)
    }

    /// Called when a render's command buffer completes on the GPU.
    private func renderCompleted() {
        let waiter = accessState.withLock { state -> CheckedContinuation<Void, Never>? in
            state.inFlightRenderCount -= 1
            if state.inFlightRenderCount == 0 && !state.hasExclusiveAccess && !state.exclusiveAccessWaiters.isEmpty {
                state.hasExclusiveAccess = true
                return state.exclusiveAccessWaiters.removeFirst()
            }
            return nil
        }
        waiter?.resume()
    }

    // MARK: - Pipeline State Building

    private func resetPipelineStates() {
        renderState.singleStagePipelineState = nil
        renderState.initializePipelineState = nil
        renderState.drawSplatPipelineState = nil
        renderState.drawSplatDepthState = nil
        renderState.postprocessPipelineState = nil
        renderState.postprocessDepthState = nil
    }

    private func buildSingleStagePipelineStatesIfNeeded() throws {
        guard renderState.singleStagePipelineState == nil else { return }

        renderState.singleStagePipelineState = try buildSingleStagePipelineState()
        renderState.singleStageDepthState = try buildSingleStageDepthState()
    }

    private func buildMultiStagePipelineStatesIfNeeded() throws {
        guard renderState.initializePipelineState == nil else { return }

        renderState.initializePipelineState = try buildInitializePipelineState()
        renderState.drawSplatPipelineState = try buildDrawSplatPipelineState()
        renderState.drawSplatDepthState = try buildDrawSplatDepthState()
        renderState.postprocessPipelineState = try buildPostprocessPipelineState()
        renderState.postprocessDepthState = try buildPostprocessDepthState()
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

    private func switchToNextDynamicBuffer() {
        renderState.uniformBufferIndex = (renderState.uniformBufferIndex + 1) % maxSimultaneousRenders
        renderState.uniformBufferOffset = UniformsArray.alignedSize * renderState.uniformBufferIndex
        renderState.uniforms = UnsafeMutableRawPointer(dynamicUniformBuffers.contents() + renderState.uniformBufferOffset).bindMemory(to: UniformsArray.self, capacity: 1)
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
            renderState.uniforms.pointee.setUniforms(index: i, uniforms)
        }
    }

    /// Computes the mean camera world position and forward vector from the given viewports.
    private static func cameraWorldPose(forViewports viewports: [ViewportDescriptor]) -> (position: SIMD3<Float>, forward: SIMD3<Float>) {
        let position = viewports.map { cameraWorldPosition(forViewMatrix: $0.viewMatrix) }.mean ?? .zero
        let forward = viewports.map { cameraWorldForward(forViewMatrix: $0.viewMatrix) }.mean?.normalized ?? .init(x: 0, y: 0, z: -1)
        return (position, forward)
    }

    private static func cameraWorldForward(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: -1, w: 0)).xyz
    }

    private static func cameraWorldPosition(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: 0, w: 1)).xyz
    }

    // MARK: - Chunk Table Building

    private func buildChunkTableBuffer(enabledChunks: [(entry: ChunkEntry, chunkIndex: UInt16)]) -> MTLBuffer? {
        // Layout: header followed by chunks array
        let headerSize = MemoryLayout<GPUChunkTableHeader>.size
        let chunkInfoSize = MemoryLayout<GPUChunkInfo>.stride
        let chunksArraySize = enabledChunks.count * chunkInfoSize
        let requiredSize = headerSize + chunksArraySize

        // Try to reuse a pooled buffer; allocate only if nil or too small
        let buffer: MTLBuffer
        if let pooled = bufferPool.acquire(tag: .chunkTable), pooled.length >= requiredSize {
            buffer = pooled
        } else {
            guard let newBuffer = device.makeBuffer(length: requiredSize, options: .storageModeShared) else {
                return nil
            }
            newBuffer.label = "Chunk Table"
            buffer = newBuffer
        }

        let ptr = buffer.contents()

        // Write header at offset 0
        let headerPtr = ptr.assumingMemoryBound(to: GPUChunkTableHeader.self)
        headerPtr.pointee = GPUChunkTableHeader(
            chunksPointer: buffer.gpuAddress + UInt64(headerSize),
            enabledChunkCount: UInt16(enabledChunks.count),
            _padding: 0,
            _padding2: 0
        )

        // Write chunk info array after header
        let chunksPtr = ptr.advanced(by: headerSize).assumingMemoryBound(to: GPUChunkInfo.self)
        for (entry, chunkIndex) in enabledChunks {
            chunksPtr[Int(chunkIndex)] = GPUChunkInfo(
                splatsPointer: entry.chunk.splats.buffer.gpuAddress,
                splatCount: UInt32(entry.chunk.splatCount),
                _padding: 0
            )
        }

        return buffer
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
            if let initializePipelineState = renderState.initializePipelineState {
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
    ///   - accessTimeout: Maximum time to block waiting for render access (when exclusive chunk access is held, or when maxSimultaneousRenders are already in flight). Defaults to 0.1s.
    ///   - sortTimeout: Maximum time to block the caller in order to wait for a valid sorted index buffer to be available. This does not cause the method to wait for the latest sort to complete, it only causes it to block if no sort at all has completed since the last time the sort was invalidated (e.g. if chunks were changed). Passing 0 disables blocking, but may result in a flash after a chunk update instead of a dropped frame. Defaults to blocking 0.1s.
    ///   - commandBuffer: The command buffer to encode rendering commands into
    /// - Returns: `true` if rendering was performed, `false` if rendering was skipped (e.g., due to exclusive access timeout or no splats). When `false` is returned, the caller should drop the frame rather than presenting an incomplete render.
    @discardableResult
    public func render(viewports: [ViewportDescriptor],
                       colorTexture: MTLTexture,
                       colorStoreAction: MTLStoreAction,
                       depthTexture: MTLTexture?,
                       rasterizationRateMap: MTLRasterizationRateMap?,
                       renderTargetArrayLength: Int,
                       accessTimeout: TimeInterval = 0.1,
                       sortTimeout: TimeInterval = 0.1,
                       to commandBuffer: MTLCommandBuffer) throws -> Bool {
        // Try to acquire render access, respecting exclusive access, serial render, and maxSimultaneousRenders
        let deadline = Date().addingTimeInterval(accessTimeout)
        while true {
            let acquired = accessState.withLock { state -> Bool in
                if state.hasExclusiveAccess {
                    return false
                }
                if state.isRendering {
                    return false  // Another render() is in progress - enforce serial execution
                }
                if state.inFlightRenderCount >= maxSimultaneousRenders {
                    return false
                }
                state.isRendering = true
                state.inFlightRenderCount += 1
                return true
            }
            if acquired {
                break
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.001)
        }

        // Clear isRendering when we exit this method (whether by return or throw)
        defer {
            accessState.withLock { state in
                state.isRendering = false
            }
        }

        // Add completion handler to signal when GPU work is done.
        // This must be added early, before any early returns, to ensure the count is always decremented.
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.renderCompleted()
        }

        // Build list of enabled chunks with their sort indices (from the stored mapping)
        var enabledChunks: [(entry: ChunkEntry, chunkIndex: UInt16)] = []
        for entry in chunks.values where entry.isEnabled {
            guard let chunkIndex = chunkIDToIndex[entry.id] else { continue }
            enabledChunks.append((entry, chunkIndex))
        }

        guard !enabledChunks.isEmpty else { return false }

        // Compute camera pose for sorting
        let cameraPose = Self.cameraWorldPose(forViewports: viewports)
        sorter.updateCameraPose(position: cameraPose.position, forward: cameraPose.forward)

        // Try to get sorted indices, optionally waiting up to sortTimeout
        var splatIndexBuffer = sorter.tryObtainSortedIndices()
        if splatIndexBuffer == nil && sortTimeout > 0 {
            let deadline = Date().addingTimeInterval(sortTimeout)
            while splatIndexBuffer == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
                splatIndexBuffer = sorter.tryObtainSortedIndices()
            }
        }
        guard let splatIndexBuffer else { return false }
        defer { sorter.releaseSortedIndices(splatIndexBuffer) }

        let splatCount = splatIndexBuffer.count
        guard splatCount != 0 else { return false }

        let indexedSplatCount = min(splatCount, Constants.maxIndexedSplatCount)
        let instanceCount = (splatCount + indexedSplatCount - 1) / indexedSplatCount

        switchToNextDynamicBuffer()
        updateUniforms(forViewports: viewports, splatCount: UInt32(splatCount), indexedSplatCount: UInt32(indexedSplatCount))

        // Build chunk table buffer (from pool if available)
        guard let chunkTableBuffer = buildChunkTableBuffer(enabledChunks: enabledChunks) else {
            return false
        }

        // Return buffer to pool when GPU is done
        commandBuffer.addCompletedHandler { [bufferPool, chunkTableBuffer] _ in
            bufferPool.release(chunkTableBuffer, tag: .chunkTable)
        }

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
        if renderState.triangleVertexIndexBuffer.count < triangleVertexCount {
            do {
                try renderState.triangleVertexIndexBuffer.ensureCapacity(triangleVertexCount)
            } catch {
                return false
            }
            renderState.triangleVertexIndexBuffer.count = triangleVertexCount
            for i in 0..<indexedSplatCount {
                renderState.triangleVertexIndexBuffer.values[i * 6 + 0] = UInt32(i * 4 + 0)
                renderState.triangleVertexIndexBuffer.values[i * 6 + 1] = UInt32(i * 4 + 1)
                renderState.triangleVertexIndexBuffer.values[i * 6 + 2] = UInt32(i * 4 + 2)
                renderState.triangleVertexIndexBuffer.values[i * 6 + 3] = UInt32(i * 4 + 1)
                renderState.triangleVertexIndexBuffer.values[i * 6 + 4] = UInt32(i * 4 + 2)
                renderState.triangleVertexIndexBuffer.values[i * 6 + 5] = UInt32(i * 4 + 3)
            }
        }

        if multiStage {
            guard let initializePipelineState = renderState.initializePipelineState,
                  let drawSplatPipelineState = renderState.drawSplatPipelineState
            else { return false }

            renderEncoder.pushDebugGroup("Initialize")
            renderEncoder.setRenderPipelineState(initializePipelineState)
            renderEncoder.dispatchThreadsPerTile(Constants.tileSize)
            renderEncoder.popDebugGroup()

            renderEncoder.pushDebugGroup("Draw Splats")
            renderEncoder.setRenderPipelineState(drawSplatPipelineState)
            renderEncoder.setDepthStencilState(renderState.drawSplatDepthState)
        } else {
            guard let singleStagePipelineState = renderState.singleStagePipelineState
            else { return false }

            renderEncoder.pushDebugGroup("Draw Splats")
            renderEncoder.setRenderPipelineState(singleStagePipelineState)
            renderEncoder.setDepthStencilState(renderState.singleStageDepthState)
        }

        renderEncoder.setVertexBuffer(dynamicUniformBuffers, offset: renderState.uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(chunkTableBuffer, offset: 0, index: BufferIndex.chunkTable.rawValue)
        renderEncoder.setVertexBuffer(splatIndexBuffer.buffer, offset: 0, index: BufferIndex.splatIndex.rawValue)

        // Make splat buffers resident - required when accessing via GPU addresses embedded in chunk table
        for (entry, _) in enabledChunks {
            renderEncoder.useResource(entry.chunk.splats.buffer, usage: .read, stages: .vertex)
        }

        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: triangleVertexCount,
                                            indexType: .uint32,
                                            indexBuffer: renderState.triangleVertexIndexBuffer.buffer,
                                            indexBufferOffset: 0,
                                            instanceCount: instanceCount)

        if multiStage {
            guard let postprocessPipelineState = renderState.postprocessPipelineState
            else { return false }

            renderEncoder.popDebugGroup()

            renderEncoder.pushDebugGroup("Postprocess")
            renderEncoder.setRenderPipelineState(postprocessPipelineState)
            renderEncoder.setDepthStencilState(renderState.postprocessDepthState)
            renderEncoder.setCullMode(.none)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            renderEncoder.popDebugGroup()
        } else {
            renderEncoder.popDebugGroup()
        }

        renderEncoder.endEncoding()
        return true
    }

    // MARK: - Locality Sort

    public func optimize(_ chunk: SplatChunk) {
        chunk.sortByLocality()
    }
}

// MARK: - Helper Extensions

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
