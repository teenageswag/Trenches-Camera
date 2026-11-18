import Metal

// The capture queue encodes every frame on the same Metal queue. Texture reuse
// is ordered by the command buffers, including when multiple frames are in flight.
final class MotionBlur {
    private struct Level {
        let luma: [MTLTexture]
        let backward: MTLTexture
        let forward: MTLTexture
    }

    private let device: MTLDevice
    private let downsample: MTLComputePipelineState
    private let match: MTLComputePipelineState
    private let validate: MTLComputePipelineState
    private let reconstruct: MTLComputePipelineState
    private var levels: [Level] = []
    private var velocity: MTLTexture?
    private var output: MTLTexture?
    private var lastTime: Double?
    private var currentIndex = 0

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw TrenchesError.message("Не найден шейдер Motion Blur: \(name).")
            }
            return try device.makeComputePipelineState(function: function)
        }
        downsample = try pipeline("shutterLuma")
        match = try pipeline("shutterMatch")
        validate = try pipeline("shutterValidate")
        reconstruct = try pipeline("shutterReconstruct")
    }

    func reset() { lastTime = nil }

    func encode(source: MTLTexture, command: MTLCommandBuffer, settings: EffectSettings, time: Double, frameDuration: Double) throws -> MTLTexture {
        guard settings.enabled(.motion), time.isFinite else { reset(); return source }
        let angle = settings.value(.motion, "shutter")
        let limit = settings.value(.motion, "radius") * Float(source.width) / 1080
        let mix = settings.value(.motion, "mix")
        guard angle > 0, limit > 0, mix > 0 else { reset(); return source }

        let width = min(320, source.width)
        let height = max(1, Int((Double(source.height) * Double(width) / Double(source.width)).rounded()))
        if levels.first?.luma[0].width != width || levels.first?.luma[0].height != height {
            var replacement: [Level] = []
            for scale in [1, 2, 4] {
                let w = max(1, (width + scale - 1) / scale), h = max(1, (height + scale - 1) / scale)
                replacement.append(try Level(luma: [texture(w, h, .r16Float), texture(w, h, .r16Float)],
                    backward: texture((w + 3) / 4, (h + 3) / 4, .rgba16Float),
                    forward: texture((w + 3) / 4, (h + 3) / 4, .rgba16Float)))
            }
            levels = replacement
            velocity = nil
            reset()
        }

        let previousIndex = 1 - currentIndex
        var input = source
        for (index, level) in levels.enumerated() {
            let luma = level.luma[currentIndex]
            try encode(command, downsample, [input, luma], [SIMD4(index == 0 ? 1 : 0, 0, 0, 0)])
            input = luma
        }
        let elapsed = lastTime.map { time - $0 } ?? 0
        var result = source
        if elapsed > 0, elapsed <= frameDuration * 2.5 {
            for index in levels.indices.reversed() {
                let level = levels[index]
                let current = level.luma[currentIndex], previous = level.luma[previousIndex]
                let coarse = index + 1 < levels.count ? levels[index + 1] : nil
                let p = SIMD4<Float>(coarse == nil ? 0 : 1, index == 0 ? 1 : 0, 0, 0)
                try encode(command, match, [current, previous, coarse?.backward ?? current, level.backward], [p])
                try encode(command, match, [previous, current, coarse?.forward ?? previous, level.forward], [p])
            }
            let fine = levels[0]
            let field = try cachedTexture(&velocity, fine.backward.width, fine.backward.height, .rgba16Float)
            try encode(command, validate, [fine.backward, fine.forward, field], [SIMD4(Float(width), Float(height), 0, 0)])
            let target = try cachedTexture(&output, source.width, source.height, source.pixelFormat)
            // Normalize missed frames to the intended shutter time instead of lengthening the streak.
            let exposure = angle / 360 * Float(min(1.25, frameDuration / elapsed))
            try encode(command, reconstruct, [source, field, target], [SIMD4(exposure, limit, mix, 0)])
            result = target
        }
        lastTime = time
        currentIndex = previousIndex
        return result
    }

    private func encode(_ command: MTLCommandBuffer, _ pipeline: MTLComputePipelineState, _ textures: [MTLTexture], _ parameters: [SIMD4<Float>]) throws {
        let target = textures[textures.count - 1]
        try FrameRenderer.encode(command, pipeline: pipeline, textures: textures, parameters: parameters, width: target.width, height: target.height)
    }

    private func texture(_ width: Int, _ height: Int, _ format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TrenchesError.message("Не удалось выделить текстуру Motion Blur.")
        }
        return texture
    }

    private func cachedTexture(_ cached: inout MTLTexture?, _ width: Int, _ height: Int, _ format: MTLPixelFormat) throws -> MTLTexture {
        if let cached, cached.width == width, cached.height == height, cached.pixelFormat == format { return cached }
        let result = try texture(width, height, format)
        cached = result
        return result
    }
}
