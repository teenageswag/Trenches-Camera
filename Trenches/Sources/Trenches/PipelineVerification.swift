#if DEBUG
import AVFoundation
import CoreImage
import OSLog
import SwiftUI

enum PipelineVerification {
    static func run() async -> String {
        var lines: [String] = []
        let logger = Logger(subsystem: "dev.x64dbg.trenches", category: "Verification")
        func record(_ line: String) { lines.append(line); logger.notice("TRENCHES_VERIFY \(line, privacy: .public)") }
        do {
            let renderer = try FrameRenderer()
            record("PASS Metal compilation / glyph atlas")
            let bounds = CGRect(x: 0, y: 0, width: 216, height: 384)
            let image = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 216, y: 384), "inputColor0": CIColor(red: 0.08, green: 0.12, blue: 0.2), "inputColor1": CIColor(red: 0.95, green: 0.75, blue: 0.5)])!.outputImage!.cropped(to: bounds)
            let baseline = try renderer.render(image, depth: nil, settings: EffectSettings(), time: 1)
            let baselineBytes = bytes(baseline)
            guard baselineBytes.max() == 255, Set(baselineBytes).count > 32 else { throw TrenchesError.message("Пустой базовый рендер") }
            record("PASS nonempty BGRA render")
            for effect in EffectID.allCases {
                if effect == .motion { continue }
                var settings = EffectSettings()
                settings.toggle(effect)
                if effect == .tone { settings.set(.tone, "exposure", 1) }
                if effect == .color { settings.set(.color, "temperature", 0.7) }
                let output = try renderer.render(image, depth: nil, settings: settings, time: 1)
                guard bytes(output) != baselineBytes else { throw TrenchesError.message("Эффект \(effect.rawValue) не изменил кадр") }
                record("PASS effect \(effect.rawValue)")
            }
            var motion = EffectSettings()
            motion.toggle(.motion)
            renderer.resetMotion()
            _ = try renderer.render(image, depth: nil, settings: motion, time: 1)
            let stationary = try renderer.render(image, depth: nil, settings: motion, time: 1 + 1.0 / 30)
            guard bytes(stationary) == baselineBytes else { throw TrenchesError.message("Motion blur размывает статичный кадр") }
            record("PASS stationary motion blur / temporal initialization")
            var stacked = EffectSettings()
            EffectID.allCases.forEach { stacked.toggle($0) }
            let output = try renderer.render(image, depth: nil, settings: stacked, time: 2)
            let jpeg = try renderer.jpeg(output)
            guard CGImageSourceCreateWithData(jpeg as CFData, nil) != nil else { throw TrenchesError.message("Невалидный JPEG") }
            record("PASS \(EffectID.allCases.count)-effect stack / JPEG encoding")
            var noDepth = EffectSettings()
            noDepth.toggle(.dof); noDepth.set(.dof, "mode", 1)
            let sharp = try renderer.render(image, depth: nil, settings: noDepth, time: 1)
            guard bytes(sharp) == baselineBytes else { throw TrenchesError.message("DOF без карты глубины меняет кадр") }
            record("PASS missing-depth behavior")
            let recorder = try MovieRecorder(width: 216, height: 384, fps: 30, includeAudio: false)
            for frame in 0..<12 { try recorder.appendVideo(output, at: CMTime(value: Int64(frame), timescale: 30)) }
            let url: URL = try await withCheckedThrowingContinuation { continuation in recorder.finish { continuation.resume(with: $0) } }
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            guard !tracks.isEmpty, duration.seconds > 0 else { throw TrenchesError.message("Пустой MOV") }
            record("PASS HEVC/MOV finish / readable video track")
            let fullBounds = CGRect(x: 0, y: 0, width: 1080, height: 1920)
            let checker = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .cropped(to: CGRect(x: 0, y: 0, width: 216, height: 384))
                .transformed(by: CGAffineTransform(scaleX: 5, y: 5)).cropped(to: fullBounds)
            var ascii = EffectSettings()
            ascii.toggle(.ascii); ascii.set(.ascii, "cell", 6); ascii.set(.ascii, "contrast", 3)
            let inputRenderer = try FrameRenderer()
            let inputBuffer = try inputRenderer.render(checker, depth: nil, settings: EffectSettings(), time: 0)
            let benchmarkImage = CIImage(cvPixelBuffer: inputBuffer)
            for frame in 0..<8 { _ = try renderer.render(benchmarkImage, depth: nil, settings: ascii, time: Double(frame) / 30) }
            record("BENCH ASCII 6px / 300%, 1080x1920")
            let throughput = try await RenderBenchmark(renderer: renderer, image: benchmarkImage, settings: ascii, paced: false).run()
            record(throughput)
            let recording = try await RenderBenchmark(renderer: renderer, image: benchmarkImage, settings: ascii, paced: true).run()
            record(recording)
            record("COMPLETE")
        } catch { record("FAIL \(error.localizedDescription)") }
        let report = lines.joined(separator: "\n")
        if let directory = try? CaptureLibrary.directory().deletingLastPathComponent() { try? report.write(to: directory.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8) }
        return report
    }

    private static func bytes(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var result = [UInt8]()
        for y in 0..<height { result.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width * 4)) }
        return result
    }
}

