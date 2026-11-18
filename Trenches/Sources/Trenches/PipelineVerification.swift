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
            try verifyASCIIShadows(renderer: renderer, record: record)
            try verifyCameraShutter(record: record)
            record(try await CameraService.verifyShutterHardware())
            try await verifyDatamosh(renderer: renderer, record: record)
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

    private static func verifyASCIIShadows(renderer: FrameRenderer, record: (String) -> Void) throws {
        let width = 1080, height = 90, bandWidth = 216
        let levels: [UInt8] = [0, 9, 28, 62, 235]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let gray = levels[x / bandWidth], index = (y * width + x) * 4
            pixels[index] = gray; pixels[index + 1] = gray; pixels[index + 2] = gray
        } }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var settings = EffectSettings()
        settings.toggle(.ascii)
        settings.set(.ascii, "cell", 6); settings.set(.ascii, "contrast", 3); settings.set(.ascii, "palette", 4)
        let output = bytes(try renderer.render(image, depth: nil, settings: settings, time: 1))
        let ink = levels.indices.map { band in
            (0..<height).reduce(0) { total, y in
                total + (0..<bandWidth).reduce(0) { row, x in
                    let i = (y * width + band * bandWidth + x) * 4
                    return row + (output[i + 1] > 16 ? 1 : 0)
                }
            }
        }
        guard ink[0] == 0, ink[1] > 0, ink[2] > ink[1], ink[3] > 0, ink[4] > ink[2] else {
            throw TrenchesError.message("ASCII 6 px/300% теряет детали в тенях: \(ink)")
        }
        record("PASS ASCII 6 px/300% / black background and shadow glyphs: \(ink)")
    }

    private static func verifyCameraShutter(record: (String) -> Void) throws {
        let minimum = CMTime(value: 1, timescale: 8_000), maximum = CMTime(value: 1, timescale: 2)
        func duration(_ angle: Float, _ fps: Int32) -> CMTime? {
            CameraShutter.duration(angle: angle, fps: fps, minimum: minimum, maximum: maximum)
        }
        guard duration(0, 30) == nil, duration(0.01, 30) == minimum,
              duration(360, 30).map({ abs($0.seconds - 1.0 / 30) < 0.00001 }) == true,
              duration(180, 60).map({ abs($0.seconds - 1.0 / 120) < 0.00001 }) == true,
              CameraShutter.duration(angle: 360, fps: 30, minimum: minimum, maximum: CMTime(value: 1, timescale: 60)) == CMTime(value: 1, timescale: 60) else {
            throw TrenchesError.message("Угол затвора не учитывает FPS или пределы сенсора")
        }
        record("PASS camera shutter angle / capture cadence / hardware range")
    }

    private static func verifyDatamosh(renderer: FrameRenderer, record: (String) -> Void) async throws {
        let bounds = CGRect(x: 0, y: 0, width: 96, height: 160)
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 11, "inputSharpness": 1])!.outputImage!
        var inputs: [CVPixelBuffer] = []
        for i in 0..<14 {
            var image = checker.transformed(by: CGAffineTransform(translationX: CGFloat(i * 4), y: CGFloat(i * 2))).cropped(to: bounds)
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: i < 3 ? 1 : 0.2, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: i < 3 ? 0.2 : 1, w: 0)])
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 96, 160, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
                throw TrenchesError.message("Не удалось создать тестовый кадр")
            }
            renderer.context.render(image, to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            inputs.append(buffer)
        }
        let clean = try DatamoshRenderer(width: 96, height: 160, referenceWidth: 96)
        for mode in DatamoshMode.allCases {
            var segment = DatamoshSegment(start: 2, duration: 10, mode: mode)
            segment.values["strength"] = 1; segment.values["fraction"] = 1
            segment.values["distortion"] = 3
            let doc = DatamoshDocument(segments: [segment])
            let a = try DatamoshRenderer(width: 96, height: 160, referenceWidth: 96)
            let b = try DatamoshRenderer(width: 96, height: 160, referenceWidth: 96)
            var changed = false
            for frame in inputs.indices {
                let result = try a.render(inputs[frame], frame: frame, document: doc)
                let repeatResult = try b.render(inputs[frame], frame: frame, document: doc)
                let baseline = try clean.render(inputs[frame], frame: frame, document: DatamoshDocument())
                guard bytes(result) == bytes(repeatResult) else { throw TrenchesError.message("Datamosh \(mode.rawValue): недетерминированный seed") }
                if frame < 2 || frame >= 12 {
                    guard bytes(result) == bytes(baseline) else { throw TrenchesError.message("Datamosh меняет кадр вне сегмента") }
                } else if bytes(result) != bytes(baseline) { changed = true }
            }
            guard changed else { throw TrenchesError.message("Datamosh \(mode.rawValue): эффект не проявился") }
            record("PASS Datamosh \(mode.rawValue) / deterministic seed / segment boundaries")
        }
        var optical = DatamoshSegment(start: 0, duration: 14)
        optical.values["estimation"] = 1; optical.values["reset"] = 5
        let flow = try DatamoshRenderer(width: 96, height: 160, referenceWidth: 96)
        let doc = DatamoshDocument(segments: [optical], resets: [8])
        for frame in inputs.indices {
            let result = try flow.render(inputs[frame], frame: frame, document: doc)
            if [0, 5, 8, 10].contains(frame) {
                let baseline = try clean.render(inputs[frame], frame: frame, document: DatamoshDocument())
                guard bytes(result) == bytes(baseline) else { throw TrenchesError.message("Datamosh не сбросил накопление") }
            }
        }
        record("PASS dense optical flow / interval and manual buffer resets")
        let transfer = DatamoshDocument(segments: [
            DatamoshSegment(start: 3, duration: 3, mode: .transfer, values: ["strength": 1], donorFrame: 0)
        ], resets: [5])
        let donor = try clean.render(inputs[0], frame: 0, document: DatamoshDocument())
        flow.reset()
        let cut = try flow.render(inputs[3], frame: 3, document: transfer, donor: inputs[0])
        let held = try flow.render(inputs[3], frame: 4, document: transfer)
        let restored = try flow.render(inputs[3], frame: 5, document: transfer)
        let sourceFrame = try clean.render(inputs[3], frame: 3, document: DatamoshDocument())
        guard bytes(cut) == bytes(donor), bytes(held) == bytes(donor), bytes(restored) == bytes(sourceFrame) else {
            throw TrenchesError.message("Datamosh не сохранил повреждённую опору или не восстановил кадр при сбросе")
        }
        record("PASS wrong reference persists through skipped predictions / explicit donor / clean reset")
        var shakal = EffectSettings(); shakal.toggle(.shakal); shakal.set(.shakal, "audio", 1)
        let degraded = try AudioDegrader().process(RenderBenchmark.audio(at: 1), settings: shakal)
        guard CMSampleBufferGetNumSamples(degraded) == 1600, CMSampleBufferGetPresentationTimeStamp(degraded) == CMTime(value: 1, timescale: 30) else { throw TrenchesError.message("Шакализация нарушила время звука") }
        record("PASS PCM audio degradation / sample count and timing")
        let recorder = try MovieRecorder(width: 96, height: 160, fps: 30, includeAudio: true)
        var finishedFixture = false
        defer { if !finishedFixture { recorder.cancel() } }
        let captureStart = CMTime(value: 123_456_789_012_345, timescale: 1_000_000_000)
        for frame in inputs.indices {
            let time = CMTimeAdd(captureStart, CMTime(value: Int64(frame) * 33_333_333 + Int64(frame % 3) * 17, timescale: 1_000_000_000))
            for _ in 0..<12 where recorder.frameCount == frame {
                try recorder.appendVideo(inputs[frame], at: time)
                if recorder.frameCount == frame { try await Task.sleep(for: .milliseconds(20)) }
            }
            guard recorder.frameCount == frame + 1 else { throw TrenchesError.message("Кодировщик пропустил тестовый кадр") }
            let audio = try RenderBenchmark.audio(at: frame)
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(audio, at: 0, timingInfoOut: &timing) == noErr else { throw TrenchesError.message("Не удалось сдвинуть тестовый звук") }
            timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, captureStart)
            var shifted: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: audio, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &shifted) == noErr,
                  let shifted else { throw TrenchesError.message("Не удалось сдвинуть тестовый звук") }
            var wroteAudio = false
            for _ in 0..<12 where !wroteAudio {
                let dropped = recorder.droppedAudioSamples
                try recorder.appendAudio(shifted)
                wroteAudio = dropped == recorder.droppedAudioSamples
                if !wroteAudio { try await Task.sleep(for: .milliseconds(20)) }
            }
            guard wroteAudio else { throw TrenchesError.message("Кодировщик пропустил тестовый звук") }
            try await Task.sleep(for: .milliseconds(34))
        }
        let source: URL = try await withCheckedThrowingContinuation { continuation in recorder.finish { continuation.resume(with: $0) } }
        finishedFixture = true
        defer { try? FileManager.default.removeItem(at: source) }
        let token = DatamoshCancellation()
        let media = try await DatamoshMedia.open(source, cancellation: token)
        guard media.frameCount == inputs.count else { throw TrenchesError.message("Тестовая запись содержит \(media.frameCount) из \(inputs.count) кадров") }
        let worker = DatamoshWorker()
        var mixed = DatamoshDocument()
        for (index, mode) in DatamoshMode.allCases.enumerated() {
            var segment = DatamoshSegment(start: index * 2, duration: 2, mode: mode)
            segment.values["estimation"] = index % 2 == 0 ? 1 : 0
            if mode == .transfer { segment.donorFrame = 2 }
            try mixed.put(segment, frameCount: media.frameCount)
        }
        let full = try worker.export(media, document: mixed, preview: false, cancellation: token) { _ in }
        defer { try? FileManager.default.removeItem(at: full) }
        let exported = try await DatamoshMedia.open(full, cancellation: token)
        guard exported.frameCount == media.frameCount, exported.audio != nil, abs(exported.seconds - media.seconds) < 0.05 else { throw TrenchesError.message("Datamosh потерял кадры, звук или длительность") }
        guard try audioBytes(media) == audioBytes(exported) else { throw TrenchesError.message("Datamosh изменил сжатые звуковые пакеты") }
        let straight = try worker.preview(media, document: mixed, frame: 9, cancellation: token)
        worker.clear()
        let repeated = try worker.preview(media, document: mixed, frame: 9, cancellation: token)
        guard straight.0.pngData() == repeated.0.pngData() else { throw TrenchesError.message("Скраббинг Datamosh зависит от истории") }
        for frame in [0, 13, 1, 12, 2, 11, 3, 10, 4, 9, 5, 8, 6, 7] {
            _ = try worker.preview(media, document: mixed, frame: frame, cancellation: token)
        }
        let loop = try worker.export(media, document: mixed, preview: true, frames: 6..<9, cancellation: token) { _ in }
        defer { try? FileManager.default.removeItem(at: loop) }
        let loopMedia = try await DatamoshMedia.open(loop, cancellation: token)
        guard loopMedia.frameCount == 3, loopMedia.audio != nil,
              abs(loopMedia.seconds - CMTimeSubtract(media.times[9], media.times[6]).seconds) < 0.035 else {
            throw TrenchesError.message("Datamosh обрезал превью диапазона с ошибкой")
        }
        record("PASS selected range proxy / clean endpoint / audio track")
        record("PASS shuffled frame-exact scrubbing / nonzero fractional capture clock / empty edit-list samples")
        record("PASS mixed-mode MOV export / bit-exact compressed audio / exact frame count / deterministic scrubbing")
    }

    private static func audioBytes(_ media: DatamoshMedia) throws -> Data {
        let (reader, output) = try media.reader(audioOnly: true)
        defer { reader.cancelReading() }
        var result = Data()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard status == noErr else { throw TrenchesError.message("Не удалось проверить звуковые пакеты") }
            result.append(contentsOf: bytes)
        }
        if let error = reader.error { throw error }
        return result
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

    static func audio(at frame: Int) throws -> CMSampleBuffer {
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
