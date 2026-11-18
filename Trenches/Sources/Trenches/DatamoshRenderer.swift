import AVFoundation
import CoreImage
import Metal
import MetalPerformanceShaders

// One instance belongs to one serial render session. It never crosses preview/export queues.
final class DatamoshRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    let context: CIContext
    private let pipelines: [String: MTLComputePipelineState]
    private var textures: [String: MTLTexture] = [:]
    private var cache: CVMetalTextureCache!
    private var pool: CVPixelBufferPool!
    private let width: Int
    private let height: Int
    private let referenceWidth: Int
    private let transform: CGAffineTransform
    private var previousFrame: Int?
    private var activeID: UUID?
    private var outputIndex = 0
    private let analysisWidth: Int
    private let analysisHeight: Int
    private let referenceHeight: Int
    private var analysisIndex = 0
    private var runStart = 0
    private let activity: MTLBuffer
    private(set) var movement = 0.0

    init(width: Int, height: Int, referenceWidth: Int, referenceHeight: Int? = nil, transform: CGAffineTransform = .identity) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let activity = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let url = Bundle.module.url(forResource: "Effects", withExtension: "metal", subdirectory: "Shaders") else {
            throw TrenchesError.message("Metal недоступен для Datamosh.")
        }
        self.device = device; self.queue = queue; self.activity = activity
        self.width = width; self.height = height; self.referenceWidth = referenceWidth; self.transform = transform
        self.referenceHeight = referenceHeight ?? max(1, Int((Double(height) * Double(referenceWidth) / Double(width)).rounded()))
        let analysisScale = min(1, 640.0 / Double(max(referenceWidth, self.referenceHeight)))
        analysisWidth = max(2, Int((Double(referenceWidth) * analysisScale).rounded()))
        analysisHeight = max(2, Int((Double(self.referenceHeight) * analysisScale).rounded()))
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in ["estimateMotion", "opticalFlow", "flowToBlocks", "datamoshResidual", "datamoshDecode", "copyFrame", "motionActivity"] {
            guard let function = library.makeFunction(name: name) else { throw TrenchesError.message("Не найден шейдер \(name).") }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        self.pipelines = pipelines
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else { throw TrenchesError.message("Не удалось создать кэш Datamosh.") }
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { throw TrenchesError.message("Не удалось создать кадры Datamosh.") }
    }

    private func texture(_ name: String, _ w: Int, _ h: Int, _ format: MTLPixelFormat = .rgba8Unorm) throws -> MTLTexture {
        if let old = textures[name], old.width == w, old.height == h, old.pixelFormat == format { return old }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let result = device.makeTexture(descriptor: descriptor) else { throw TrenchesError.message("Недостаточно памяти для Datamosh. Закройте другие приложения.") }
        textures[name] = result
        return result
    }

    private func encode(_ command: MTLCommandBuffer, _ name: String, _ textures: [MTLTexture], _ parameters: [SIMD4<Float>] = [], buffer: MTLBuffer? = nil) throws {
        guard let pipeline = pipelines[name], let encoder = command.makeComputeCommandEncoder(), let target = textures.last else { throw TrenchesError.message("Не удалось запустить Datamosh.") }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        if !parameters.isEmpty { parameters.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) } }
        if let buffer { encoder.setBuffer(buffer, offset: 0, index: 1) }
        let w = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: min(8, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
        encoder.endEncoding()
    }

    private func copy(_ command: MTLCommandBuffer, _ source: MTLTexture, _ target: MTLTexture) throws {
        try encode(command, "copyFrame", [source, target])
    }

    func reset() {
        previousFrame = nil
        activeID = nil
        movement = 0
    }

    private func draw(_ buffer: CVPixelBuffer, into texture: MTLTexture, using command: MTLCommandBuffer) throws {
        var image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(texture.width) / image.extent.width, y: CGFloat(texture.height) / image.extent.height))
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
        destination.isFlipped = true
        destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        _ = try context.startTask(toRender: image, from: CGRect(x: 0, y: 0, width: texture.width, height: texture.height), to: destination, at: .zero)
    }

    func render(_ buffer: CVPixelBuffer, frame: Int, document: DatamoshDocument, donor: CVPixelBuffer? = nil) throws -> CVPixelBuffer {
        guard let command = queue.makeCommandBuffer() else { throw TrenchesError.message("Очередь Datamosh недоступна.") }
        let current = try texture("current", width, height)
        try draw(buffer, into: current, using: command)
        let segment = document.segment(at: frame).flatMap { $0.value("strength") > 0 ? $0 : nil }
        let consecutive = previousFrame.map { $0 + 1 == frame } ?? false
        let intervalReset = segment.map { $0.resetInterval > 0 && (frame - $0.start) % $0.resetInterval == 0 } ?? false
        let reset = !consecutive || segment?.id != activeID || intervalReset || document.resets.contains(frame)

        var output = current
        movement = 0
        var fieldCount = 0
        if let segment {
            let history = try texture("output\(outputIndex)", width, height)
            output = try texture("output\(1 - outputIndex)", width, height)
            let currentAnalysis = try texture("analysis\(analysisIndex)", analysisWidth, analysisHeight)
            try draw(buffer, into: currentAnalysis, using: command)
            let anchor = segment.mode == .freeze ? try texture("anchor", width, height) : history
            if reset {
                runStart = frame
                if frame == segment.start, segment.mode == .transfer, !document.resets.contains(frame) {
                    if let donor { try draw(donor, into: output, using: command) }
                    else if consecutive {
                        try copy(command, texture("transferDonor", width, height), output)
                    } else { try copy(command, current, output) }
                } else {
                    try copy(command, current, output)
                }
                if segment.mode == .freeze { try copy(command, current, anchor) }
            } else {
                let block = segment.blockSize
                let field = try texture("blockFlow", (referenceWidth + block - 1) / block,
                                        (referenceHeight + block - 1) / block, .rgba16Float)
                let residual = try texture("residual", analysisWidth, analysisHeight, .rgba16Float)
                let age = frame - runStart
                let period = max(2, Int(segment.value("repeat").rounded()))
                let repeatAge = segment.mode == .bloom ? (age - 1) % period : 0
                if repeatAge == 0 {
                    let previousAnalysis = try texture("analysis\(1 - analysisIndex)", analysisWidth, analysisHeight)
                    if segment.value("estimation") >= 0.5 {
                        let flow = try opticalFlow(command, currentAnalysis, previousAnalysis)
                        try encode(command, "flowToBlocks", [currentAnalysis, previousAnalysis, flow, field])
                    } else {
                        let search = max(4, 16 * Float(max(analysisWidth, analysisHeight)) / 640)
                        try encode(command, "estimateMotion", [currentAnalysis, previousAnalysis, field], [SIMD4(search, 0, 0, 0)])
                    }
                    try encode(command, "datamoshResidual", [currentAnalysis, previousAnalysis, field, residual], [SIMD4(segment.value("strength"), 0, 0, 0)])
                }
                let recovery = segment.recoveryFrames
                let remaining = segment.endFrame - frame
                let repair = recovery > 0 ? max(0, Float(recovery - remaining + 1) / Float(recovery + 1)) : 0
                let settings = [
                    SIMD4(Float(segment.mode.index), segment.value("strength"), Float(age), segment.value("seed").rounded()),
                    SIMD4(segment.value("accumulation"), segment.value("decay"), segment.value("threshold"), segment.value("fraction")),
                    SIMD4(segment.value("distortion"), segment.value("distortionAmount"), segment.value("trail").rounded(), 0),
                    SIMD4(repair, Float(repeatAge), 0, 0)
                ]
                try encode(command, "datamoshDecode", [current, history, anchor, field, residual, output], settings)
                activity.contents().storeBytes(of: UInt32(0), as: UInt32.self)
                try encode(command, "motionActivity", [field], buffer: activity)
                fieldCount = field.width * field.height
            }
            analysisIndex = 1 - analysisIndex
            outputIndex = 1 - outputIndex
        }
        // Preserve the original frame before a cut, even when two ranges touch.
        if let next = document.segment(at: frame + 1), next.start == frame + 1, next.mode == .transfer, next.donorFrame == nil {
            try copy(command, current, texture("transferDonor", width, height))
        }

        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess, let result else {
            throw TrenchesError.message("Недостаточно памяти для выходного кадра.")
        }
        var reference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, result, nil, .bgra8Unorm, width, height, 0, &reference) == kCVReturnSuccess,
              let reference, let target = CVMetalTextureGetTexture(reference) else {
            throw TrenchesError.message("Не удалось создать выходную текстуру Datamosh.")
        }
        try copy(command, output, target)
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime((buffer, donor, reference)) {}
        if let error = command.error { throw error }
        if fieldCount > 0 { movement = Double(activity.contents().load(as: UInt32.self)) / Double(fieldCount) }
        previousFrame = frame
        activeID = segment?.id
        return result
    }

    private func opticalFlow(_ command: MTLCommandBuffer, _ current: MTLTexture, _ previous: MTLTexture) throws -> MTLTexture {
        let scaler = MPSImageBilinearScale(device: device)
        var currents: [MTLTexture] = [], previouses: [MTLTexture] = []
        for level in 1...3 {
            let w = max(2, analysisWidth >> level), h = max(2, analysisHeight >> level)
            let a = try texture("opticalCurrent\(level)", w, h)
            let b = try texture("opticalPrevious\(level)", w, h)
            scaler.encode(commandBuffer: command, sourceTexture: currents.last ?? current, destinationTexture: a)
            scaler.encode(commandBuffer: command, sourceTexture: previouses.last ?? previous, destinationTexture: b)
            currents.append(a)
            previouses.append(b)
        }
        var flow: MTLTexture?
        for level in currents.indices.reversed() {
            for iteration in 0..<3 {
                let target = try texture("opticalFlow\(level)-\(iteration % 2)", currents[level].width, currents[level].height, .rgba16Float)
                try encode(command, "opticalFlow", [currents[level], previouses[level], flow ?? previouses[level], target], [SIMD4(flow == nil ? 0 : 1, 0, 0, 0)])
                flow = target
            }
        }
        return flow!
    }
}
