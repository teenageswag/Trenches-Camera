import CoreVideo
import MetalKit
import SwiftUI

final class PreviewFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var sequence: UInt64 = 0
    func set(_ buffer: CVPixelBuffer) { lock.lock(); self.buffer = buffer; sequence &+= 1; lock.unlock() }
    func latest() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return buffer }
    func snapshot() -> (CVPixelBuffer?, UInt64) { lock.lock(); defer { lock.unlock() }; return (buffer, sequence) }
    func clear() { lock.lock(); buffer = nil; sequence &+= 1; lock.unlock() }
}

struct CameraPreview: UIViewRepresentable {
    let frames: PreviewFrames
    func makeCoordinator() -> Coordinator { Coordinator(frames: frames) }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.isOpaque = true
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        let frames: PreviewFrames
        private let queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var cache: CVMetalTextureCache?
        private var lastSequence: UInt64 = .max
        private var lastSize = CGSize.zero
        init(frames: PreviewFrames) {
            self.frames = frames
            queue = device?.makeCommandQueue()
            if let device {
                let source = """
                #include <metal_stdlib>
                using namespace metal;
                struct Vertex { float4 position [[position]]; float2 uv; };
                vertex Vertex previewVertex(uint id [[vertex_id]]) {
                    const float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
                    return { float4(p[id],0,1), float2((p[id].x+1)*0.5, (1-p[id].y)*0.5) };
                }
                fragment float4 previewFragment(Vertex v [[stage_in]],
                                                texture2d<float> image [[texture(0)]],
                                                constant float2 &scale [[buffer(0)]]) {
                    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
                    return float4(image.sample(s, (v.uv-0.5)*scale+0.5).rgb, 1);
                }
                """
                if let library = try? device.makeLibrary(source: source, options: nil) {
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = library.makeFunction(name: "previewVertex")
                    descriptor.fragmentFunction = library.makeFunction(name: "previewFragment")
                    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                    pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
                }
                CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            }
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { lastSequence = .max }
        func draw(in view: MTKView) {
            let (buffer, sequence) = frames.snapshot()
            guard sequence != lastSequence || lastSize != view.drawableSize, let buffer, let pipeline, let cache,
                  view.drawableSize.width > 0, view.drawableSize.height > 0,
                  let command = queue?.makeCommandBuffer(), let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }
            var reference: CVMetalTexture?
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &reference) == kCVReturnSuccess,
                  let reference, let texture = CVMetalTextureGetTexture(reference) else { return }
            let sourceAspect = Float(width) / Float(height)
            let targetAspect = Float(view.drawableSize.width / view.drawableSize.height)
            var scale = sourceAspect > targetAspect ? SIMD2(targetAspect / sourceAspect, 1) : SIMD2(1, sourceAspect / targetAspect)
            pass.colorAttachments[0].loadAction = .dontCare
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            // Keep the IOSurface alive until the preview GPU command finishes.
            command.addCompletedHandler { _ in withExtendedLifetime((buffer, reference)) {} }
            command.commit()
            lastSequence = sequence; lastSize = view.drawableSize
        }
    }
}
