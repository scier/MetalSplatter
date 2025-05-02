//  Original source: https://gist.github.com/kemchenj/26e1dad40e5b89de2828bad36c81302f
//  Assessed Feb 2, 2025.
import MetalPerformanceShaders
import MetalPerformanceShadersGraph

public class MPSArgSort {
    private let dataType: MPSDataType
    private let graph: MPSGraph
    private let graphExecutable: MPSGraphExecutable
    private let inputTensor: MPSGraphTensor
    private let outputTensor: MPSGraphTensor

    init(dataType: MPSDataType, descending: Bool = false) {
        self.dataType = dataType

        let graph = MPSGraph()
        let inputTensor = graph.placeholder(shape: nil, dataType: dataType, name: nil)
        let outputTensor = graph.argSort(inputTensor, axis: 0, descending: descending, name: nil)

        self.graph = graph
        self.inputTensor = inputTensor
        self.outputTensor = outputTensor
        self.graphExecutable = autoreleasepool {
            let compilationDescriptor = MPSGraphCompilationDescriptor()
            compilationDescriptor.waitForCompilationCompletion = true
            compilationDescriptor.disableTypeInference()
            return graph.compile(with: nil,
                                 feeds: [inputTensor : MPSGraphShapedType(shape: nil, dataType: dataType)],
                                 targetTensors: [outputTensor],
                                 targetOperations: nil,
                                 compilationDescriptor: compilationDescriptor)
        }
    }

    func callAsFunction(
        commandQueue: any MTLCommandQueue,
        input: any MTLBuffer,
        output: any MTLBuffer,
        count: Int
    ) {
        autoreleasepool {
            let commandBuffer = commandQueue.makeCommandBuffer()!
            callAsFunction(commandBuffer: commandBuffer,
                           input: input,
                           output: output,
                           count: count)
            assert(commandBuffer.error == nil)
            assert(commandBuffer.status == .completed)
        }
    }

    private func callAsFunction(
        commandBuffer: any MTLCommandBuffer,
        input: any MTLBuffer,
        output: any MTLBuffer,
        count: Int
    ) {
        let shape: [NSNumber] = [count as NSNumber]
        let inputData = MPSGraphTensorData(input, shape: shape, dataType: dataType)
        let outputData = MPSGraphTensorData(output, shape: shape, dataType: .int32)
        let executionDescriptor = MPSGraphExecutableExecutionDescriptor()
        executionDescriptor.waitUntilCompleted = true
        graphExecutable.encode(to: MPSCommandBuffer(commandBuffer: commandBuffer),
                               inputs: [inputData],
                               results: [outputData],
                               executionDescriptor: executionDescriptor)
    }
}
