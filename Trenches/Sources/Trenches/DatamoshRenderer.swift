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
    private var velocityIndex = 0
    private let activity: MTLBuffer
    private(set) var movement = 0.0

    init(width: Int, height: Int, referenceWidth: Int, transform: CGAffineTransform = .identity) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let activity = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let url = Bundle.module.url(forResource: "Effects", withExtension: "metal", subdirectory: "Shaders") else {
            throw TrenchesError.message("Metal недоступен для Datamosh.")
        }
        self.device = device; self.queue = queue; self.activity = activity
        self.width = width; self.height = height; self.referenceWidth = referenceWidth; self.transform = transform
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in ["estimateMotion", "opticalFlow", "accumulateVectors", "datamoshCompose", "copyFrame", "motionActivity"] {
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

    func render(_ buffer: CVPixelBuffer, frame: Int, document: DatamoshDocument) throws -> CVPixelBuffer {
        guard let command = queue.makeCommandBuffer() else { throw TrenchesError.message("Очередь Datamosh недоступна.") }
        let current = try texture("current", width, height)
        let previous = try texture("previous", width, height)
        let anchor = try texture("anchor", width, height)
        var image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width, y: CGFloat(height) / image.extent.height))
        let destination = CIRenderDestination(mtlTexture: current, commandBuffer: command)
        destination.isFlipped = true; destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        _ = try context.startTask(toRender: image, from: CGRect(x: 0, y: 0, width: width, height: height), to: destination, at: .zero)
        let segment = document.segment(at: frame)
        let consecutive = previousFrame.map { $0 + 1 == frame } ?? false
        let intervalReset = segment.map { $0.resetInterval > 0 && (frame - $0.start) % $0.resetInterval == 0 } ?? false
        let reset = !consecutive || segment?.id != activeID || intervalReset || document.resets.contains(frame)
        let oldOutput = try texture("output\(outputIndex)", width, height)
        let output = try texture("output\(1 - outputIndex)", width, height)
        movement = 0
        if let segment, !reset {
            let field: MTLTexture
            let vectorScale: Float
            if segment.value("estimation") < 0.5 {
                let block = max(1, Float(segment.blockSize) * Float(width) / Float(referenceWidth))
                field = try texture("blockFlow", Int(ceil(Float(width) / block)), Int(ceil(Float(height) / block)), .rgba16Float)
                let search = max(1, 16 * Float(width) / Float(referenceWidth))
                try encode(command, "estimateMotion", [current, previous, field], [SIMD4(block, search, 0, 0)])
                vectorScale = 1
            } else {
                field = try opticalFlow(command, current, previous)
                vectorScale = Float(width) / Float(field.width)
            }
            let velocity = try texture("velocity\(velocityIndex)", field.width, field.height, .rgba16Float)
            let nextVelocity = try texture("velocity\(1 - velocityIndex)", field.width, field.height, .rgba16Float)
            let velocityValid = previousFrame != nil && activeID == segment.id && textures["velocityValid"] != nil
            try encode(command, "accumulateVectors", [field, velocity, nextVelocity], [SIMD4(segment.value("accumulation"), segment.value("decay"), velocityValid ? 1 : 0, 0)])
            textures["velocityValid"] = nextVelocity
            velocityIndex = 1 - velocityIndex
            var p = [SIMD4<Float>](repeating: .zero, count: 4)
            p[0] = SIMD4(Float(segment.mode.index), segment.value("strength"), Float(segment.blockSize) * Float(width) / Float(referenceWidth), Float(frame))
            p[1] = SIMD4(segment.value("accumulation"), segment.value("decay"), segment.value("threshold"), segment.value("fraction"))
            p[2] = SIMD4(segment.value("distortion"), segment.value("distortionAmount"), segment.value("trail"), segment.value("seed").rounded())
            p[3] = SIMD4(vectorScale, Float(width) / Float(referenceWidth), 0, 0)
            try encode(command, "datamoshCompose", [current, previous, oldOutput, anchor, field, nextVelocity, output], p)
            activity.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            try encode(command, "motionActivity", [field], [SIMD4(vectorScale, 0, 0, 0)], buffer: activity)
            movement = -Double(field.width * field.height)
        } else {
            // Transfer seeds from scene A; other modes start from the current unmodified frame.
            let initial = segment?.mode == .transfer && frame == segment?.start && (segment?.value("strength") ?? 0) > 0 && consecutive ? previous : current
            try copy(command, initial, output)
            try copy(command, current, anchor)
            textures.removeValue(forKey: "velocityValid")
        }
        try copy(command, current, previous)
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess, let result else { throw TrenchesError.message("Недостаточно памяти для выходного кадра.") }
        var reference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, result, nil, .bgra8Unorm, width, height, 0, &reference) == kCVReturnSuccess,
              let reference, let target = CVMetalTextureGetTexture(reference) else { throw TrenchesError.message("Не удалось создать выходную текстуру Datamosh.") }
        try copy(command, output, target)
        command.commit(); command.waitUntilCompleted()
        withExtendedLifetime([reference as Any, image as Any]) {}
        if let error = command.error { throw error }
        if movement < 0 { movement = Double(activity.contents().load(as: UInt32.self)) / -movement }
        previousFrame = frame; activeID = segment?.id; outputIndex = 1 - outputIndex
        return result
    }

    private func opticalFlow(_ command: MTLCommandBuffer, _ current: MTLTexture, _ previous: MTLTexture) throws -> MTLTexture {
        let scale = min(1, 960.0 / Double(max(width, height)))
        let w = max(8, Int(Double(width) * scale)), h = max(8, Int(Double(height) * scale))
        let scaler = MPSImageBilinearScale(device: device)
        var currents: [MTLTexture] = [], previouses: [MTLTexture] = []
        for level in 0..<4 {
            let cw = max(4, w >> level), ch = max(4, h >> level)
            let a = try texture("opticalCurrent\(level)", cw, ch)
            let b = try texture("opticalPrevious\(level)", cw, ch)
            scaler.encode(commandBuffer: command, sourceTexture: currents.last ?? current, destinationTexture: a)
            scaler.encode(commandBuffer: command, sourceTexture: previouses.last ?? previous, destinationTexture: b)
            currents.append(a); previouses.append(b)
        }
        var flow: MTLTexture?
        for level in (0..<4).reversed() {
            for iteration in 0..<4 {
                let target = try texture("opticalFlow\(level)-\(iteration % 2)", currents[level].width, currents[level].height, .rgba16Float)
                try encode(command, "opticalFlow", [currents[level], previouses[level], flow ?? previouses[level], target], [SIMD4(flow == nil ? 0 : 1, 0, 0, 0)])
                flow = target
            }
        }
        return flow!
    }
}