private final class RenderBenchmark: @unchecked Sendable {
    private let renderer: FrameRenderer
    private let image: CIImage
    private let settings: EffectSettings
    private let paced: Bool
    private let queue = DispatchQueue(label: "dev.trenches.benchmark", qos: .userInitiated)
    private var total: Int { paced ? 240 : 90 }
    private var scheduled = 0
    private var pending = 0
    private var completed = 0
    private var skipped = 0
    private var durations: [Double] = []
    private var started = 0.0
    private var firstError: Error?
    private var finishing = false
    private var recorder: MovieRecorder?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<String, Error>?

    init(renderer: FrameRenderer, image: CIImage, settings: EffectSettings, paced: Bool) {
        self.renderer = renderer; self.image = image; self.settings = settings; self.paced = paced
    }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                started = CACurrentMediaTime()
                if paced {
                    do { recorder = try MovieRecorder(width: 1080, height: 1920, fps: 30, includeAudio: true) }
                    catch { continuation.resume(throwing: error); return }
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30), leeway: .milliseconds(1))
                    timer.setEventHandler { [self] in tick() }
                    self.timer = timer
                    timer.resume()
                } else { pump() }
            }
        }
    }

    private func tick() {
        guard scheduled < total else { finishIfReady(); return }
        if pending >= 3 { scheduled += 1; skipped += 1; finishIfReady(); return }
        submit()
    }
    private func pump() {
        while scheduled < total && pending < 3 && firstError == nil { submit() }
        if firstError != nil { scheduled = total }
        finishIfReady()
    }
    private func submit() {
        let index = scheduled
        scheduled += 1; pending += 1
        let start = CACurrentMediaTime()
        let complete: (Result<CVPixelBuffer, Error>) -> Void = { [self] result in
            queue.async {
                self.pending -= 1
                self.durations.append((CACurrentMediaTime() - start) * 1000)
                do {
                    let buffer = try result.get()
                    try self.recorder?.appendVideo(buffer, at: CMTime(value: Int64(index), timescale: 30))
                    self.completed += 1
                } catch { self.firstError = error }
                if self.paced { self.finishIfReady() } else { self.pump() }
            }
        }
        do {
            let movingImage = paced ? image.clampedToExtent().transformed(by: CGAffineTransform(translationX: sin(Double(index) * 0.47) * 90, y: cos(Double(index) * 0.31) * 140)).cropped(to: image.extent) : image
            try renderer.renderAsync(movingImage, depth: nil, settings: settings, time: Double(index) / 30, completion: complete)
            if paced {
                do { try recorder?.appendAudio(Self.audio(at: index)) }
                catch { firstError = error }
            }
        }
        catch { complete(.failure(error)) }
    }

    private static func audio(at frame: Int) throws -> CMSampleBuffer {
        let count = 1600
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw TrenchesError.message("Benchmark audio format") }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &block) == noErr, let block else { throw TrenchesError.message("Benchmark audio allocation") }
        let samples = (0..<count).map { Float(sin(Double(frame * count + $0) * 2 * .pi * 440 / 48000) * 0.02) }
        let copied = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sample: CMSampleBuffer?
        guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr, let sample else { throw TrenchesError.message("Benchmark audio buffer") }
        return sample
    }
    private func finishIfReady() {
        guard !finishing, scheduled == total, pending == 0, let continuation else { return }
        finishing = true; timer?.cancel(); timer = nil
        self.continuation = nil
        if let firstError { recorder?.cancel(); continuation.resume(throwing: firstError); return }
        let elapsed = CACurrentMediaTime() - started
        let ordered = durations.sorted()
        let p95 = ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))]
        let summary = String(format: "%@: %.1f render FPS, p95 %.1f ms, %d skipped", paced ? "MOVING + AUDIO 30" : "THROUGHPUT", Double(completed) / elapsed, p95, skipped)
        guard let recorder else { continuation.resume(returning: summary); return }
        let frames = recorder.frameCount
        recorder.finish { result in
            switch result {
            case .success(let url):
                try? FileManager.default.removeItem(at: url)
                continuation.resume(returning: String(format: "%@, %d/%d encoded frames, %.2f encoded FPS, %d drops", summary, frames, self.total, recorder.recordedFrameRate, recorder.droppedFrames))
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }
}

struct PipelineVerificationView: View {
    @State private var report = "Проверка GPU…"
    var body: some View {
        ScrollView { Text(report).font(.system(.callout, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .task { report = await Task.detached(priority: .userInitiated) { await PipelineVerification.run() }.value }
    }
}
#endif
