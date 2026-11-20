import AVFoundation
import CoreImage
import Metal
import MetalKit
import MetalPerformanceShaders

enum TrenchesError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Owned by the capture queue. A completed pixel buffer can safely cross to preview/writer.
final class FrameRenderer {
    enum RenderError: Error { case backPressure }
    let device: MTLDevice
    let context: CIContext
    private let queue: MTLCommandQueue
    private let grade: MTLComputePipelineState
    private let finish: MTLComputePipelineState
    private let asciiPrepare: MTLComputePipelineState
    private let jpegDegrade: MTLComputePipelineState
    private let macroblock: MTLComputePipelineState
    private let brightPass: MTLComputePipelineState
    private let lensComposite: MTLComputePipelineState
    private let ditherThreshold: MTLComputePipelineState
    private let ditherInput: MTLComputePipelineState
    private let ditherDiffuse: MTLComputePipelineState
    private let ditherUsesSIMD: Bool
    private let blueNoise: MTLTexture
    private let dirt: MTLTexture
    private let asciiAtlas: ASCIIAtlas
    private var cache: CVMetalTextureCache!
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero
    private var source: MTLTexture?
    private var blurred: MTLTexture?
    private var intermediate: MTLTexture?
    private var asciiCells: MTLTexture?
    private var compressed: MTLTexture?
    private var blockOutput: MTLTexture?
    private var highlights: MTLTexture?
    private var glow: MTLTexture?
    private var lightOutput: MTLTexture?
    private var ditherSignal: MTLTexture?
    private var ditherGrid: MTLTexture?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(allowSIMDDiffusion: Bool = true) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw TrenchesError.message("Metal недоступен на этом устройстве.")
        }
        self.device = device
        self.queue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        guard let url = Bundle.module.url(forResource: "Effects", withExtension: "metal", subdirectory: "Shaders") else {
            throw TrenchesError.message("Не найден файл шейдеров.")
        }
        let options = MTLCompileOptions()
        ditherUsesSIMD = allowSIMDDiffusion && device.supportsFamily(.apple6)
        if ditherUsesSIMD { options.preprocessorMacros = ["TRENCHES_SIMD_DIFFUSION": NSNumber(value: 1)] }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: options)
        guard let gradeFunction = library.makeFunction(name: "grade"), let finishFunction = library.makeFunction(name: "finish"),
              let asciiFunction = library.makeFunction(name: "asciiPrepare"), let jpegFunction = library.makeFunction(name: "jpegDegrade") else {
            throw TrenchesError.message("Не найдены функции обработки Metal.")
        }
        grade = try device.makeComputePipelineState(function: gradeFunction)
        finish = try device.makeComputePipelineState(function: finishFunction)
        asciiPrepare = try device.makeComputePipelineState(function: asciiFunction)
        jpegDegrade = try device.makeComputePipelineState(function: jpegFunction)
        guard let blocks = library.makeFunction(name: "macroblockCorrupt") else { throw TrenchesError.message("Не найден Macroblock.") }
        macroblock = try device.makeComputePipelineState(function: blocks)
        guard let bright = library.makeFunction(name: "brightPass"), let lens = library.makeFunction(name: "lensComposite"),
              let dirtURL = Bundle.module.url(forResource: "LensDirt", withExtension: "png", subdirectory: "Assets") else {
            throw TrenchesError.message("Не найдены ресурсы Lens flare.")
        }
        brightPass = try device.makeComputePipelineState(function: bright)
        lensComposite = try device.makeComputePipelineState(function: lens)
        dirt = try MTKTextureLoader(device: device).newTexture(URL: dirtURL, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        guard let threshold = library.makeFunction(name: "ditherThreshold"), let input = library.makeFunction(name: "ditherInput"),
              let diffuse = library.makeFunction(name: "ditherDiffuse"),
              let noiseURL = Bundle.module.url(forResource: "DitherBlueNoise", withExtension: "png", subdirectory: "Assets") else {
            throw TrenchesError.message("Не найдены ресурсы Dither.")
        }
        ditherThreshold = try device.makeComputePipelineState(function: threshold)
        ditherInput = try device.makeComputePipelineState(function: input)
        ditherDiffuse = try device.makeComputePipelineState(function: diffuse)
        blueNoise = try MTKTextureLoader(device: device).newTexture(URL: noiseURL, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        asciiAtlas = try ASCIIAtlas(device: device, queue: queue)
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw TrenchesError.message("Не удалось создать кэш текстур.")
        }
    }

    private func prepare(width: Int, height: Int) throws {
        guard size != CGSize(width: width, height: height) else { return }
        pool = nil; source = nil; blurred = nil; intermediate = nil; asciiCells = nil; compressed = nil
        ditherGrid = nil; ditherSignal = nil
        size = .zero
        CVMetalTextureCacheFlush(cache, 0)
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { throw TrenchesError.message("Не удалось создать пул кадров.") }
        size = CGSize(width: width, height: height)
    }

    private func scratch(_ cached: inout MTLTexture?, width: Int, height: Int, format: MTLPixelFormat = .rgba8Unorm) throws -> MTLTexture {
        if let cached, cached.width == width, cached.height == height, cached.pixelFormat == format { return cached }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw TrenchesError.message("Недостаточно памяти для обработки кадра.") }
        cached = texture
        return texture
    }

    private struct PendingFrame {
        let output: CVPixelBuffer
        let command: MTLCommandBuffer
        let resources: [Any]
    }

    // Stills may wait; the live capture path submits asynchronously and limits frames in flight.
    func render(_ image: CIImage, depth: AVDepthData?, settings: EffectSettings, time: Double) throws -> CVPixelBuffer {
        let frame = try encodeFrame(image, depth: depth, settings: settings, time: time)
        frame.command.commit()
        frame.command.waitUntilCompleted()
        withExtendedLifetime(frame.resources) {}
        if let error = frame.command.error { throw error }
        return frame.output
    }

    func renderAsync(_ image: CIImage, depth: AVDepthData?, settings: EffectSettings, time: Double,
                     completion: @escaping (Result<CVPixelBuffer, Error>) -> Void) throws {
        let frame = try encodeFrame(image, depth: depth, settings: settings, time: time)
        let resources = frame.resources
        let output = frame.output
        frame.command.addCompletedHandler { command in
            withExtendedLifetime(resources) {
                if let error = command.error { completion(.failure(error)) }
                else { completion(.success(output)) }
            }
        }
        frame.command.commit()
    }

    private func encodeFrame(_ image: CIImage, depth: AVDepthData?, settings: EffectSettings, time: Double) throws -> PendingFrame {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        try prepare(width: width, height: height)
        guard let pool, let command = queue.makeCommandBuffer() else { throw TrenchesError.message("Не удалось подготовить кадр.") }
        var output: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey as String: 10] as CFDictionary, &output)
        if result == kCVReturnWouldExceedAllocationThreshold { throw RenderError.backPressure }
        guard result == kCVReturnSuccess, let output else { throw TrenchesError.message("Очередь кадров переполнена. Попробуйте снизить качество.") }
        var outputReference: CVMetalTexture?
        let textureAttributes = [kCVMetalTextureUsage as String: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, output, textureAttributes, .bgra8Unorm, width, height, 0, &outputReference) == kCVReturnSuccess,
              let outputReference, let outputTexture = CVMetalTextureGetTexture(outputReference) else { throw TrenchesError.message("Не удалось создать выходную текстуру.") }
        let input = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let bounds = CGRect(origin: .zero, size: size)
        let atlas = asciiAtlas.texture
        var resources: [Any] = [image, outputReference]
        if settings.activeCount == (settings.enabled(.motion) ? 1 : 0) {
            let destination = CIRenderDestination(mtlTexture: outputTexture, commandBuffer: command)
            destination.isFlipped = true
            destination.colorSpace = colorSpace
            _ = try context.startTask(toRender: input, from: bounds, to: destination, at: .zero)
            return PendingFrame(output: output, command: command, resources: resources)
        }
        let sourceFormat: MTLPixelFormat = (settings.enabled(.bloom) || settings.enabled(.lensFlare)) && settings.enabled(.tone) ? .rgba16Float : .rgba8Unorm
        var source = try scratch(&self.source, width: width, height: height, format: sourceFormat)
        let destination = CIRenderDestination(mtlTexture: source, commandBuffer: command)
        destination.isFlipped = true
        destination.colorSpace = colorSpace
        _ = try context.startTask(toRender: input, from: bounds, to: destination, at: .zero)
        if settings.enabled(.bloom) || settings.enabled(.lensFlare) {
            let w = max(1, width / 4), h = max(1, height / 4)
            let bright = try scratch(&highlights, width: w, height: h, format: .rgba16Float)
            let soft = try scratch(&glow, width: w, height: h, format: .rgba16Float)
            let light = [SIMD4<Float>(settings.enabled(.lensFlare) ? settings.value(.lensFlare, "threshold") : 0.65,
                settings.enabled(.bloom) ? settings.value(.bloom, "amount") : 0,
                settings.enabled(.lensFlare) ? settings.value(.lensFlare, "amount") : 0,
                settings.enabled(.lensFlare) ? settings.value(.lensFlare, "dirt") : 0)]
            try Self.encode(command, pipeline: brightPass, textures: [source, bright], parameters: light, width: w, height: h)
            let sigma = settings.enabled(.bloom) ? settings.value(.bloom, "radius") * Float(width) / 4320 : 6
            let blur = MPSImageGaussianBlur(device: device, sigma: max(0.5, sigma))
            blur.edgeMode = .clamp
            blur.encode(commandBuffer: command, sourceTexture: bright, destinationTexture: soft)
            let output = try scratch(&lightOutput, width: width, height: height, format: sourceFormat)
            try Self.encode(command, pipeline: lensComposite, textures: [source, bright, soft, dirt, output], parameters: light, width: width, height: height)
            source = output
        }
        var blurTexture = source
        if settings.enabled(.dof) {
            blurTexture = try scratch(&blurred, width: width, height: height, format: sourceFormat)
            let sigma = max(0.1, settings.value(.dof, "amount") * 28 * Float(width) / 1080)
            let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
            blur.edgeMode = .clamp
            blur.encode(commandBuffer: command, sourceTexture: source, destinationTexture: blurTexture)
        }
        var depthReference: CVMetalTexture?
        var depthTexture: MTLTexture?
        var convertedDepth: AVDepthData?
        if settings.wantsDepth, let depth {
            let converted = depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            convertedDepth = converted
            let map = converted.depthDataMap
            if CVMetalTextureCacheCreateTextureFromImage(nil, cache, map, nil, .r32Float, CVPixelBufferGetWidth(map), CVPixelBufferGetHeight(map), 0, &depthReference) == kCVReturnSuccess, let depthReference {
                depthTexture = CVMetalTextureGetTexture(depthReference)
            }
        }
        var p = [SIMD4<Float>](repeating: .zero, count: 22)
        func on(_ id: EffectID) -> Float { settings.enabled(id) ? 1 : 0 }
        p[0] = SIMD4(on(.dof), settings.value(.dof, "mode"), depthTexture == nil ? 0 : 1, 0)
        p[1] = SIMD4(settings.value(.dof, "focus"), settings.value(.dof, "range"), settings.value(.dof, "radius"), 0)
        var depthScale = SIMD2<Float>(repeating: 1)
        if let depthTexture {
            let imageAspect = Float(width) / Float(height)
            let depthAspect = Float(depthTexture.width) / Float(depthTexture.height)
            if imageAspect < depthAspect { depthScale.x = imageAspect / depthAspect }
            else { depthScale.y = depthAspect / imageAspect }
        }
        p[2] = SIMD4(settings.focusX, settings.focusY, depthScale.x, depthScale.y)
        p[3] = SIMD4(on(.tone), settings.value(.tone, "exposure"), settings.value(.tone, "curve"), settings.value(.tone, "highlights"))
        p[4].x = settings.value(.tone, "shadows")
        p[5] = SIMD4(on(.color), settings.value(.color, "temperature"), settings.value(.color, "tint"), settings.value(.color, "saturation"))
        p[6] = SIMD4(settings.value(.color, "contrast"), settings.value(.color, "gamma"), 0, 0)
        p[7] = SIMD4(on(.post), settings.value(.post, "grain"), settings.value(.post, "vignette"), settings.value(.post, "rgb"))
        p[8] = SIMD4(settings.value(.post, "scan"), settings.value(.post, "halftone"), Float(time.truncatingRemainder(dividingBy: 3600)), settings.value(.post, "pixel"))
        p[9] = SIMD4(on(.ascii), settings.value(.ascii, "cell"), settings.value(.ascii, "contrast"), settings.value(.ascii, "palette"))
        p[10] = SIMD4(settings.value(.ascii, "invert"), settings.value(.ascii, "mix"), 0, 0)
        let symbols = ASCIISymbols(rawValue: Int(settings.value(.ascii, "symbols"))) ?? .standard
        let row = asciiAtlas.row(for: symbols, legacy: settings.asciiUsesLegacyGlyphs)
        p[10].z = row.index; p[10].w = row.count
        p[13] = SIMD4(settings.value(.ascii, "inkR"), settings.value(.ascii, "inkG"), settings.value(.ascii, "inkB"), 0)
        p[14] = SIMD4(settings.value(.ascii, "ink2R"), settings.value(.ascii, "ink2G"), settings.value(.ascii, "ink2B"), 0)
        p[15] = SIMD4(settings.value(.ascii, "paperR"), settings.value(.ascii, "paperG"), settings.value(.ascii, "paperB"), 0)
        p[11] = SIMD4(on(.shakal), settings.value(.shakal, "quality"), settings.value(.shakal, "scale"), settings.value(.shakal, "chroma"))
        p[12] = SIMD4(settings.value(.shakal, "sampling"), settings.value(.shakal, "mix"), Float(width), Float(height))
        p[16] = SIMD4(settings.value(.macroblock, "block") < 0.5 ? 8 : 16, settings.value(.macroblock, "amount"), settings.value(.macroblock, "fraction"), settings.value(.macroblock, "seed").rounded())
        p[17].x = Float(floor(time * Double(settings.value(.macroblock, "rate"))).truncatingRemainder(dividingBy: 1_000_000))
        var graded = source
        if settings.enabled(.dof) || settings.enabled(.tone) || settings.enabled(.color) {
            graded = try scratch(&intermediate, width: width, height: height)
            try Self.encode(command, pipeline: grade, textures: [source, blurTexture, depthTexture ?? atlas, graded], parameters: p, width: width, height: height)
        }
        if settings.enabled(.macroblock) {
            let blocks = try scratch(&blockOutput, width: width, height: height)
            try Self.encode(command, pipeline: macroblock, textures: [graded, blocks], parameters: p, width: width, height: height)
            graded = blocks
        }
        var compressedTexture = graded
        if settings.enabled(.shakal) {
            let w = max(8, Int((Float(width) / p[11].z / 8).rounded()) * 8)
            let h = max(8, Int((Float(height) / p[11].z / 8).rounded()) * 8)
            compressedTexture = try scratch(&compressed, width: w, height: h)
            guard let encoder = command.makeComputeCommandEncoder() else { throw TrenchesError.message("Не удалось запустить JPEG-эффект.") }
            encoder.setComputePipelineState(jpegDegrade)
            encoder.setTexture(graded, index: 0)
            encoder.setTexture(compressedTexture, index: 1)
            p.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.dispatchThreadgroups(MTLSize(width: w / 8, height: h / 8, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
        var dither = atlas
        if settings.enabled(.dither), settings.value(.dither, "mix") > 0 {
            let mode = DitherMode(rawValue: Int(settings.value(.dither, "mode"))) ?? .bayer4
            let pixel = Int(settings.value(.dither, "pixel").rounded())
            // Use integer geometry so equal-aspect photo and video frames round to the same grid.
            let rowDenominator = width * pixel
            let w = min(width, (1080 + pixel - 1) / pixel)
            let h = min(height, (height * 1080 + rowDenominator - 1) / rowDenominator)
            p[18] = SIMD4(Float(mode.rawValue), settings.value(.dither, "levels").rounded() - 1,
                          settings.value(.dither, "intensity"), settings.value(.dither, "threshold"))
            p[19] = SIMD4(settings.value(.dither, "palette"), settings.value(.dither, "mix"), 0, 0)
            p[20] = SIMD4(settings.value(.dither, "darkR"), settings.value(.dither, "darkG"), settings.value(.dither, "darkB"), 0)
            p[21] = SIMD4(settings.value(.dither, "lightR"), settings.value(.dither, "lightG"), settings.value(.dither, "lightB"), 0)
            dither = try scratch(&ditherGrid, width: w, height: h)
            if mode.diffusesError {
                let signal = try scratch(&ditherSignal, width: w, height: h, format: .rgba16Float)
                try Self.encode(command, pipeline: ditherInput, textures: [graded, compressedTexture, signal], parameters: p, width: w, height: h)
                try encodeDiffusion(command, input: signal, output: dither, parameters: p)
            } else {
                try Self.encode(command, pipeline: ditherThreshold, textures: [graded, compressedTexture, blueNoise, dither], parameters: p, width: w, height: h)
            }
        }
        var cells = atlas
        if settings.enabled(.ascii) {
            let cell = settings.value(.ascii, "cell") * Float(width) / 1080
            let w = max(1, Int(ceil(Float(width) / cell)))
            let h = max(1, Int(ceil(Float(height) / (cell * 1.5))))
            cells = try scratch(&asciiCells, width: w, height: h)
            try Self.encode(command, pipeline: asciiPrepare, textures: [graded, compressedTexture, dither, cells], parameters: p, width: w, height: h)
        }
        try Self.encode(command, pipeline: finish, textures: [graded, atlas, compressedTexture, cells, dither, outputTexture], parameters: p, width: width, height: height)
        if let depthReference { resources.append(depthReference) }
        if let convertedDepth { resources.append(convertedDepth) }
        return PendingFrame(output: output, command: command, resources: resources)
    }

    private func encodeDiffusion(_ command: MTLCommandBuffer, input: MTLTexture, output: MTLTexture,
                                 parameters: [SIMD4<Float>]) throws {
        let lanes = ditherUsesSIMD ? ditherDiffuse.threadExecutionWidth : 32
        guard lanes >= 22, let encoder = command.makeComputeCommandEncoder() else {
            throw TrenchesError.message("Metal не смог запустить диффузию ошибки.")
        }
        encoder.setComputePipelineState(ditherDiffuse)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        parameters.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        // One threadgroup per 32×16 output tile, including six preparatory rows.
        let tiles = MTLSize(width: (output.width + 31) / 32, height: (output.height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(tiles, threadsPerThreadgroup: MTLSize(width: lanes, height: 1, depth: 1))
        encoder.endEncoding()
    }

    static func encode(_ command: MTLCommandBuffer, pipeline: MTLComputePipelineState, textures: [MTLTexture], parameters: [SIMD4<Float>], width: Int, height: Int) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw TrenchesError.message("Metal не смог начать обработку.") }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        if !parameters.isEmpty { parameters.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) } }
        let w = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: min(8, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
        encoder.endEncoding()
    }

    func jpeg(_ buffer: CVPixelBuffer) throws -> Data {
        guard let data = context.jpegRepresentation(of: CIImage(cvPixelBuffer: buffer), colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]) else { throw TrenchesError.message("Не удалось закодировать фото.") }
        return data
    }
}
